import contextlib
import importlib.util
import pathlib
import unittest
import unittest.mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "sr_tts_server", ROOT / "daemon" / "sr_tts_server.py"
)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class FakeConnection:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.timeout = None

    def settimeout(self, timeout):
        self.timeout = timeout

    def recv(self, _size):
        return self.chunks.pop(0) if self.chunks else b""


class RequestReaderTests(unittest.TestCase):
    def test_rejects_oversized_line_even_when_newline_arrives_with_it(self):
        conn = FakeConnection([b"x" * (server.MAX_REQUEST_BYTES + 1) + b"\n"])
        with self.assertRaises(server.RequestTooLarge):
            server._read_request_line(conn)

    def test_returns_only_first_request_line(self):
        conn = FakeConnection([b'{"token":"a"}\nignored'])
        self.assertEqual(server._read_request_line(conn), b'{"token":"a"}')


@unittest.skipUnless(
    importlib.util.find_spec("numpy"), "numpy not installed"
)
class TrimEdgeSilenceTests(unittest.TestCase):
    SAMPLE_RATE = 24000

    def _segment(self, lead_s, speech_s, trail_s):
        import numpy as np

        lead = np.zeros(int(lead_s * self.SAMPLE_RATE), dtype=np.float32)
        speech = np.full(int(speech_s * self.SAMPLE_RATE), 0.5, dtype=np.float32)
        trail = np.zeros(int(trail_s * self.SAMPLE_RATE), dtype=np.float32)
        return np.concatenate([lead, speech, trail])

    def test_trims_edges_keeping_pad(self):
        audio = self._segment(0.4, 1.0, 0.6)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        expected = (1.0 + 2 * server.TRIM_PAD_SECONDS) * self.SAMPLE_RATE
        self.assertAlmostEqual(trimmed.size, expected, delta=2)

    def test_short_edges_left_alone(self):
        audio = self._segment(0.02, 1.0, 0.02)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        self.assertEqual(trimmed.size, audio.size)

    def test_all_silent_segment_untouched(self):
        import numpy as np

        audio = np.zeros(6000, dtype=np.float32)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        self.assertEqual(trimmed.size, 6000)

    def test_empty_segment_untouched(self):
        import numpy as np

        audio = np.zeros(0, dtype=np.float32)
        self.assertEqual(server._trim_edge_silence(audio, self.SAMPLE_RATE).size, 0)

    def test_quiet_speech_trims_relative_to_peak(self):
        audio = self._segment(0.4, 1.0, 0.6) * 0.01
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        expected = (1.0 + 2 * server.TRIM_PAD_SECONDS) * self.SAMPLE_RATE
        self.assertAlmostEqual(trimmed.size, expected, delta=2)


class IdleWatchdogTests(unittest.TestCase):
    def test_active_client_blocks_idle_exit(self):
        original_time = server.last_request_time
        original_active = server.active_clients
        try:
            server.last_request_time = 0
            server.active_clients = 1
            should_exit, _, active = server._idle_state(server.IDLE_TIMEOUT + 1)
            self.assertFalse(should_exit)
            self.assertEqual(active, 1)

            server.active_clients = 0
            should_exit, _, _ = server._idle_state(server.IDLE_TIMEOUT + 1)
            self.assertTrue(should_exit)
        finally:
            server.last_request_time = original_time
            server.active_clients = original_active


class OutputVersionTests(unittest.TestCase):
    def test_successful_response_identifies_live_output_semantics(self):
        import json
        import tempfile
        from unittest.mock import patch, Mock

        conn = Mock()
        request = json.dumps({"token": "test", "text": "test", "voice": "bf_lily"}).encode()
        with tempfile.NamedTemporaryFile() as audio:
            audio.write(b"audio")
            audio.flush()
            with patch.object(server, "AUTH_TOKEN", "test"), \
                    patch.object(server, "_read_request_line", return_value=request), \
                    patch.object(server, "_client_gone", return_value=False), \
                    patch.object(server, "generate_audio", return_value=audio.name), \
                    patch.object(server, "_release_model_scratch"), patch.object(server, "log"):
                server.handle_client(conn)
        response = json.loads(conn.sendall.call_args.args[0])
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["output_version"], "kokoro-82M-t2")


