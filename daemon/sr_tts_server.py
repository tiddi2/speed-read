#!/usr/bin/env python3
"""Persistent local TTS daemon for sr (P-9).

Adapted from Speak11's tts_server.py (public domain). Keeps the local
model(s) loaded in memory and serves TTS requests over a Unix domain socket.

Two engines share this daemon, one venv and one socket:
  kokoro — Kokoro-82M via mlx-audio. English. Fixed set of baked-in voices.
  f5     — an F5-TTS checkpoint via f5-tts-mlx. Norwegian. Zero-shot, so a
           "voice" is a short reference recording plus its transcript, and
           each one lives in its own directory under SR_F5_VOICES_PATH.
Each engine is optional: the daemon starts with whichever ones the installer
configured, and refuses requests for the others.

Security model (P-9):
  - Unix socket only, mode 0600, under ~/Library/Application Support/sr/kokoro/.
    Never TCP.
  - Per-launch auth token: the Swift supervisor passes SR_DAEMON_TOKEN in the
    environment; every request must carry a matching "token" field or the
    connection is refused.

Protocol (one JSON object per line, UTF-8):
  request:  {"token": "<hex>", "text": "...", "voice": "bf_lily",
             "speed": "1.0", "lang_code": "b", "engine": "kokoro"}
  response: {"status": "ok", "audio_file": "/abs/path.wav"}
        or  {"status": "error", "message": "..."}
  "engine" is optional and defaults to "kokoro", so a client from before the
  Norwegian voice existed still speaks the same protocol.
  The CLIENT owns the returned WAV file and its parent temp directory and
  must delete both after reading. Orphaned temp dirs are swept at daemon
  startup.

Modes:
  Default:   auto-shuts down after idle timeout (SR_IDLE_TIMEOUT, default 300s).
  --managed: shuts down on idle timeout, parent exit, or SIGTERM.

Logging is content-free (P-5): text lengths only, never text.
"""

import contextlib
import fcntl
import json
import os
import signal
import socket
import sys
import tempfile
import threading
import time

# ── Paths ────────────────────────────────────────────────────────────

DATA_DIR = os.path.expanduser("~/Library/Application Support/sr/kokoro")
SOCKET_PATH = os.path.join(DATA_DIR, "daemon.sock")
PID_FILE = os.path.join(DATA_DIR, "daemon.pid")
LOCK_FILE = os.path.join(DATA_DIR, "daemon.lock")
TMP_ROOT = os.path.join(DATA_DIR, "tmp")
LOG_DIR = os.path.expanduser("~/Library/Logs/sr")
LOG_FILE = os.path.join(LOG_DIR, "kokoro.log")

MODEL_ID = "mlx-community/Kokoro-82M-bf16"
# Must match the client cache namespace: old processes may outlive an update.
# One entry per engine, because a stale daemon serving one engine's audio
# under the other's namespace would poison the cache.
OUTPUT_VERSIONS = {"kokoro": "kokoro-82M-t2", "f5": "f5-tts-no-t1"}
ENGINES = tuple(OUTPUT_VERSIONS)

# Verified local snapshot (P-12): the supervisor passes the installer's
# hash-verified snapshot directory so the daemon runs exactly the bytes
# that were checked — never whatever the HF cache resolves MODEL_ID to.
MODEL_PATH = os.environ.get("SR_MODEL_PATH", "")

# ── F5 (Norwegian) ───────────────────────────────────────────────────
# Same idea: the supervisor passes verified directories, never repo ids.
#   SR_F5_MODEL_PATH    dir with model_v1.safetensors + vocab.txt
#   SR_F5_VOCODER_PATH  dir with the Vocos mel vocoder
#   SR_F5_VOICES_PATH   dir of <voice>/ref.wav + <voice>/ref.txt
#   SR_F5_ARCH          JSON architecture knobs written by the installer
F5_MODEL_PATH = os.environ.get("SR_F5_MODEL_PATH", "")
F5_VOCODER_PATH = os.environ.get("SR_F5_VOCODER_PATH", "")
F5_VOICES_PATH = os.environ.get("SR_F5_VOICES_PATH", "")
F5_ARCH_JSON = os.environ.get("SR_F5_ARCH", "")

# Every way these can fail has the same fix, so they get one wording each
# rather than a class name the user cannot act on.
MODEL_FILES_DAMAGED = "the Norwegian model files are missing or damaged"
VOCODER_DAMAGED = "the mel vocoder is missing or damaged"

F5_SAMPLE_RATE = 24_000
F5_HOP_LENGTH = 256
F5_FRAMES_PER_SEC = F5_SAMPLE_RATE / F5_HOP_LENGTH
# f5-tts-mlx normalizes the reference clip to this RMS before conditioning.
F5_TARGET_RMS = 0.1
# Sampling steps through the flow-matching ODE. 8 is upstream's default and
# the knee of the quality/latency curve on Apple Silicon.
F5_STEPS = 8
# f5-tts-mlx caps a generation at 4096 frames (~43 s). Stay under it with
# room for the reference clip, and split longer text rather than truncating.
F5_MAX_FRAMES = 3600

# Requests are single sentences (the client chunks upstream); 1 MB is
# orders of magnitude above any legitimate request line.
MAX_REQUEST_BYTES = 1_000_000

# Kokoro bakes ~0.4 s of leading and ~0.6 s of trailing silence into every
# generated segment (stacking when text is split into multiple segments).
# The client adds its own configured inter-sentence pause on top, so baked-in
# edge silence is pure dead air between sentences at any playback rate.
# Trim thresholds: sample counts as silent below this fraction of the
# segment's peak amplitude; a short natural pad is kept at each edge.
TRIM_THRESHOLD_RATIO = 0.005
TRIM_PAD_SECONDS = 0.06

# Idle timeout in seconds (non-managed mode).
IDLE_TIMEOUT = int(os.environ.get("SR_IDLE_TIMEOUT", "300"))

