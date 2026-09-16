#!/usr/bin/env python3
"""Fetch and normalize an F5-TTS checkpoint for sr's Norwegian offline voice.

Run by KokoroInstaller/F5Installer inside the pinned venv. It is the only
part of the local stack that talks to huggingface.co, and it does so once,
on an explicit user action (Settings → General → the Norwegian voice).

Why a fetch step at all, instead of pointing the daemon at a repo id: a
community F5 fine-tune does not follow one naming convention. The checkpoint
may be `model_last.safetensors`, `model_500000.pt`, or anything else; the
vocabulary may or may not sit next to it; the architecture variant may only
be stated in a YAML config. This script resolves all of that ONCE, writes a
fixed layout the daemon can load blind, and reports what it found so the
Swift side can hash-verify and pin it.

Output layout (under --dest):
    model_v1.safetensors   normalized weights (converted from .pt if needed)
    vocab.txt              character vocabulary
and, under --vocoder-dest:
    model.safetensors      Vocos mel vocoder
    config.yaml

A JSON report is written to --report:
    {"revision": "<commit sha>", "weights_source": "...", "arch": {...},
     "reference": {"audio": "<path>", "text": "..."} | null, ...}

Progress is written as a single JSON line to --progress (overwritten), which
the Swift installer polls — the download is gigabytes and a static spinner
tells the user nothing.

Logging is content-free (P-5): file names, byte counts and step names only.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import urllib.request
from pathlib import Path

# Weights we must not mistake for the acoustic model.
_NOT_WEIGHTS = ("duration", "vocos", "vocoder", "optimizer", "vocab")
_AUDIO_SUFFIXES = (".wav", ".mp3", ".flac", ".m4a", ".ogg")
_TRANSCRIPT_SUFFIXES = (".txt", ".lab")

# Most F5 trainings use the stock character vocabulary unchanged, and a repo
# that did not change it often does not bother to ship it. Pinned by content
# hash rather than by commit: what matters is the bytes, and a change upstream
# should stop the install rather than silently alter how text is tokenized.
CANONICAL_VOCAB_URL = (
    "https://raw.githubusercontent.com/SWivid/F5-TTS/main/"
    "src/f5_tts/infer/examples/vocab.txt"
)
CANONICAL_VOCAB_SHA256 = \
    "4e173934be56219eb38759fa8d4c48132d5a34454f0c44abce409bcf6a07ec46"
# The LF copy, deliberately: the CRLF one under data/ carries a \r into every
# symbol and would tokenize nothing correctly.

# F5-TTS Base ("v0") vs F5-TTS v1 Base. Identical tensor shapes, different
# text masking and rotary-embedding placement, so the checkpoint cannot tell
# us which one it is — only a config in the repo can. Defaults match the
# akhbar/F5_Norwegian card, which names the F5Base architecture.
DEFAULT_ARCH = {
    "dim": 1024,
    "depth": 22,
    "heads": 16,
    "ff_mult": 2,
    "text_dim": 512,
    "conv_layers": 4,
    "text_mask_padding": False,
    "pe_attn_head": 1,
}


def _progress(path, stage, detail="", done_bytes=None, total_bytes=None):
    if not path:
        return
    payload = {"stage": stage, "detail": detail}
    if done_bytes is not None:
        payload["bytes"] = int(done_bytes)
    if total_bytes:
        payload["total"] = int(total_bytes)
    try:
        tmp = f"{path}.tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        pass


def human_bytes(count):
    # Decimal units, because that is what macOS and Hugging Face both show.
    if count >= 1_000_000_000:
        return f"{count / 1e9:.1f} GB"
    if count >= 1_000_000:
        return f"{count / 1e6:.0f} MB"
    return f"{count / 1e3:.0f} KB"


def _inflight_bytes(cache_root):
    """Largest partial download currently on disk, in bytes.

    huggingface_hub offers no byte callback, and its progress bar writes to a
    stderr the installer captures whole rather than streams. The bytes are
    observable anyway: every backend writes into the cache before moving the
    finished blob into place, so watching the partial file is backend-agnostic
    in a way that hooking the download loop would not be. The glob is aimed
    straight at `<cache>/<repo>/blobs/*.incomplete` rather than walking the
    tree, so polling it every second stays cheap on a large cache.
    """
    import glob

    best = 0
    pattern = os.path.join(cache_root, "*", "blobs", "*.incomplete")
    for path in glob.glob(pattern):
        try:
            best = max(best, os.path.getsize(path))
        except OSError:
            pass
    return best


def _watch_download(progress_path, stage, total_bytes, stop):
    """Publish download progress until `stop` is set."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE as cache_root
    except Exception:  # noqa: BLE001 — progress is never worth failing over
        return
    while not stop.wait(1.0):
        try:
            done = _inflight_bytes(cache_root)
        except OSError:
            continue
        if not done:
            continue
        detail = human_bytes(done)
        if total_bytes:
            detail = f"{detail} of {human_bytes(total_bytes)}"
        _progress(progress_path, stage, detail, done, total_bytes)