class GenerationFailureTests(unittest.TestCase):
    def test_exhausted_workarounds_fail_instead_of_returning_silence(self):
        import sys
        from unittest.mock import patch, Mock

        model = Mock()
        model.generate.side_effect = ValueError("[broadcast_shapes] secret text")
        # This path must raise before any array operations, so it can be
        # verified without downloading numpy or the actual voice model.
        with patch.object(server, "model", model), patch.object(server, "log"), \
                patch.dict(sys.modules, {"numpy": Mock()}):
            with self.assertRaisesRegex(server.EngineError, "^local synthesis workaround exhausted$"):
                server._generate_segments("fragment", "bf_lily", 1, "b", None)
        self.assertEqual(model.generate.call_count, 4)

    def test_unrelated_model_errors_are_not_retried(self):
        import sys
        from unittest.mock import patch, Mock

        model = Mock()
        model.generate.side_effect = ValueError("unrelated")
        with patch.object(server, "model", model), \
                patch.dict(sys.modules, {"numpy": Mock()}):
            with self.assertRaises(ValueError):
                server._generate_segments("fragment", "bf_lily", 1, "b", None)
        self.assertEqual(model.generate.call_count, 1)


if __name__ == "__main__":
    unittest.main()


class EngineRoutingTests(unittest.TestCase):
    """The daemon serves two engines over one socket; each request says which."""

    def _handle(self, request_obj, **patches):
        import json
        import tempfile
        from unittest.mock import patch, Mock

        conn = Mock()
        request = json.dumps(request_obj).encode()
        with tempfile.NamedTemporaryFile() as audio:
            audio.write(b"audio")
            audio.flush()
            context = {
                "AUTH_TOKEN": "test",
                "_read_request_line": lambda _conn: request,
                "_client_gone": lambda _conn: False,
                "generate_audio": lambda *a, **k: audio.name,
                "_release_model_scratch": lambda: None,
                "log": lambda *a: None,
            }
            context.update(patches)
            with contextlib.ExitStack() as stack:
                for name, value in context.items():
                    stack.enter_context(patch.object(server, name, value))
                server.handle_client(conn)
        return json.loads(conn.sendall.call_args.args[0])

    def test_f5_response_uses_its_own_output_version(self):
        response = self._handle(
            {"token": "test", "text": "Hei.", "voice": "min-stemme",
             "lang_code": "n", "engine": "f5"},
            f5_configured=lambda: True)
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["output_version"], "f5-tts-no-t1")

    def test_unknown_engine_is_refused(self):
        response = self._handle(
            {"token": "test", "text": "x", "voice": "bf_lily", "engine": "espeak"})
        self.assertEqual(response["status"], "error")
        self.assertEqual(response["message"], "invalid request fields")

    def test_f5_refused_when_not_installed(self):
        response = self._handle(
            {"token": "test", "text": "Hei.", "voice": "min-stemme", "engine": "f5"},
            f5_configured=lambda: False)
        self.assertEqual(response["status"], "error")
        self.assertEqual(response["message"], "engine not installed")

    def test_f5_voice_id_cannot_escape_the_voices_directory(self):
        for voice in ("../../etc", "has/slash", "Upper", "has.dot", ""):
            response = self._handle(
                {"token": "test", "text": "Hei.", "voice": voice, "engine": "f5"},
                f5_configured=lambda: True)
            self.assertEqual(response["message"], "invalid request fields", voice)

    def test_engine_errors_reach_the_client_verbatim(self):
        """The daemon's own diagnosis is the only clue the app can show.

        Before this, every generation failure arrived as the exception class
        name, so a missing reference recording and a corrupt checkpoint were
        both "RuntimeError" behind an HTTP 500.
        """
        def boom(*_a, **_k):
            raise server.EngineError("voice is missing its reference recording")

        response = self._handle(
            {"token": "test", "text": "Hei.", "voice": "min-stemme",
             "engine": "f5"},
            f5_configured=lambda: True, generate_audio=boom)
        self.assertEqual(response["status"], "error")
        self.assertEqual(response["message"],
                         "voice is missing its reference recording")

    def test_unexpected_exceptions_still_hide_their_message(self):
        """P-5: an exception sr did not author may quote the text being read.

        Its class and the frames it came from cannot, and those are what make
        the difference between a name to look up and a name to guess at.
        """
        def boom(*_a, **_k):
            raise ValueError("secret text the user selected")

        response = self._handle(
            {"token": "test", "text": "Hei.", "voice": "min-stemme",
             "engine": "f5"},
            f5_configured=lambda: True, generate_audio=boom)
        self.assertEqual(response["status"], "error")
        self.assertNotIn("secret", str(response))
        self.assertTrue(response["message"].startswith("ValueError at "),
                        response["message"])
        self.assertIn("test_server.py:", response["message"])

    def test_traceback_frames_name_places_not_content(self):
        try:
            raise ValueError("secret text the user selected")
        except ValueError as e:
            frames = server._traceback_frames(e)
        self.assertNotIn("secret", frames)
        self.assertIn("test_server.py:", frames)

    def test_kokoro_still_rejects_the_hyphen_f5_allows(self):
        response = self._handle(
            {"token": "test", "text": "x", "voice": "bf-lily"})
        self.assertEqual(response["message"], "invalid request fields")


