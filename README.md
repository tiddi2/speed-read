# sr

**Select text in any Mac app, press a hotkey, hear it read aloud in a state-of-the-art AI voice.**

sr is a privacy-first text-to-speech utility for macOS. It lives in your menu bar, reads whatever you select — articles, PDFs, emails, docs — using ElevenLabs cloud voices or a fully offline local model, at any speed from 0.5× to 3× with pitch preserved. Every byte that leaves your machine is explicit, minimal, and controllable: no telemetry, no content in logs, cloud history auto-deleted after every read, and a Local-Only mode where text never leaves the Mac at all.

## Features

- **Read anything, anywhere** — a global hotkey per language (default ⌥A English, ⌥⇧A Norwegian) speaks the current selection in Safari, Chrome, Preview PDFs, VS Code, Slack, Mail, Terminal. Accessibility-API capture first; clipboard fallback restores your clipboard byte-for-byte.
- **One language per hotkey, never a third** — each language has its own voice and model, and the language is pinned on the request (`language_code`) instead of being detected from the text. Norwegian is cloud-only: the offline voice has no Norwegian, so it is never substituted.
- **Fully rebindable** — every hotkey (speak, clipboard, pause, stop, ±sentence, ±5 s, restart, speed) is configurable in Settings → Shortcuts.
- **Top-tier voices** — ElevenLabs (Flash v2.5 / Turbo / Multilingual v2 / v3) with your account's full voice list, or the local Kokoro model (free, offline, Apple Silicon).
- **Instant, pitch-perfect speed** — 0.5×–3.0× applied client-side with time-domain (WSOLA) stretching. Changing speed never re-generates audio and never costs credits.
- **Full transport** — play/pause, ±1 sentence, ±5 s seek, restart, stop, live progress, from the menu bar panel or the keyboard.
- **See what you're hearing** — an optional borderless reader floats over whatever you're reading from, showing the previous, current and next sentence *in full* with the spoken word highlighted, plus play/pause, sentence stepping, speed and language. Nothing is truncated: the window sizes itself to the text. It never takes focus, so your selection survives.
- **Smart text cleanup** — PDF line-break repair, LaTeX math to spoken English, Markdown stripping, citations, units, URLs — ported from [Speak11](https://github.com/smcantab/speak11) and parity-tested.
- **Cache-first** — repeated reads are instant and free (content-addressed local cache, size-capped, purgeable, disableable, with burst writes coalesced into one maintenance sweep).
- **Bounded read-ahead** — prepares only the current sentence plus five ahead; pausing prevents new requests and stopping cancels pending work. Requests already sent may still be billed.
- **Cost controls** — live credit display, exact per-read billing, daily budget with warning/hard-stop, large-read confirmation, and a 250,000-character per-read ceiling.
- **Privacy by construction** — see [Privacy](#privacy).

## Requirements

- macOS 14+ on Apple Silicon
- Swift 6 toolchain (Xcode Command Line Tools are enough: `xcode-select --install`)
- An [ElevenLabs](https://elevenlabs.io) API key for cloud voices (free tier works), and/or ~330 MB of disk for the offline voice
- [`uv`](https://docs.astral.sh/uv/) only if you install the offline voice

## Install

```sh
git clone https://github.com/OneRedOak/speed-read.git
cd speed-read
make install        # builds sr.app and installs it to /Applications
```

Then, one-time setup:

1. **Grant Accessibility** when prompted (System Settings → Privacy & Security → Accessibility → enable **sr**). This is what lets sr read your selection; the hotkey itself works without it.
2. **Add your ElevenLabs key**: menu bar → waveform icon → Settings… → Cost → paste key → Save. It is stored only in the macOS Keychain. Recommended: create a dedicated key scoped to *Text-to-Speech + User Read*, and opt out of training under ElevenLabs → Terms & Privacy → Data Use.
3. *(Optional, for offline use)* click **Install Local Voice (Kokoro, ~330 MB)** in Settings → General. The Python version and full dependency closure are pinned and hash-verified; the model revision and behavior-defining files are checksum-verified too.
4. *(Optional)* System Settings → General → Login Items → **+** → `/Applications/sr.app` to start at login.

## Usage

| Action | How |
|---|---|
| Speak selection — English | Select text anywhere, press **⌥A** (re-press replaces the current read) |
| Speak selection — Norwegian | Same, **⌥⇧A** |
| Pause / resume | **⌥⇧.** or the menu panel |
| Previous / next sentence | **⌥⇧,** / **⌥⇧/** or the menu panel |
| Slower / faster | **⌥⇧[** / **⌥⇧]** (±0.1×) |
| Seek, restart, stop | Menu bar panel, or bind hotkeys in Settings → Shortcuts |
| Show / hide the reader overlay | Settings → General, the overlay's ✕, or a hotkey you bind |
| Speak clipboard | Menu → Speak Clipboard → Norwegian / English |
| Change hotkeys | Settings (⌘,) → Shortcuts |
| Voice & model per language | Settings (⌘,) → Voices |
| Backend | Settings → General: **Auto** (cloud, falls back to local), **Cloud**, **Local 🔒** |

### The reader overlay

While sr speaks, a borderless window floats in the top-right of the display
your selection is on, showing the previous, current and next sentence with the
word being spoken highlighted — drag it anywhere and sr puts it back there
next time. Settings → General switches the overlay off, or any of the three
sentence lines individually. The speed and language it shows are readouts, not
controls: the language is fixed for the life of a read (it is chosen by which
hotkey started it), and the speed is changed with ⌥⇧[ / ⌥⇧].

All three sentences are shown whole — no ellipsis, no clipped line — and the
window's height follows the text. Only a sentence long enough to fill the
screen (the chunker allows up to 5,000 characters, which means minified text
or OCR without punctuation, not prose) stops it growing; then the pane scrolls
and keeps the sentence being read in view, so the text is still all there.

Two things worth knowing about it:

- **It shows what is spoken, not what you selected.** The text is sr's
  normalized form — LaTeX read out in words, PDF line breaks repaired,
  citations dropped — because that is what the voice is saying.
- **The word cursor is an estimate.** No TTS backend sr uses returns word
  timings, and cached audio could not carry them anyway, so the position is
  derived from playback progress through the sentence, weighted by word length
  and punctuation. It is re-anchored at every sentence boundary, so it can be a
  word out inside a sentence but never drifts beyond one. The sentence it
  emphasizes is always the one being read.

sr does not highlight in the source app itself. There is no cross-application
way to draw into another app's text: Accessibility exposes bounds for a text
range only in the apps that implement it, the normalized text no longer lines
up with the source characters, and the source view scrolls and reflows while
you listen. A floating window behaves the same everywhere, which is the point
of "select anywhere".

sr only ever reads Norwegian or English, and only the one you asked for. The
language is sent to ElevenLabs as `language_code`, which pins both the model and
its text normalization — so a Norwegian selection is never read as English or
anything else. Only **Flash v2.5** and **Turbo v2.5** accept that parameter;
Settings → Voices warns if you pick Multilingual v2 or v3, which detect the
language from the text instead. Kokoro has no Norwegian voice, so Norwegian
reads always use ElevenLabs and are refused (not substituted) in Local-Only mode.

CLI (same binary):

```sh
/Applications/sr.app/Contents/MacOS/sr --speak article.md      # or "-" for stdin
/Applications/sr.app/Contents/MacOS/sr --speak artikkel.md --lang no
/Applications/sr.app/Contents/MacOS/sr --speak-clipboard --local
# Explicitly bypass cloud budget/large-read gates for one invocation:
/Applications/sr.app/Contents/MacOS/sr --speak article.md --override-cost-controls
```

## Privacy

- **Keychain-only credentials** — the API key never touches a config file or environment variable; the UI shows at most its last 4 characters.
- **Clipboard integrity** — the ⌘C fallback snapshots and restores your full clipboard (images, RTF, files), verifies ownership via change count, and restores again if a delayed copy arrives after timeout.
- **Concealed-content refusal** — content marked protected through Accessibility or concealed through `org.nspasteboard.ConcealedType` is never spoken, cached, logged, or transmitted.
- **Content-free logging** — logs record counts, latencies, and status codes. Never your text.
- **The reader overlay is local and transient** — it renders text that is already being read on this Mac, holds it only while the read is in progress, drops it on stop, and never writes it anywhere. Turn it off in Settings → General if a screen is the wrong place for what you're reading.
- **Cloud history auto-delete** — every ElevenLabs generation is deleted from your account history seconds after synthesis (on by default; best-effort — see ElevenLabs' retention docs for backup windows).
- **Per-app routing** — block sr in specific apps or force the local voice for sensitive ones (`~/Library/Application Support/sr/rules.json`); password managers are blocked out of the box.
- **Private audio cache** — the cache directory is owner-only (0700), new audio files are owner-only (0600), and caching stays disabled if the private directory cannot be established. Existing cache directory permissions are repaired at startup, including removal of extended ACL grants.
- **Zero telemetry.** The complete list of hosts sr will ever contact:

| Host | When |
|---|---|
| `api.elevenlabs.io` | Cloud synthesis, voice list, credits, history deletion |
| `huggingface.co` | Only during the explicit local-voice install |
| `github.com` / PyPI | Only during the explicit local-voice install (pinned Python packages) |

Local synthesis runs in a supervised daemon bound to a Unix socket (0600) with per-launch auth, bounded pre-auth connections, request-size limits, verified-model-only startup, and parent/idle watchdogs — no network listener, ever.

## Uninstall

```sh
osascript -e 'quit app "sr"'
rm -rf /Applications/sr.app ~/Library/Application\ Support/sr ~/Library/Logs/sr
security delete-generic-password -a elevenlabs -s "sr — ElevenLabs API Key"
defaults delete com.patrickellis.sr
```

Then remove **sr** from System Settings → Privacy & Security → Accessibility.

## Development

```sh
make build     # debug build
make test      # core + app CLI + daemon unit tests and normalization parity
make app       # release build → dist/sr.app (locally signed)
make run       # build + launch from dist/
```

Two toolchain notes:

- **Signing / Accessibility across rebuilds**: without a codesigning identity, builds are ad-hoc signed and macOS forgets the Accessibility grant after every rebuild. Create a self-signed code-signing certificate named `sr-dev` (Keychain Access → Certificate Assistant → Create a Certificate… → type *Code Signing*) and `build-app.sh` picks it up automatically, making the grant stick.
- **`make test` targets a Command-Line-Tools-only toolchain** (it wires the Swift Testing framework paths manually). With full Xcode installed, plain `swift test` should also work.

Layout: `Sources/SRCore` (engine: normalizer, providers, cache, cost, privacy), `Sources/sr` (menu bar app, playback, capture, CLI), `daemon/` (local TTS daemon plus its hashed dependency lock), `Tests/` (core, app CLI, daemon, and parity tests). `PROGRESS.md` tracks the build log and roadmap (Shortcuts, MCP server, URL scheme, notarized releases).

## Credits

- [Speak11](https://github.com/smcantab/speak11) (Unlicense) — the reference implementation whose text-normalization rules, capture strategy, and fallback design sr ports and builds on. Read it; it's good.
- [Kokoro](https://huggingface.co/mlx-community/Kokoro-82M-bf16) via [mlx-audio](https://github.com/Blaizzy/mlx-audio) — the local voice.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT) — hotkey registration.

## License

[MIT](LICENSE)