def fetch_canonical_vocab(destination):
    """Download the stock F5-TTS vocabulary, refusing anything unexpected."""
    with urllib.request.urlopen(CANONICAL_VOCAB_URL, timeout=60) as response:
        body = response.read()
    digest = hashlib.sha256(body).hexdigest()
    if digest != CANONICAL_VOCAB_SHA256:
        raise RuntimeError(
            "the stock F5-TTS vocabulary does not match its pinned checksum "
            f"(expected {CANONICAL_VOCAB_SHA256}, got {digest})")
    Path(destination).write_bytes(body)


def text_embed_rows(safetensors_path):
    """Rows in the checkpoint's text embedding, read from the header alone.

    A safetensors file starts with its header length and a JSON header of
    tensor shapes, so this costs one short read rather than loading 1.4 GB.
    The row count is the vocabulary size the checkpoint was trained with,
    which is the only way to tell a matching vocabulary from a wrong one.
    """
    try:
        with open(safetensors_path, "rb") as f:
            length = int.from_bytes(f.read(8), "little")
            if not 0 < length < 100_000_000:
                return None
            header = json.loads(f.read(length))
    except (OSError, ValueError):
        return None
    for key, meta in header.items():
        if key.endswith("text_embed.text_embed.weight") and isinstance(meta, dict):
            shape = meta.get("shape") or []
            if shape:
                return int(shape[0])
    return None


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(4 << 20):
            digest.update(chunk)
    return digest.hexdigest()


# ── Repo inspection ──────────────────────────────────────────────────


def _siblings(info):
    """(name, size, lfs_sha256) for every file in the repo revision."""
    out = []
    for sibling in getattr(info, "siblings", None) or []:
        name = getattr(sibling, "rfilename", None)
        if not name:
            continue
        lfs = getattr(sibling, "lfs", None)
        sha = None
        if lfs is not None:
            sha = lfs.get("sha256") if isinstance(lfs, dict) else getattr(lfs, "sha256", None)
        out.append((name, getattr(sibling, "size", None), sha))
    return out


def _trailing_step(name):
    """Largest number in a checkpoint name — `model_1200000` beats `model_10`."""
    numbers = [int(n) for n in re.findall(r"\d+", Path(name).stem)]
    return max(numbers) if numbers else -1


def pick_weights(names):
    """The acoustic checkpoint: newest .safetensors, else newest .pt/.ckpt."""
    def usable(name, suffixes):
        lower = name.lower()
        return (Path(lower).suffix in suffixes
                and not any(word in lower for word in _NOT_WEIGHTS))

    for suffixes in ({".safetensors"}, {".pt", ".ckpt", ".bin"}):
        candidates = [n for n in names if usable(n, suffixes)]
        if candidates:
            # Prefer a top-level file, then the highest step number, then a
            # stable alphabetical tiebreak so re-installs pick the same file.
            return sorted(
                candidates,
                key=lambda n: (n.count("/"), -_trailing_step(n), n),
            )[0]
    return None


