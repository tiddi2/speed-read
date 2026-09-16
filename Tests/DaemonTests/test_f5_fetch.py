import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "sr_f5_fetch", ROOT / "daemon" / "sr_f5_fetch.py"
)
fetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch)


class PickWeightsTests(unittest.TestCase):
    """A community fine-tune names its checkpoint whatever it likes."""

    def test_prefers_safetensors_over_a_pickle(self):
        self.assertEqual(
            fetch.pick_weights(["model_last.pt", "model_last.safetensors"]),
            "model_last.safetensors",
        )

    def test_falls_back_to_a_pickle_when_that_is_all_there_is(self):
        self.assertEqual(
            fetch.pick_weights(["vocab.txt", "model_500000.pt"]), "model_500000.pt"
        )

    def test_picks_the_latest_step(self):
        self.assertEqual(
            fetch.pick_weights([
                "model_10.safetensors",
                "model_1200000.safetensors",
                "model_9000.safetensors",
            ]),
            "model_1200000.safetensors",
        )

    def test_prefers_a_top_level_file_over_a_nested_one(self):
        self.assertEqual(
            fetch.pick_weights(["ckpts/model_99.safetensors", "model_1.safetensors"]),
            "model_1.safetensors",
        )

    def test_never_mistakes_the_duration_predictor_or_vocoder_for_the_model(self):
        self.assertIsNone(
            fetch.pick_weights(["duration_v2.safetensors", "vocos.safetensors"])
        )

    def test_reports_nothing_rather_than_guessing(self):
        self.assertIsNone(fetch.pick_weights(["README.md", "vocab.txt"]))


class PickVocabTests(unittest.TestCase):
    def test_exact_name_wins(self):
        self.assertEqual(
            fetch.pick_vocab(["data/my_vocab.txt", "vocab.txt"]), "vocab.txt"
        )

    def test_falls_back_to_a_fuzzy_match(self):
        self.assertEqual(fetch.pick_vocab(["nb_vocab.txt"]), "nb_vocab.txt")

    def test_absent_vocab_is_reported(self):
        self.assertIsNone(fetch.pick_vocab(["model.safetensors"]))


class PickReferenceTests(unittest.TestCase):
    """A shipped sample gives a working voice with nothing to record."""

    def test_pairs_audio_with_its_transcript(self):
        audio, text = fetch.pick_reference(["ref.wav", "ref.lab", "model.safetensors"])
        self.assertEqual((audio, text), ("ref.wav", "ref.lab"))

    def test_audio_without_a_transcript_is_not_usable(self):
        self.assertEqual(fetch.pick_reference(["ref.wav"]), (None, None))

    def test_vocab_txt_is_not_a_transcript_for_an_unrelated_clip(self):
        self.assertEqual(
            fetch.pick_reference(["vocab.txt", "sample.wav"]), (None, None)
        )


class ArchFromConfigTests(unittest.TestCase):
    """The only thing that can say which F5 architecture a checkpoint is."""

    def _write(self, name, body):
        directory = tempfile.mkdtemp()
        path = pathlib.Path(directory) / name
        path.write_text(body, encoding="utf-8")
        return path

    def test_reads_a_yaml_config(self):
        path = self._write("F5TTS_Base.yaml", """
model:
  name: F5TTS_Base
  arch:
    dim: 1024
    depth: 22
    heads: 16
    ff_mult: 2
    text_dim: 512
    text_mask_padding: False
    conv_layers: 4
    pe_attn_head: 1
""")
        arch = fetch.arch_from_config(path)
        self.assertEqual(arch["pe_attn_head"], 1)
        self.assertIs(arch["text_mask_padding"], False)
        self.assertEqual(arch["depth"], 22)

    def test_a_v1_config_says_every_head(self):
        path = self._write("F5TTS_v1_Base.yaml", """
    text_mask_padding: True
    pe_attn_head: null
""")
        arch = fetch.arch_from_config(path)
        self.assertIsNone(arch["pe_attn_head"])
        self.assertIs(arch["text_mask_padding"], True)

    def test_reads_a_nested_json_config(self):
        path = self._write(
            "config.json",
            '{"model": {"arch": {"dim": 768, "conv_layers": 4}}, "other": [1, 2]}')
        arch = fetch.arch_from_config(path)
        self.assertEqual(arch["dim"], 768)
        self.assertEqual(arch["conv_layers"], 4)

    def test_unrelated_keys_are_not_adopted(self):
        path = self._write("config.yaml", "learning_rate: 7\nbatch_size: 3\n")
        self.assertEqual(fetch.arch_from_config(path), {})

    def test_an_unreadable_config_changes_nothing(self):
        self.assertEqual(fetch.arch_from_config("/nonexistent/config.yaml"), {})

    def test_defaults_match_the_daemons(self):
        # Both sides default to F5-TTS Base; a drift here would make the
        # daemon interpret a checkpoint differently from what was recorded.
        spec = importlib.util.spec_from_file_location(
            "sr_tts_server_for_arch", ROOT / "daemon" / "sr_tts_server.py")
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
        self.assertEqual(fetch.DEFAULT_ARCH, server.F5_DEFAULT_ARCH)