class F5ArchTests(unittest.TestCase):
    """SR_F5_ARCH decides how the checkpoint is interpreted."""

    def _arch(self, json_text):
        from unittest.mock import patch
        with patch.object(server, "F5_ARCH_JSON", json_text), \
                patch.object(server, "log", lambda *a: None):
            return server.f5_arch()

    def test_defaults_to_the_base_architecture(self):
        arch = self._arch("")
        self.assertEqual(arch["pe_attn_head"], 1)
        self.assertFalse(arch["text_mask_padding"])

    def test_explicit_null_pe_attn_head_means_every_head(self):
        # A missing key would leave the default of 1 in place, so the Swift
        # side writes null explicitly; this is the other half of that contract.
        arch = self._arch('{"pe_attn_head": null, "text_mask_padding": true}')
        self.assertIsNone(arch["pe_attn_head"])
        self.assertTrue(arch["text_mask_padding"])

    def test_unknown_keys_are_ignored(self):
        arch = self._arch('{"dim": 512, "not_a_real_knob": 3}')
        self.assertEqual(arch["dim"], 512)
        self.assertNotIn("not_a_real_knob", arch)

    def test_unparseable_json_falls_back_to_defaults(self):
        self.assertEqual(self._arch("{not json"), server.F5_DEFAULT_ARCH)


class NamedFailureTests(unittest.TestCase):
    """An offline failure has to name itself.

    mlx answers a missing, truncated or unreadable checkpoint with a bare
    `RuntimeError`, and soundfile answers an unreadable clip with a subclass
    of one. Reported by class alone they all reach the menu bar as
    "Offline synthesis failed (RuntimeError)", which names neither the file
    nor the fix — so every phase that can fail for an ordinary, non-content
    reason says what it was doing, or what to do about it.
    """

    def setUp(self):
        self._logged = []
        patcher = unittest.mock.patch.object(
            server, "log", lambda message: self._logged.append(message))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_missing_file_names_what_is_damaged(self):
        with self.assertRaises(server.EngineError) as caught:
            server._require_files(server.MODEL_FILES_DAMAGED, "/nonexistent/model.safetensors")
        self.assertEqual(str(caught.exception), server.MODEL_FILES_DAMAGED)

    def test_empty_file_counts_as_damaged(self):
        import tempfile
        with tempfile.NamedTemporaryFile() as empty:
            with self.assertRaises(server.EngineError) as caught:
                server._require_files(server.VOCODER_DAMAGED, empty.name)
        self.assertEqual(str(caught.exception), server.VOCODER_DAMAGED)

    def test_phase_names_itself_when_there_is_no_single_fix(self):
        with self.assertRaises(server.EngineError) as caught:
            with server.during("generating Norwegian speech"):
                raise RuntimeError("secret text the user selected")
        self.assertEqual(str(caught.exception),
                         "RuntimeError while generating Norwegian speech")
        self.assertNotIn("secret", str(caught.exception))

    def test_phase_with_one_fix_reports_the_fix(self):
        with self.assertRaises(server.EngineError) as caught:
            with server.during("reading the Norwegian model weights",
                               server.MODEL_FILES_DAMAGED):
                raise RuntimeError("[load_safetensors] Invalid json header length")
        self.assertEqual(str(caught.exception), server.MODEL_FILES_DAMAGED)

    def test_the_class_and_frames_still_reach_the_log(self):
        with self.assertRaises(server.EngineError):
            with server.during("loading the mel vocoder", server.VOCODER_DAMAGED):
                raise RuntimeError("secret text the user selected")
        logged = " ".join(self._logged)
        self.assertIn("RuntimeError", logged)
        self.assertIn("test_server.py:", logged)
        self.assertNotIn("secret", logged)

    def test_running_out_of_memory_is_not_reported_as_a_mystery(self):
        for failure in (MemoryError(),
                        RuntimeError("[metal::malloc] Attempting to allocate 99 GB")):
            with self.assertRaises(server.EngineError) as caught:
                with server.during("generating Norwegian speech",
                                   server.MODEL_FILES_DAMAGED):
                    raise failure
            self.assertTrue(str(caught.exception).startswith("ran out of memory"),
                            str(caught.exception))

    def test_cancellation_is_never_turned_into_a_failure(self):
        with self.assertRaises(server.CancelledError):
            with server.during("generating Norwegian speech"):
                raise server.CancelledError("client disconnected")

    def test_an_already_named_failure_passes_through_unchanged(self):
        with self.assertRaises(server.EngineError) as caught:
            with server.during("generating Norwegian speech"):
                raise server.EngineError("reference recording is too short")
        self.assertEqual(str(caught.exception), "reference recording is too short")