# Per-launch auth token (required).
AUTH_TOKEN = os.environ.get("SR_DAEMON_TOKEN", "")

# ── Logging (content-free, P-5) ──────────────────────────────────────


def log(msg):
    """Append a timestamped line to the log. Never log request text."""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] sr_tts_server: {msg}\n"
            )
    except OSError:
        pass


def _traceback_frames(exc, limit=4):
    """Where an exception came from, as file:line names only.

    Deliberately not `traceback.format_exc()`: that includes the exception
    message and the source line, either of which can quote the text being
    read (P-5). Frame file names and line numbers cannot.
    """
    import traceback

    try:
        frames = traceback.extract_tb(exc.__traceback__)[-limit:]
        return " <- ".join(
            f"{os.path.basename(f.filename)}:{f.lineno}" for f in reversed(frames)
        ) or "no frames"
    except Exception:
        return "unavailable"


# ── Globals ──────────────────────────────────────────────────────────

model = None
f5_model = None
f5_load_lock = threading.Lock()
last_request_time = time.time()
server_socket = None
shutdown_event = threading.Event()
managed_mode = False
generation_lock = threading.Lock()
client_slots = threading.BoundedSemaphore(16)
activity_lock = threading.Lock()
active_clients = 0


def kokoro_configured():
    return bool(MODEL_PATH) or not managed_mode


def f5_configured():
    return bool(F5_MODEL_PATH and F5_VOCODER_PATH and F5_VOICES_PATH)


# ── Model ────────────────────────────────────────────────────────────


def load_tts_model():
    global model
    from mlx_audio.tts.utils import load_model

    if MODEL_PATH and os.path.isdir(MODEL_PATH):
        log("loading model from verified snapshot path")
        model = load_model(MODEL_PATH)
    elif managed_mode:
        raise EngineError("verified model path missing")
    else:
        log(f"loading model {MODEL_ID}")
        model = load_model(MODEL_ID)
    log("model loaded")


def warmup_pipeline():
    """Pre-cache the language pipeline so the first real request is fast."""
    try:
        log("warming up pipeline")
        for _ in model.generate(text=".", voice="bf_lily", speed=1.0, lang_code="b"):
            pass
        log("pipeline warm")
    except Exception as e:
        log(f"warmup failed (non-fatal): {type(e).__name__}")


class CancelledError(Exception):
    """Raised when a generation is cancelled (client disconnected)."""


class EngineError(Exception):
    """A failure the daemon itself diagnosed, safe to report verbatim.

    P-5 keeps request text out of logs and off the wire, which is why an
    unexpected exception is reported as its class name alone: the message
    could quote the text being read. But these messages are fixed literals
    written here, naming a condition rather than any content, so relaying
    them costs nothing and is the difference between "HTTP 500" and knowing
    which of a dozen setup problems to fix. Never raise this with a message
    built from a request field.
    """


# Memory exhaustion arrives as a different exception per allocator — Python's
# MemoryError, or one of Metal's, whose class is a bare RuntimeError. Only the
# fact is used; the message itself is never relayed.
_OUT_OF_MEMORY_MARKERS = (
    "out of memory", "insufficient memory", "attempting to allocate",
    "failed to allocate", "maximum allowed buffer size",
)


def _is_out_of_memory(exc):
    if isinstance(exc, MemoryError):
        return True
    return any(marker in str(exc).lower() for marker in _OUT_OF_MEMORY_MARKERS)


@contextlib.contextmanager
def during(step, diagnosis=None):
    """Name the phase an unexpected failure happened in.

    The generic handler reports an unexpected exception by class name alone,
    which for `RuntimeError` — what mlx raises for a missing, truncated or
    unreadable model file, and what soundfile raises for an unreadable clip —
    is the entire story the user gets. These are the phases that fail for
    ordinary reasons having nothing to do with the text being read, so each
    says what it was doing. `diagnosis` replaces that with a condition the
    user can act on, for phases where every way of failing has the same fix.
    Both are literals written here, never built from a request field, so the
    wire message stays content-free; the class and frames go to the log.
    """
    try:
        yield
    except (EngineError, CancelledError):
        raise
    except Exception as exc:
        log(f"error while {step}: {type(exc).__name__} at {_traceback_frames(exc)}")
        # Chained, not suppressed. Only the EngineError's own message reaches
        # the log and the wire, so P-5 is unaffected — but keeping the cause
        # attached is what lets --self-test print what actually went wrong.
        if _is_out_of_memory(exc):
            raise EngineError(f"ran out of memory while {step}") from exc
        raise EngineError(diagnosis or f"{type(exc).__name__} while {step}") from exc