class NormalizeWeightsTests(unittest.TestCase):
    def test_safetensors_are_copied_verbatim(self):
        directory = pathlib.Path(tempfile.mkdtemp())
        source = directory / "model_last.safetensors"
        source.write_bytes(b"not really safetensors, but bytes are bytes")
        destination = directory / "model_v1.safetensors"
        self.assertEqual(fetch.normalize_weights(source, destination), "copied")
        self.assertEqual(destination.read_bytes(), source.read_bytes())


class JsonConfigNullTests(unittest.TestCase):
    def test_a_json_null_pe_attn_head_is_read_not_skipped(self):
        directory = pathlib.Path(tempfile.mkdtemp())
        path = directory / "config.json"
        path.write_text('{"arch": {"pe_attn_head": null, "text_mask_padding": true}}')
        arch = fetch.arch_from_config(path)
        self.assertIn("pe_attn_head", arch)
        self.assertIsNone(arch["pe_attn_head"])
        self.assertIs(arch["text_mask_padding"], True)


class DownloadProgressTests(unittest.TestCase):
    """The installer polls a file for this; a hang and a slow link look the
    same without it."""

    def test_sizes_are_rendered_in_the_units_macos_shows(self):
        self.assertEqual(fetch.human_bytes(1_400_000_000), "1.4 GB")
        self.assertEqual(fetch.human_bytes(412_000_000), "412 MB")
        self.assertEqual(fetch.human_bytes(5_000), "5 KB")

    def test_finds_the_partial_download_in_the_hub_cache(self):
        import os

        root = pathlib.Path(tempfile.mkdtemp())
        blobs = root / "models--akhbar--F5_Norwegian" / "blobs"
        blobs.mkdir(parents=True)
        (blobs / "abc123.incomplete").write_bytes(b"x" * 4096)
        # A finished blob is not progress, and neither is a file elsewhere.
        (blobs / "abc123").write_bytes(b"x" * 99_999)
        (root / "stray.incomplete").write_bytes(b"x" * 50_000)
        self.assertEqual(fetch._inflight_bytes(str(root)), 4096)

    def test_reports_nothing_when_no_download_is_in_flight(self):
        self.assertEqual(fetch._inflight_bytes(tempfile.mkdtemp()), 0)

    def test_progress_file_carries_the_byte_counts(self):
        import json

        path = pathlib.Path(tempfile.mkdtemp()) / "download.progress"
        fetch._progress(str(path), "downloading", "412 MB of 1.4 GB",
                        412_000_000, 1_400_000_000)
        payload = json.loads(path.read_text())
        self.assertEqual(payload["bytes"], 412_000_000)
        self.assertEqual(payload["total"], 1_400_000_000)
        self.assertEqual(payload["stage"], "downloading")

    def test_a_step_with_no_byte_count_omits_the_fields(self):
        import json

        path = pathlib.Path(tempfile.mkdtemp()) / "download.progress"
        fetch._progress(str(path), "normalizing")
        payload = json.loads(path.read_text())
        self.assertNotIn("bytes", payload)
        self.assertNotIn("total", payload)


if __name__ == "__main__":
    unittest.main()