def pick_vocab(names):
    exact = [n for n in names if Path(n).name.lower() == "vocab.txt"]
    if exact:
        return sorted(exact, key=lambda n: (n.count("/"), n))[0]
    fuzzy = [n for n in names if "vocab" in n.lower() and n.lower().endswith(".txt")]
    return sorted(fuzzy, key=lambda n: (n.count("/"), n))[0] if fuzzy else None


def pick_reference(names):
    """A reference clip plus its transcript, when the repo ships one.

    F5-TTS is a zero-shot cloner: it speaks in the voice of a short reference
    recording, so a repo that ships one gives sr a working voice out of the
    box. Convention is `<stem>.wav` next to `<stem>.txt` or `<stem>.lab`.
    """
    stems = {}
    for name in names:
        stems.setdefault(Path(name).stem, {})[Path(name).suffix.lower()] = name
    for stem in sorted(stems):
        entry = stems[stem]
        audio = next((entry[s] for s in _AUDIO_SUFFIXES if s in entry), None)
        text = next((entry[s] for s in _TRANSCRIPT_SUFFIXES if s in entry), None)
        if audio and text:
            return audio, text
    return None, None


def pick_config(names):
    return [
        n for n in names
        if Path(n).suffix.lower() in (".yaml", ".yml")
        or Path(n).name.lower() == "config.json"
    ]


def arch_from_config(path):
    """Read architecture knobs out of a repo config, when there is one.

    Only the fields that change inference are taken, and only when present —
    a config that says nothing leaves the defaults alone.
    """
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    if Path(path).suffix.lower() == ".json":
        try:
            blob = json.loads(text)
        except ValueError:
            return {}
        found = {}
        stack = [blob]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                for key, value in node.items():
                    # None is a real answer for pe_attn_head ("rotate every
                    # head"), so it has to be accepted, not skipped.
                    if key in DEFAULT_ARCH and (value is None
                                                or isinstance(value, (int, bool))):
                        found.setdefault(key, value)
                    elif isinstance(value, (dict, list)):
                        stack.append(value)
            elif isinstance(node, list):
                stack.extend(node)
        return found

    # YAML without a yaml dependency in the hot path: these are flat scalar
    # keys in every F5-TTS config, so a line scan is enough and cannot
    # execute anything the file asks for.
    found = {}
    for line in text.splitlines():
        match = re.match(r"\s*([A-Za-z_]+)\s*:\s*([^#]+?)\s*$", line)
        if not match:
            continue
        key, raw = match.group(1), match.group(2).strip()
        if key not in DEFAULT_ARCH or key in found:
            continue
        if raw.lower() in ("true", "false"):
            found[key] = raw.lower() == "true"
        elif raw.lower() in ("null", "none", "~"):
            found[key] = None
        elif re.fullmatch(r"-?\d+", raw):
            found[key] = int(raw)
    return found


# ── Normalization ────────────────────────────────────────────────────


def normalize_weights(source, destination):
    """Put the checkpoint at `destination` as safetensors.

    A `.safetensors` source is copied verbatim — the daemon's loader already
    strips the `ema_model.` prefix the F5-TTS trainer writes. A `.pt` is a
    pickle, so it is loaded with torch's `weights_only` reader (tensors only,
    no arbitrary code) and re-saved.
    """
    if source.suffix.lower() == ".safetensors":
        shutil.copyfile(source, destination)
        return "copied"

    import torch
    from safetensors.torch import save_file

    blob = torch.load(source, map_location="cpu", weights_only=True)
    for key in ("ema_model_state_dict", "model_state_dict", "state_dict"):
        if isinstance(blob, dict) and key in blob:
            blob = blob[key]
            break
    if not isinstance(blob, dict):
        raise RuntimeError("checkpoint is not a state dict")

    tensors = {
        name: value.contiguous()
        for name, value in blob.items()
        if isinstance(value, torch.Tensor) and value.dtype != torch.bool
    }
    if not tensors:
        raise RuntimeError("checkpoint contains no tensors")
    save_file(tensors, str(destination))
    return "converted"