def _generate_segments(text, voice, speed, lang_code, cancel_check, depth=0):
    """Yield audio segments, splitting the text on a known mlx-audio bug.

    mlx-audio 0.4.4 raises ValueError('[broadcast_shapes] ...') for certain
    voice x output-length combinations (upstream bug, fixed after 0.4.4 —
    revisit when the pin is bumped). Splitting the text at a word boundary
    changes the length and sidesteps the trigger; recursion is bounded.
    """
    import numpy as np

    try:
        segments = []
        for result in model.generate(
            text=text, voice=voice, speed=float(speed), lang_code=lang_code
        ):
            if cancel_check and cancel_check():
                raise CancelledError("client disconnected")
            # Materialize inside the try so the workaround also catches
            # errors raised lazily during generation.
            segments.append((np.array(result.audio), result.sample_rate))
        return segments
    except ValueError as e:
        if "broadcast_shapes" not in str(e):
            raise
        if depth >= 90:
            # Inside a punctuation-pad attempt (depth=99): no further
            # workarounds — bubble up so the pad ladder tries the next pad.
            raise
        # Split at a word boundary when possible — halving usually dodges
        # the length trigger.
        if depth < 4 and len(text) >= 12:
            mid = len(text) // 2
            split_at = text.rfind(" ", 0, mid)
            if split_at <= 0:
                split_at = text.find(" ", mid)
            if split_at > 0:
                log(f"broadcast_shapes workaround: splitting text_len={len(text)} at {split_at}")
                left = _generate_segments(
                    text[:split_at].strip(), voice, speed, lang_code, cancel_check, depth + 1
                )
                right = _generate_segments(
                    text[split_at:].strip(), voice, speed, lang_code, cancel_check, depth + 1
                )
                return left + right
        # Cursed fragment: the crash is deterministic in phoneme length, so
        # nudge the length with punctuation-only pads (no words added).
        for pad in (",", " ,", ", ,"):
            try:
                log(f"broadcast_shapes workaround: padding text_len={len(text)}")
                return _generate_segments(
                    text + pad, voice, speed, lang_code, cancel_check, depth=99
                )
            except ValueError as e2:
                if "broadcast_shapes" not in str(e2):
                    raise
        # Never report success (and cache incomplete audio) when a fragment
        # could not be spoken. The client will surface the failure to the user.
        log(f"broadcast_shapes workaround exhausted: text_len={len(text)}")
        raise EngineError("local synthesis workaround exhausted") from None


def _trim_edge_silence(audio, sample_rate):
    """Trim leading/trailing silence from one generated segment.

    Keeps TRIM_PAD_SECONDS of natural padding at each edge. All-silent
    segments pass through untouched because they have no speech boundary.
    """
    import numpy as np

    if audio.size == 0:
        return audio
    threshold = np.abs(audio).max() * TRIM_THRESHOLD_RATIO
    if threshold <= 0:
        return audio
    voiced = np.flatnonzero(np.abs(audio) > threshold)
    if voiced.size == 0:
        return audio
    pad = int(TRIM_PAD_SECONDS * sample_rate)
    start = max(int(voiced[0]) - pad, 0)
    end = min(int(voiced[-1]) + 1 + pad, audio.size)
    return audio[start:end]


def generate_audio(text, voice, speed, lang_code, cancel_check=None,
                   engine="kokoro"):
    """Generate a WAV file from text. Returns the file path.

    The caller's client owns the file and its parent dir (deletes after
    reading).
    """
    import numpy as np
    from mlx_audio.audio_io import write as audio_write

    os.makedirs(TMP_ROOT, exist_ok=True)
    tmp_dir = tempfile.mkdtemp(prefix="gen_", dir=TMP_ROOT)
    out_path = os.path.join(tmp_dir, "out.wav")

    try:
        if engine == "f5":
            pairs = _f5_generate_segments(text, voice, cancel_check)
        else:
            pairs = _generate_segments(text, voice, speed, lang_code, cancel_check)
        segments = [_trim_edge_silence(audio, rate) for audio, rate in pairs]
        sample_rate = pairs[-1][1] if pairs else None

        if not segments or sample_rate is None:
            raise EngineError("model produced no audio")

        audio = np.concatenate(segments) if len(segments) > 1 else segments[0]
        audio_write(out_path, audio, sample_rate, format="wav")

        if not os.path.isfile(out_path) or os.path.getsize(out_path) == 0:
            raise EngineError("audio file empty after write")

        del segments, audio
        return out_path

    except Exception:
        import shutil

        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


# ── F5 (Norwegian) ───────────────────────────────────────────────────

# F5-TTS Base ("v0") and F5-TTS v1 Base have identical tensor shapes and
# differ only in how text padding is masked and where rotary embeddings are
# applied, so a checkpoint cannot say which it is. The installer records the
# answer (from a config in the repo, or the shipped default) and passes it
# here; getting it wrong produces babble rather than an error, which is why
# it is switchable from Settings.
F5_DEFAULT_ARCH = {
    "dim": 1024,
    "depth": 22,
    "heads": 16,
    "ff_mult": 2,
    "text_dim": 512,
    "conv_layers": 4,
    "text_mask_padding": False,
    "pe_attn_head": 1,
}

_f5_attention_patched = False
_f5_reference_cache = {}


def f5_arch():
    arch = dict(F5_DEFAULT_ARCH)
    if F5_ARCH_JSON:
        try:
            supplied = json.loads(F5_ARCH_JSON)
        except ValueError:
            log("f5: ignoring unparseable SR_F5_ARCH")
            return arch
        if isinstance(supplied, dict):
            arch.update({k: v for k, v in supplied.items() if k in F5_DEFAULT_ARCH})
    return arch


def _patch_attention_for_pe_head(pe_attn_head):
    """Apply rotary embeddings to the first `pe_attn_head` heads only.

    f5-tts-mlx implements F5-TTS v1, which rotates every head. The original
    F5TTS_Base rotates only the first (`pe_attn_head: 1` upstream), and a
    checkpoint trained that way is unintelligible when every head is
    rotated. The projections, mask and output path are upstream's; only the
    rope slice differs.
    """
    global _f5_attention_patched
    if _f5_attention_patched:
        return

    import mlx.core as mx
    from f5_tts_mlx.dit import Attention
    from f5_tts_mlx.rope import apply_rotary_pos_emb

    upstream = Attention.__call__

    def patched(self, x, mask=None, rope=None):
        if rope is None:
            return upstream(self, x, mask=mask, rope=rope)

        batch, seq_len, _ = x.shape
        heads = self.heads

        def split(projection):
            return projection.reshape(batch, seq_len, heads, -1).transpose(0, 2, 1, 3)

        query, key, value = split(self.to_q(x)), split(self.to_k(x)), split(self.to_v(x))

        freqs, xpos_scale = rope
        q_scale, k_scale = (
            (xpos_scale, xpos_scale**-1.0) if xpos_scale is not None else (1.0, 1.0)
        )
        count = min(pe_attn_head, heads)
        query = mx.concatenate(
            [apply_rotary_pos_emb(query[:, :count], freqs, q_scale), query[:, count:]],
            axis=1)
        key = mx.concatenate(
            [apply_rotary_pos_emb(key[:, :count], freqs, k_scale), key[:, count:]],
            axis=1)

        attn_mask = None
        if mask is not None:
            attn_mask = mask[:, None, None, :].expand(batch, heads, 1, seq_len)

        out = mx.fast.scaled_dot_product_attention(
            q=query, k=key, v=value, scale=self._scale_factor, mask=attn_mask)
        out = out.transpose(0, 2, 1, 3).reshape(batch, seq_len, -1).astype(query.dtype)
        out = self.to_out(out)
        if attn_mask is not None:
            out = out * mask[:, :, None]
        return out

    Attention.__call__ = patched
    _f5_attention_patched = True
    log(f"f5: rotary embeddings limited to {pe_attn_head} head(s)")


def _f5_convert_weights(weights):
    """Rename an F5-TTS checkpoint's tensors onto the MLX module tree.

    Same mapping f5-tts-mlx applies in `F5TTS.from_pretrained`, kept here
    because sr builds the model itself (local paths, a local vocoder and a
    selectable architecture, none of which that entry point offers).
    """
    converted = {}
    for key, value in weights.items():
        key = key.replace("ema_model.", "")
        if len(key) < 1 or "mel_spec." in key or key in ("initted", "step"):
            continue
        elif ".to_out" in key:
            key = key.replace(".to_out", ".to_out.layers")
        elif ".text_blocks" in key:
            key = key.replace(".text_blocks", ".text_blocks.layers")
        elif ".ff.ff.0.0" in key:
            key = key.replace(".ff.ff.0.0", ".ff.ff.layers.0.layers.0")
        elif ".ff.ff.2" in key:
            key = key.replace(".ff.ff.2", ".ff.ff.layers.2")
        elif ".time_mlp" in key:
            key = key.replace(".time_mlp", ".time_mlp.layers")
        elif ".conv1d" in key:
            key = key.replace(".conv1d", ".conv1d.layers")

        if ".dwconv.weight" in key:
            value = value.swapaxes(1, 2)
        elif ".conv1d.layers.0.weight" in key:
            value = value.swapaxes(1, 2)
        elif ".conv1d.layers.2.weight" in key:
            value = value.swapaxes(1, 2)

        converted[key] = value
    return converted


def load_f5_model():
    """Build the F5 model on first Norwegian request (~1.3 GB of weights).

    Lazy rather than eager so a user who installed only the English voice
    never pays for this, and so daemon startup stays inside the supervisor's
    socket deadline when both engines are installed.
    """
    global f5_model
    if f5_model is not None:
        return f5_model

    with f5_load_lock:
        if f5_model is not None:
            return f5_model
        if not f5_configured():
            raise EngineError("f5 engine not installed")

        import mlx.core as mx
        from vocos_mlx import Vocos

        arch = f5_arch()
        pe_attn_head = arch.get("pe_attn_head")
        if pe_attn_head:
            _patch_attention_for_pe_head(int(pe_attn_head))

        from f5_tts_mlx.cfm import F5TTS
        from f5_tts_mlx.dit import DiT

        log("f5: loading weights")
        weights_path = os.path.join(F5_MODEL_PATH, "model_v1.safetensors")
        vocab_path = os.path.join(F5_MODEL_PATH, "vocab.txt")
        # Say which file is gone before mlx does. Its own answer to a missing
        # or truncated checkpoint is a bare RuntimeError, which reaches the
        # menu bar as "(RuntimeError)" and names neither the file nor the fix.
        _require_files(MODEL_FILES_DAMAGED, weights_path, vocab_path)
        _require_files(
            VOCODER_DAMAGED,
            os.path.join(F5_VOCODER_PATH, "model.safetensors"),
            os.path.join(F5_VOCODER_PATH, "config.yaml"))

        with during("reading the Norwegian vocabulary", MODEL_FILES_DAMAGED):
            with open(vocab_path, encoding="utf-8") as f:
                entries = f.read().split("\n")
        vocab = {char: index for index, char in enumerate(entries)}
        if not vocab:
            raise EngineError("f5 vocabulary is empty")

        with during("reading the Norwegian model weights", MODEL_FILES_DAMAGED):
            weights = _f5_convert_weights(mx.load(weights_path, format="safetensors"))

        # Size the text embedding from the checkpoint rather than from the
        # vocabulary file: whether vocab.txt ends in a newline changes the
        # count by one, and a one-off there is a shape mismatch at load.
        embedding = weights.get("transformer.text_embed.text_embed.weight")
        text_num_embeds = (
            embedding.shape[0] - 1 if embedding is not None else len(vocab) - 1
        )

        with during("loading the mel vocoder", VOCODER_DAMAGED):
            vocos = Vocos.from_pretrained(F5_VOCODER_PATH)
        f5 = F5TTS(
            transformer=DiT(
                dim=int(arch["dim"]),
                depth=int(arch["depth"]),
                heads=int(arch["heads"]),
                ff_mult=int(arch["ff_mult"]),
                text_dim=int(arch["text_dim"]),
                conv_layers=int(arch["conv_layers"]),
                text_mask_padding=bool(arch["text_mask_padding"]),
                text_num_embeds=text_num_embeds,
            ),
            vocab_char_map=vocab,
            vocoder=vocos.decode,
        )
        with during("fitting the weights to the model"):
            try:
                f5.load_weights(list(weights.items()))
            except ValueError as error:
                # Tensor names or shapes the architecture does not have: the
                # checkpoint is being loaded as something it is not. The one
                # F5 failure whose fix is neither "reinstall" nor "free some
                # memory", so it gets its own wording.
                log(f"f5: weights do not fit the model "
                    f"({_traceback_frames(error, 1)})")
                raise EngineError(
                    "checkpoint does not fit the F5 architecture") from error
        with during("preparing the Norwegian model"):
            mx.eval(f5.parameters())
        f5_model = f5
        log(f"f5: model loaded (vocab={len(vocab)} embeds={text_num_embeds})")
        return f5_model