def resolve_vocab(repo_vocab, repo_vocab_name, checkpoint, progress_path, scratch):
    """Pick the vocabulary this checkpoint was trained with, and prove it fits.

    In order: one the user supplied, the repo's own, then the stock F5-TTS
    one. Whichever is chosen is checked against the checkpoint's text
    embedding — a vocabulary of the wrong size is the wrong vocabulary, and
    it would produce confident nonsense rather than an error at synthesis
    time. Returns (path, human-readable source).
    """
    override = os.environ.get("SR_F5_VOCAB", "") or str(
        Path(scratch).parent / "vocab-override.txt")
    candidates = []
    if os.path.isfile(override):
        candidates.append((override, f"supplied by hand ({override})"))
    if repo_vocab:
        candidates.append((str(repo_vocab), repo_vocab_name))

    expected = text_embed_rows(checkpoint)

    for path, source in candidates:
        if fits(path, expected):
            return path, source

    # Nothing local fit — or there was nothing local. Try the stock one.
    if not candidates or expected is not None:
        _progress(progress_path, "vocab", "stock F5-TTS vocabulary")
        fallback = Path(tempfile.mkdtemp()) / "vocab.txt"
        fetch_canonical_vocab(fallback)
        if fits(fallback, expected):
            return str(fallback), "SWivid/F5-TTS (stock vocabulary)"

    found = ", ".join(
        f"{source} has {vocab_entries(path)}" for path, source in candidates
    ) or "the repo ships none"
    raise RuntimeError(
        "could not find the vocabulary this checkpoint was trained with: it "
        f"expects {expected if expected is not None else 'an unknown number of'} "
        f"symbols, and {found}. If one is posted in the model repo's Community "
        "tab, save it to "
        f"{Path(scratch).parent / 'vocab-override.txt'} and install again.")


def vocab_entries(path):
    """How many symbols a vocabulary file defines, counted as the model does."""
    try:
        return len(Path(path).read_text(encoding="utf-8").split("\n"))
    except OSError:
        return 0


def fits(path, expected):
    """Whether a vocabulary matches the checkpoint's embedding.

    Unknown expectation means an unreadable checkpoint header rather than a
    mismatch, so anything is allowed through rather than blocking the
    install on a check that could not run. The one-symbol tolerance covers a
    file saved without a trailing newline.
    """
    if expected is None:
        return True
    return abs(vocab_entries(path) - expected) <= 1