def _require_files(diagnosis, *paths):
    """Refuse early, by name, when a verified file is gone or truncated."""
    for path in paths:
        try:
            if os.path.getsize(path) > 0:
                continue
        except OSError:
            pass
        log(f"f5: missing or empty {os.path.basename(path)}")
        raise EngineError(diagnosis)


def _f5_reference(voice):
    """Load a reference clip and its transcript, cached by mtime.

    Returns (mx.array mono 24 kHz, transcript, rms_scale). The clip is
    written by sr at exactly 24 kHz mono, so anything else here means the
    voice directory was tampered with and is refused rather than resampled.
    """
    import mlx.core as mx
    import numpy as np
    import soundfile as sf

    directory = os.path.join(F5_VOICES_PATH, voice)
    audio_path = os.path.join(directory, "ref.wav")
    text_path = os.path.join(directory, "ref.txt")
    # Trust boundary: the voice id is already validated as a bare name, but
    # resolve the files too — a symlink planted in the voices tree must not
    # make the daemon read somewhere else on disk.
    root = os.path.realpath(F5_VOICES_PATH) + os.sep
    for path in (audio_path, text_path):
        if not os.path.realpath(path).startswith(root):
            raise EngineError("voice files escape the voices root")
    if not (os.path.isfile(audio_path) and os.path.isfile(text_path)):
        raise EngineError("voice is missing its reference recording")

    stamp = (os.path.getmtime(audio_path), os.path.getmtime(text_path))
    cached = _f5_reference_cache.get(voice)
    if cached and cached[0] == stamp:
        return cached[1]

    try:
        audio, sample_rate = sf.read(audio_path, dtype="float32", always_2d=True)
    except Exception as error:
        # soundfile's own failure is a RuntimeError subclass, and its message
        # quotes the path — so name the condition instead and let the log
        # carry the class.
        log(f"f5: unreadable reference clip ({type(error).__name__})")
        raise EngineError("reference recording could not be read") from error
    if sample_rate != F5_SAMPLE_RATE:
        raise EngineError("reference recording is not 24 kHz")
    audio = audio.mean(axis=1) if audio.shape[1] > 1 else audio[:, 0]
    if audio.size < F5_SAMPLE_RATE // 2:
        raise EngineError("reference recording is too short")

    with open(text_path, encoding="utf-8") as f:
        transcript = f.read().strip()
    if not transcript:
        raise EngineError("reference recording has no transcript")

    # Upstream conditions on a clip normalized to TARGET_RMS and scales the
    # result back, so a quiet reference does not make every read loud.
    rms = float(np.sqrt(np.mean(np.square(audio)))) or 1.0
    scale = 1.0
    if rms < F5_TARGET_RMS:
        audio = audio * (F5_TARGET_RMS / rms)
        scale = rms / F5_TARGET_RMS

    loaded = (mx.array(audio), transcript, scale)
    _f5_reference_cache[voice] = (stamp, loaded)
    return loaded


def _f5_estimated_frames(reference_frames, ref_text, gen_text):
    """Upstream's byte-length heuristic for how long the output should be."""
    ref_length = max(len(ref_text.encode("utf-8")), 1)
    gen_length = len(gen_text.encode("utf-8"))
    return reference_frames + int(reference_frames / ref_length * gen_length)


def _f5_generate_segments(text, voice, cancel_check, depth=0):
    """Yield (audio, sample_rate) for `text`, splitting when it is too long.

    A single F5 generation is capped at F5_MAX_FRAMES; sr chunks by sentence
    upstream, but one sentence of minified text or unpunctuated OCR can still
    exceed it. Splitting at a word boundary keeps every word spoken instead of
    truncating the tail.
    """
    import numpy as np

    f5 = load_f5_model()
    reference, ref_text, rms_scale = _f5_reference(voice)
    reference_frames = reference.shape[0] // F5_HOP_LENGTH
    frames = _f5_estimated_frames(reference_frames, ref_text, text)

    if frames > F5_MAX_FRAMES and depth < 6 and len(text) >= 24:
        middle = len(text) // 2
        split_at = text.rfind(" ", 0, middle)
        if split_at <= 0:
            split_at = text.find(" ", middle)
        if split_at > 0:
            log(f"f5: splitting long text_len={len(text)} at {split_at}")
            return (
                _f5_generate_segments(
                    text[:split_at].strip(), voice, cancel_check, depth + 1)
                + _f5_generate_segments(
                    text[split_at:].strip(), voice, cancel_check, depth + 1)
            )

    if cancel_check and cancel_check():
        raise CancelledError("client disconnected")

    import mlx.core as mx
    from f5_tts_mlx.utils import convert_char_to_pinyin

    # Speed is always 1.0 — sr applies playback rate client-side (F-8), so
    # cached audio stays rate-agnostic.
    with during("generating Norwegian speech"):
        conditioned = convert_char_to_pinyin([ref_text + " " + text])
        wave, _ = f5.sample(
            mx.expand_dims(reference, axis=0),
            text=conditioned,
            duration=min(frames, F5_MAX_FRAMES),
            steps=F5_STEPS,
            method="rk4",
            cfg_strength=2.0,
            sway_sampling_coef=-1.0,
            speed=1.0,
        )
        # The model continues the reference clip; drop the part we fed it.
        wave = wave[reference.shape[0]:]
        mx.eval(wave)

    audio = np.array(wave, copy=True).astype(np.float32)
    if rms_scale != 1.0:
        audio = audio * rms_scale
    del wave
    if audio.size == 0:
        raise EngineError("model produced no audio")
    return [(audio, F5_SAMPLE_RATE)]


# ── Client handler ───────────────────────────────────────────────────


def _client_gone(conn):
    """Non-blocking check: has the client closed the connection?"""
    import select
    try:
        readable, _, _ = select.select([conn], [], [], 0)
        if readable:
            data = conn.recv(1, socket.MSG_PEEK)
            return len(data) == 0
        return False
    except OSError:
        return True


class RequestTooLarge(Exception):
    """Raised before parsing when a request exceeds the wire cap."""


def _read_request_line(conn):
    data = b""
    conn.settimeout(10)
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
        # Check size before accepting a newline from the same recv. The old
        # order let MAX_REQUEST_BYTES + one socket chunk through.
        if len(data) > MAX_REQUEST_BYTES:
            raise RequestTooLarge()
        if b"\n" in data:
            return data.split(b"\n", 1)[0]
    return data


def _release_model_scratch():
    """Release per-request scratch while the generation lock is still held."""
    import gc
    import mlx.core as mx

    gc.collect()
    # mx.metal.clear_cache is deprecated in favour of mx.clear_cache and warns
    # on every call; keep the old spelling only for an older pinned mlx.
    clear = getattr(mx, "clear_cache", None) or mx.metal.clear_cache
    clear()


def handle_client(conn):
    """Read one JSON request, check token, generate audio, respond."""
    def send(obj):
        try:
            conn.sendall((json.dumps(obj) + "\n").encode("utf-8"))
        except OSError:
            pass

    try:
        try:
            data = _read_request_line(conn)
        except RequestTooLarge:
            log("request rejected: oversized")
            send({"status": "error", "message": "request too large"})
            return

        if not data.strip():
            return

        request = json.loads(data.decode("utf-8").strip())

        # ── Auth (P-9) ──
        if not AUTH_TOKEN or request.get("token", "") != AUTH_TOKEN:
            log("request rejected: bad token")
            send({"status": "error", "message": "unauthorized"})
            return

        # ── Validation: reject rather than let bad values reach the model,
        # and never log raw request fields (log-line forgery / content leaks).
        text = request.get("text", "")
        voice = request.get("voice", "bf_lily")
        speed_raw = request.get("speed", "1.0")
        lang_code = request.get("lang_code", "b")
        # Absent means kokoro: a client from before the Norwegian voice
        # existed omits the field entirely.
        engine = request.get("engine", "kokoro")
        import math
        import re
        # F5 voice ids are directory names sr generates, so they may carry a
        # hyphen; Kokoro's are the model's own baked-in names. Both patterns
        # exclude "." and "/", which is what keeps a voice id a bare name.
        voice_pattern = r"[a-z0-9_-]{1,64}" if engine == "f5" else r"[a-z0-9_]{1,32}"
        if not isinstance(text, str) or not isinstance(voice, str) \
                or not isinstance(lang_code, str) \
                or not isinstance(engine, str) or engine not in ENGINES \
                or not re.fullmatch(voice_pattern, voice) \
                or not re.fullmatch(r"[a-z]", lang_code):
            log("request rejected: invalid fields")
            send({"status": "error", "message": "invalid request fields"})
            return
        if engine == "f5" and not f5_configured():
            log("request rejected: f5 engine not installed")
            send({"status": "error", "message": "engine not installed"})
            return
        try:
            speed = float(speed_raw)
        except (TypeError, ValueError):
            speed = None
        if speed is None or not math.isfinite(speed) or not 0.25 <= speed <= 4.0:
            log("request rejected: invalid speed")
            send({"status": "error", "message": "invalid speed"})
            return

        log(f"request: engine={engine} text_len={len(text)} voice={voice} "
            f"speed={speed} lang={lang_code}")

        if _client_gone(conn):
            raise CancelledError("client disconnected before generation")

        with generation_lock:
            # Requests can wait behind another sentence after their client has
            # already canceled. Re-check immediately after acquiring the lock
            # so stale work never reaches model.generate().
            if _client_gone(conn):
                raise CancelledError("client disconnected while queued")
            try:
                audio_file = generate_audio(
                    text, voice, speed, lang_code,
                    cancel_check=lambda: _client_gone(conn),
                    engine=engine,
                )
            finally:
                _release_model_scratch()

        # Size before send: once the response is out, the client owns the
        # temp dir and may delete it before we could stat it.
        audio_bytes = os.path.getsize(audio_file)
        send({"status": "ok", "audio_file": audio_file,
              "output_version": OUTPUT_VERSIONS[engine]})
        log(f"response: ok bytes={audio_bytes}")

    except CancelledError:
        log("generation cancelled (client disconnected)")
    except EngineError as e:
        # Our own diagnosis, fixed wording, no request data — say it.
        log(f"error: {e}")
        send({"status": "error", "message": str(e)})
    except Exception as e:
        # Content-free (P-5): exception messages can embed request fragments,
        # so neither logs nor the wire response include them. The traceback's
        # frames are our own and the libraries' file names and line numbers,
        # which carry no request text and are what makes an unexpected
        # failure diagnosable at all — without them "RuntimeError" is the
        # whole story. They go on the wire for the same reason: someone
        # reading the error in the menu bar should not have to open a log to
        # learn which of a dozen unrelated failures they hit.
        frames = _traceback_frames(e)
        log(f"error: {type(e).__name__} at {frames}")
        send({"status": "error",
              "message": f"{type(e).__name__} at {_traceback_frames(e, limit=2)}"})
    finally:
        try:
            conn.close()
        except OSError:
            pass


def _client_started():
    global active_clients, last_request_time
    with activity_lock:
        active_clients += 1
        last_request_time = time.time()


def _client_finished():
    global active_clients, last_request_time
    with activity_lock:
        active_clients -= 1
        last_request_time = time.time()


def handle_client_with_slot(conn):
    try:
        handle_client(conn)
    finally:
        _client_finished()
        client_slots.release()