# ── Main ─────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--revision", default=None,
                        help="pinned commit sha; omitted resolves the default branch")
    parser.add_argument("--dest", required=True)
    parser.add_argument("--vocoder-repo", required=True)
    parser.add_argument("--vocoder-revision", default=None)
    parser.add_argument("--vocoder-dest", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--progress", default=None)
    args = parser.parse_args()

    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    from huggingface_hub import HfApi, hf_hub_download, snapshot_download

    api = HfApi()
    _progress(args.progress, "resolving")
    info = api.model_info(args.repo, revision=args.revision, files_metadata=True)
    revision = getattr(info, "sha", None) or args.revision
    if not revision:
        raise RuntimeError("could not resolve a commit for the model repo")

    files = _siblings(info)
    names = [name for name, _, _ in files]
    sizes = {name: size for name, size, _ in files}
    upstream_hashes = {name: sha for name, _, sha in files if sha}

    weights_name = pick_weights(names)
    vocab_name = pick_vocab(names)
    if not weights_name:
        raise RuntimeError("no model checkpoint found in the repo")

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    def fetch(name, stage, detail=None):
        _progress(args.progress, stage, detail or Path(name).name)
        path = hf_hub_download(args.repo, name, revision=revision)
        expected = upstream_hashes.get(name)
        if expected and sha256_of(path) != expected:
            raise RuntimeError(f"hash mismatch for {Path(name).name}")
        return Path(path)

    # Config first: it is tiny and decides how the weights are interpreted.
    arch = dict(DEFAULT_ARCH)
    arch_source = None
    for name in pick_config(names):
        found = arch_from_config(fetch(name, "config"))
        if found:
            arch.update({k: v for k, v in found.items() if k in DEFAULT_ARCH})
            arch_source = name
            break

    # The step that runs for minutes. A static "downloading…" here is
    # indistinguishable from a hang, so watch the bytes land while it runs.
    weights_bytes = sizes.get(weights_name) or 0
    _progress(args.progress, "downloading",
              human_bytes(weights_bytes) if weights_bytes else "", 0, weights_bytes)
    stop_watching = threading.Event()
    watcher = threading.Thread(
        target=_watch_download,
        args=(args.progress, "downloading", weights_bytes, stop_watching),
        daemon=True)
    watcher.start()
    try:
        weights_path = fetch(
            weights_name, "downloading",
            detail=human_bytes(weights_bytes) if weights_bytes else None)
    finally:
        stop_watching.set()
        watcher.join(timeout=3)
    # A repo that never changed the stock vocabulary often does not ship one.
    # Resolving it is deferred until the checkpoint is on disk, because the
    # checkpoint is the only thing that can say whether a vocabulary fits.
    vocab_path = fetch(vocab_name, "vocab") if vocab_name else None

    reference = None
    audio_name, text_name = pick_reference(names)
    if audio_name and text_name:
        try:
            audio_path = fetch(audio_name, "reference")
            text_path = fetch(text_name, "reference")
            transcript = Path(text_path).read_text(
                encoding="utf-8", errors="replace").strip()
            if transcript:
                reference = {"audio": str(audio_path), "text": transcript}
        except Exception:  # a missing sample must not fail the install
            reference = None

    _progress(args.progress, "normalizing")
    # Write through a temp file in the same directory: a half-written
    # checkpoint that survives a crash would fail verification forever.
    with tempfile.NamedTemporaryFile(dir=dest, suffix=".safetensors",
                                     delete=False) as handle:
        staged = Path(handle.name)
    try:
        mode = normalize_weights(weights_path, staged)
        os.replace(staged, dest / "model_v1.safetensors")
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    vocab_path, vocab_source = resolve_vocab(
        vocab_path, vocab_name, dest / "model_v1.safetensors",
        args.progress, dest)
    shutil.copyfile(vocab_path, dest / "vocab.txt")

    _progress(args.progress, "vocoder")
    vocoder_snapshot = Path(snapshot_download(
        args.vocoder_repo,
        revision=args.vocoder_revision,
        allow_patterns=["*.yaml", "*.safetensors"],
    ))
    vocoder_dest = Path(args.vocoder_dest)
    vocoder_dest.mkdir(parents=True, exist_ok=True)
    for filename in ("model.safetensors", "config.yaml"):
        source = vocoder_snapshot / filename
        if not source.is_file():
            raise RuntimeError(f"vocoder is missing {filename}")
        shutil.copyfile(source, vocoder_dest / filename)

    _progress(args.progress, "verifying")
    report = {
        "repo": args.repo,
        "revision": revision,
        "weights_source": weights_name,
        "weights_mode": mode,
        "weights_bytes": weights_bytes,
        "vocab_source": vocab_source,
        "arch": arch,
        "arch_source": arch_source,
        "reference": reference,
        "vocoder_repo": args.vocoder_repo,
        "vocoder_revision": args.vocoder_revision or "",
        "model_sha256": sha256_of(dest / "model_v1.safetensors"),
        "vocab_sha256": sha256_of(dest / "vocab.txt"),
        "vocoder_sha256": sha256_of(vocoder_dest / "model.safetensors"),
    }
    Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True))
    _progress(args.progress, "done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 — the message is the UI's
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