# ── Watchdogs ────────────────────────────────────────────────────────


def _idle_state(now=None):
    """Return (should_exit, remaining, active) from one locked snapshot."""
    if now is None:
        now = time.time()
    with activity_lock:
        remaining = IDLE_TIMEOUT - (now - last_request_time)
        active = active_clients
    return remaining <= 0 and active == 0, remaining, active


def idle_watchdog():
    while not shutdown_event.is_set():
        should_exit, remaining, active = _idle_state()
        if should_exit:
            log(f"idle for {IDLE_TIMEOUT}s, shutting down")
            do_shutdown()
            return
        # Active includes requests queued behind generation_lock. Never kill a
        # live or queued read; completion refreshes last_request_time.
        shutdown_event.wait(1 if active else min(remaining + 0.5, 10))


def parent_watchdog():
    """Managed mode: exit if the parent (sr.app) dies."""
    parent_pid = os.getppid()
    if parent_pid <= 1:
        log("already orphaned at startup, shutting down")
        do_shutdown()
        return
    log(f"parent watchdog started (parent pid={parent_pid})")
    while not shutdown_event.is_set():
        if os.getppid() != parent_pid:
            log(f"parent died (was {parent_pid}), shutting down")
            do_shutdown()
            return
        shutdown_event.wait(2)


# ── Shutdown ─────────────────────────────────────────────────────────


def do_shutdown():
    shutdown_event.set()
    if server_socket is not None:
        try:
            server_socket.close()
        except OSError:
            pass
    for path in (SOCKET_PATH, PID_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    log("shutdown complete")
    os._exit(0)


def handle_signal(signum, _frame):
    log(f"received signal {signum}")
    do_shutdown()


# ── Main ─────────────────────────────────────────────────────────────


def main():
    global server_socket, managed_mode

    managed_mode = "--managed" in sys.argv[1:]

    if not AUTH_TOKEN:
        log("refusing to start: SR_DAEMON_TOKEN not set")
        sys.exit(2)

    # Before taking the lock or writing a pid: a daemon with no engine to
    # serve would only leave state behind for the next one to clean up.
    if not kokoro_configured() and not f5_configured():
        log("refusing to start: no engine configured")
        sys.exit(2)

    os.makedirs(DATA_DIR, exist_ok=True)

    # Exclusive lock — at most one daemon. Held for process lifetime,
    # released automatically on any exit.
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)  # another daemon holds the lock

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    # Publish the auth token — only AFTER winning the flock, so a losing
    # contender can never overwrite the live daemon's token with its own
    # (Swift clients read this file; the daemon is the single writer).
    token_path = os.path.join(DATA_DIR, "daemon.token")
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    # O_CREAT's mode only applies on create — repair a pre-existing file's
    # permissions so a once-loose token file can't stay world-readable.
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(AUTH_TOKEN)

    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    # Sweep temp dirs orphaned by interrupted generations.
    import glob
    import shutil

    for d in glob.glob(os.path.join(TMP_ROOT, "gen_*")):
        shutil.rmtree(d, ignore_errors=True)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load the eager engine (slow — the supervisor polls for the socket to
    # appear). F5 is loaded on first use instead, so installing only the
    # Norwegian voice neither delays startup nor pins 1.3 GB that a
    # cloud-only session would never touch.
    if kokoro_configured():
        load_tts_model()
        warmup_pipeline()
    else:
        log("starting without kokoro: f5 engine only")

    # Managed daemons need both guarantees: die with the parent, and unload
    # the model after inactivity so a prewarm does not pin Metal/RAM forever.
    threading.Thread(target=idle_watchdog, daemon=True).start()
    if managed_mode:
        threading.Thread(target=parent_watchdog, daemon=True).start()

    # Creating the socket signals readiness. 0600 before listen (P-9).
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    umask_prev = os.umask(0o177)
    try:
        server_socket.bind(SOCKET_PATH)
    finally:
        os.umask(umask_prev)
    os.chmod(SOCKET_PATH, 0o600)
    # Backlog must exceed the client's max in-flight chunks (SynthesisPipeline
    # opens one connection per concurrent chunk). listen(2) refused the 3rd of
    # 3 concurrent connections with ECONNREFUSED, which cascaded into a failed
    # read ("Local voice unavailable"). Generation is still serialized by
    # generation_lock; the backlog only governs how many connects can queue.
    server_socket.listen(16)
    server_socket.settimeout(5)

    mode_str = "managed" if managed_mode else f"idle timeout {IDLE_TIMEOUT}s"
    log(f"listening ({mode_str})")

    # Each client in a thread so a new request can cancel a long-running
    # generation (old client disconnects, cancel_check fires).
    while not shutdown_event.is_set():
        try:
            conn, _ = server_socket.accept()
            if not client_slots.acquire(blocking=False):
                log("connection rejected: capacity")
                conn.close()
                continue
            _client_started()
            t = threading.Thread(
                target=handle_client_with_slot, args=(conn,), daemon=True)
            t.start()
        except socket.timeout:
            continue
        except OSError:
            if not shutdown_event.is_set():
                log("socket error in accept loop")
            break

    do_shutdown()


# ── Self-test ────────────────────────────────────────────────────────

# A sentence written here, not one anyone selected — which is the whole
# reason this mode may print what the daemon may not.
SELF_TEST_TEXT = "Dette er en test av den norske stemmen."


def _self_test_paths():
    """Fill in the standard install layout for anything not in the env.

    Run by hand the daemon has no supervisor to hand it the verified paths,
    so it falls back to where the installer puts them.
    """
    global MODEL_PATH, F5_MODEL_PATH, F5_VOCODER_PATH, F5_VOICES_PATH, F5_ARCH_JSON

    f5_base = os.path.expanduser("~/Library/Application Support/sr/f5")
    F5_MODEL_PATH = F5_MODEL_PATH or os.path.join(f5_base, "model")
    F5_VOCODER_PATH = F5_VOCODER_PATH or os.path.join(f5_base, "vocoder")
    F5_VOICES_PATH = F5_VOICES_PATH or os.path.join(f5_base, "voices")
    MODEL_PATH = MODEL_PATH or os.path.join(DATA_DIR, "Kokoro-82M-bf16")

    if F5_ARCH_JSON:
        print(f"arch:            {F5_ARCH_JSON} (from SR_F5_ARCH)")
        return

    # What the supervisor would have passed: the architecture the installer
    # recorded, with the Settings → Voices override applied if there is one.
    # Reading the same two sources sr reads is the point — an arch that
    # differs from the app's would diagnose a different install than the one
    # that is failing.
    try:
        with open(os.path.join(f5_base, "manifest.json"), encoding="utf-8") as f:
            arch = json.load(f)["arch"]
        source = "manifest.json"
    except (OSError, ValueError, KeyError) as error:
        print(f"arch:            built-in defaults "
              f"({type(error).__name__} reading manifest.json)")
        return

    variant = _preference("f5Variant")
    if variant == "f5tts_base":
        arch.update(text_mask_padding=False, pe_attn_head=1)
        source += " + Settings override (F5-TTS Base)"
    elif variant == "f5tts_v1_base":
        arch.update(text_mask_padding=True, pe_attn_head=None)
        source += " + Settings override (F5-TTS v1 Base)"
    F5_ARCH_JSON = json.dumps(arch, sort_keys=True)
    print(f"arch:            {F5_ARCH_JSON} ({source})")


def _preference(key):
    """One value out of sr's preferences, or None. Read-only, no defaults(1)."""
    import plistlib

    path = os.path.expanduser(
        "~/Library/Preferences/com.patrickellis.sr.plist")
    try:
        with open(path, "rb") as f:
            return plistlib.load(f).get(key)
    except Exception:
        return None


def _describe(label, path):
    try:
        size = os.path.getsize(path)
        print(f"{label:<16} {size:>14,} bytes  {path}")
    except OSError as error:
        print(f"{label:<16} {type(error).__name__:>14}  {path}")


def self_test(voice=None):
    """Run the offline Norwegian stack in the foreground, and say what fails.

    The daemon reports an unexpected exception by class name alone because its
    message could quote the text being read (P-5). That is the right trade for
    a running daemon and the wrong one when the question is which of a dozen
    setup problems you have — `RuntimeError` is what mlx raises for a
    checkpoint that is missing, truncated or stored in a dtype it cannot read,
    what Metal raises when it cannot allocate, and what soundfile subclasses
    for a clip it cannot decode. Here the text is a fixed literal, so there is
    nothing to protect and the exception is printed whole.
    """
    import platform
    import traceback

    # Mirror the daemon's own log lines to the terminal: how far the load got
    # is half the answer, and nobody should have to tail a file to see it.
    global log
    to_file = log

    def log(message):
        print(f"  {message}")
        to_file(message)

    print(f"python:          {platform.python_version()} ({sys.executable})")
    _self_test_paths()

    for module in ("mlx", "mlx_audio", "f5_tts_mlx", "vocos_mlx", "soundfile"):
        try:
            import importlib.metadata as metadata
            print(f"{module + ':':<16} {metadata.version(module.replace('_', '-'))}")
        except Exception as error:
            print(f"{module + ':':<16} NOT INSTALLED ({type(error).__name__})")

    try:
        import mlx.core as mx
        device_info = getattr(mx, "device_info", None) or mx.metal.device_info
        limit = device_info().get("max_recommended_working_set_size", 0)
        print(f"metal budget:    {limit:,} bytes")
    except Exception as error:
        print(f"metal budget:    unavailable ({type(error).__name__})")

    print()
    _describe("weights:", os.path.join(F5_MODEL_PATH, "model_v1.safetensors"))
    _describe("vocab:", os.path.join(F5_MODEL_PATH, "vocab.txt"))
    _describe("vocoder:", os.path.join(F5_VOCODER_PATH, "model.safetensors"))
    _describe("vocoder config:", os.path.join(F5_VOCODER_PATH, "config.yaml"))

    voices = sorted(
        name for name in (os.listdir(F5_VOICES_PATH) if os.path.isdir(F5_VOICES_PATH) else [])
        if os.path.isdir(os.path.join(F5_VOICES_PATH, name)) and not name.startswith("."))
    print(f"voices:          {', '.join(voices) if voices else 'NONE'}")
    voice = voice or (voices[0] if voices else None)
    if voice is None:
        print("\nNo reference voice to read with — record one in Settings → Voices.")
        return 1
    _describe("ref.wav:", os.path.join(F5_VOICES_PATH, voice, "ref.wav"))
    _describe("ref.txt:", os.path.join(F5_VOICES_PATH, voice, "ref.txt"))

    for step, run in (
        ("loading the model", load_f5_model),
        (f"reading a sentence as {voice!r}",
         lambda: _f5_generate_segments(SELF_TEST_TEXT, voice, None)),
    ):
        print(f"\n== {step} ==")
        started = time.time()
        try:
            result = run()
        except Exception:
            print(f"FAILED after {time.time() - started:.1f}s\n")
            traceback.print_exc()
            return 1
        elapsed = time.time() - started
        if isinstance(result, list):
            samples = sum(audio.size for audio, _ in result)
            print(f"ok in {elapsed:.1f}s — {samples / F5_SAMPLE_RATE:.1f}s of audio")
        else:
            print(f"ok in {elapsed:.1f}s")

    print("\nThe offline Norwegian voice works from here. If reads still fail "
          "in sr, quit every sr window and reopen it so the daemon restarts.")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        rest = [a for a in sys.argv[1:] if a != "--self-test"]
        sys.exit(self_test(voice=rest[0] if rest else None))
    main()
