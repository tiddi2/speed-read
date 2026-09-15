# sr — build progress

PRD: see conversation / repo root. Reference implementation: [Speak11](https://github.com/smcantab/speak11) (Unlicense) — clone it into `reference/` (gitignored) to compare against the ported code.

## Decisions (Phase 0, 2026-07-06)

| Q | Decision |
|---|---|
| Q-1 Name | **sr** — CLI `sr`, bundle `com.patrickellis.sr`, Keychain item "sr — ElevenLabs API Key", storage `~/Library/Application Support/sr/` |
| Q-2 macOS floor | 14+ (dev machine runs macOS 26.5; no constraint) |
| Q-3 Hotkey dep | `sindresorhus/KeyboardShortcuts` (1 of 2 SPM budget) |
| Q-4 History-ID | **Live-verified 2026-07-06**: streaming TTS response carries `history-item-id` header (also `character-cost` — use it for exact C-1/C-2 accounting instead of estimating). `DELETE /v1/history/{id}` returns 200 `{"status":"ok"}`; history confirmed empty afterwards. Header-first, list-fallback. |
| Q-5 Pause semantics | Superseded: reading is per language, so the single speak hotkey became one per language (⌥A English, ⌥⇧A Norwegian) and every hotkey is rebindable in Settings → Shortcuts. ⌥⇧. stays pause/resume, flanked by ⌥⇧, / ⌥⇧/ for previous/next sentence. Re-pressing a speak hotkey replaces the read; stopping is the menu's or a bound Stop hotkey's job. |
| Q-7 Languages | Norwegian + English only, never auto-detected: the language is chosen by which hotkey you press and pinned as ElevenLabs `language_code`, which only Flash v2.5 / Turbo v2.5 accept. Kokoro has no Norwegian, so Norwegian is cloud-only and never falls back locally. |
| Q-6 Public release | Undecided; keeping CHANGELOG from day one, code written for strangers |
| Build toolchain | Pure SwiftPM + `scripts/build-app.sh` assembling `sr.app` (only CLT installed, no Xcode — works; signing/notarization deferred to Phase 3) |

## Phase 0 audit findings (§6.3)

- **Pasteboard restore: NO.** `Speak11.swift handleHotkey()` posts ⌘C via CGEvent and sleeps 200 ms; `speak.sh` reads `pbpaste`. Nothing snapshots or restores the prior clipboard. Confirms P-3 need.
- **Content on disk: YES.** `speak.sh` writes the full normalized text to `$TMPDIR/speak11_text` (for respeak position tracking) and never deletes it until next run. sr must keep respeak state in memory only.
- **tts.log: content-free** — `tts_server.py` logs `text_len=` only; `speak.sh` logs voice/speed/paths. Exception tracebacks could theoretically embed text; sr logging is content-free by design (P-5).
- **normalize.py temp files: none** (pure stdin→stdout; optional read of `~/.config/speak11/latex_macros.tex`).
- **Install downloads:** python-build-standalone (pinned URL, GitHub) + `mlx-community/Kokoro-82M-bf16` via huggingface_hub — **no checksum verification**. sr adds SHA-256 pinning (P-12).
- **Network endpoints observed in reference:** api.elevenlabs.io only (subscription check + TTS). No telemetry found.
- **Speed:** reference passes `voice_settings.speed` (0.7–1.2) to the API — regenerates on change. sr pins API speed 1.0, client-side time-stretch (F-8).
- **ElevenLabs voice_settings.speed confirmed in current API docs** (default 1.0) — safe to omit/pin.

## Ported-with-gratitude map

| Reference | sr location |
|---|---|
| `normalize.py` (1219 lines: source detect, markdown/latex/pdf front-ends, phases 0/A/B/C/D) | `Sources/SRCore/Normalizer/` |
| `speak.sh` fallback logic (429/network → local), sentence pause `pause/speed` scaling | `SynthesisPipeline` + `PlaybackEngine` |
| `Speak11.swift` CGEvent tap (keycode 44 ⌥⇧, tap re-enable on timeout), ⌘C simulation (vk 8, 200 ms settle) | `HotkeyManager` / `SelectionCapture` (via KeyboardShortcuts for the hotkey itself) |
| `speak11-audio.swift` queue player semantics | `PlaybackEngine` (AVAudioEngine) |
| Voice/model preset lists, ElevenLabs defaults 0.50/0.75/0.00/boost-on | `Providers/ElevenLabs.swift` |
| `tts_server.py` | Phase 2: adapted daemon (Unix socket + token) |

## Status

- [x] Phase 0 — recon, audit, decisions (this file)
- [x] Phase 0 spike B — live verification complete: header present, delete works, history empty after delete.
- [x] Phase 1 code — F-1, F-2, F-3 (ElevenLabs only), F-4 (30/30 parity fixtures), F-5, F-6 minimal, F-8, P-1, P-2, P-3, P-4 (refusal in capture path), P-5, P-11. `dist/sr.app` builds + launches.
- [ ] Phase 1 acceptance — end-to-end speak blocked on: user grants Accessibility to sr.app; user adds ElevenLabs key to Keychain. Then: T-1 capture matrix spot-check, T-2 clipboard integrity, live spike B (history-item-id header).
- [x] Phase 2 code — P-6 HistoryJanitor (on by default; leftover Phase-1 history manually purged, account history verified empty), P-8 routing rules (`rules.json`, password managers blocked) + Local-Only backend mode, P-9 Kokoro daemon (Unix socket + per-launch token), P-10 cache (SHA-256 keys, 500 MB LRU, 30-day TTL, purge + no-cache toggle), P-12 pins (exact Python, fully hashed dependency lock, model rev a71e4d38…, weights SHA-256 recorded), F-3 Kokoro provider + Auto cloud→local fallback (one-way, never local→cloud), F-9 cache-first, C-1 credits + spent-today (exact `character-cost` header), C-2 daily budget 30k w/ 80% warn + hard stop + override, C-3 large-read confirm ≥8k chars. 51 Swift tests + 2 daemon tests green.
- [x] Phase 2 acceptance (2026-07-06):
  - **T-3 concealed refusal ✓** — pasteboard item with `org.nspasteboard.ConcealedType` refused (`CONCEALED-REFUSED`, exit 2); sentinel absent from logs/App Support/prefs.
  - **T-6 privacy sweep ✓** — sentinel phrases spoken through the full cloud pipeline: zero hits in logs, Application Support, UserDefaults; cache filenames are hashes; no lingering temp audio; ElevenLabs history empty immediately after (janitor). Network observation: endpoint-level external verification is best done with a local proxy or Little Snitch; sr's own logs show only elevenlabs events.
  - **T-7 auto fallback ✓** — simulated 429 (SR_SIMULATE_CLOUD_FAILURE=1 seam): `pipeline.fallback` fired, remaining sentences synthesized+played via local Kokoro, exit 0. Cold daemon start ~10 s; GUI pre-warms the daemon at launch when backend ≠ cloud so the warm path meets the 2 s bar.
  - Fixes landed during acceptance: shared daemon token via 0600 `daemon.token` file (GUI+CLI share one daemon); supervisor actor-reentrancy fix (single in-flight startup task); missing `misaki[en]==0.9.4` + pinned spaCy model wheel added to installer (P-12); daemon-side split-retry workaround for mlx-audio 0.4.4 `broadcast_shapes` bug (upstream fix exists post-0.4.4 — **open decision**: bump the mlx-audio pin to a git revision, needs owner sign-off).
  - CLI seed shipped (A-1 partial): `sr --speak <file|->`, `sr --speak-clipboard`, `sr --install-kokoro`, `--local` flag.
- [x] Reader overlay — borderless non-activating `NSPanel` (`ReaderOverlay.swift`) showing prev/current/next sentence with a word cursor, transport, and read-only speed and language readouts. Opens on the display the selection was made on (pointer position at hotkey time — AX gives no portable screen rect for a selection); drag position persists as an offset from that screen's top-right corner, so it survives display and resolution changes. Each of the three sentence lines and the overlay itself toggle in Settings → General. `PlaybackEngine` gained `sentenceProgress` (0…1 within the current sentence) and a 10 Hz UI timer to drive it.
  - **Word timing is estimated** (`ReaderSentence`), not measured: the ElevenLabs endpoint sr uses returns audio only, the Kokoro daemon returns audio only, and cache hits have no timings to return. Words are weighted by spoken-character count plus a punctuation pause, normalized into the sentence, and re-anchored every sentence so error cannot accumulate. **Upgrade path**: ElevenLabs' `…/with-timestamps` endpoint returns per-character alignment — adopting it means a new `SynthesisResult` field, an alignment sidecar in the audio cache (cached audio predating it has none), and no equivalent for Kokoro, so the estimator stays as the floor for both backends regardless.
- [ ] Phase 3 — transport polish, sign/notarize, v1.0
- [ ] Phase 4 — automations (CLI → Shortcuts → MCP → scheme)

## Open items from the 2026-07-07 pre-release audit

Fixed in that pass: daemon request validation + size caps + token-perms repair, runtime model-load pinning (SR_MODEL_PATH from the verified manifest), pipeline error-swallow hang, stale-delivery race, concurrent-capture clipboard clobber, CostLedger atomicity, CLI usage handling, playback engine lifecycle (rate-before-first-chunk, finish-across-pause, orphaned stretch chain, engine idle stop), log O_APPEND + rotate-by-rename, Chunker O(n²) offsets, ElevenLabs URL encoding. Full audit trail: `.review-and-push/triage-20260707-full-repo.md` (untracked).

Resolved in the 2026-07-09 audit-fix pass:

- **Supply chain**: the installer now uses an exact Python version and a fully resolved, hash-locked dependency closure; the bundled lock is checksummed before `uv --require-hashes` runs and recorded in the validated install manifest.
- **Playback correctness and memory**: underruns pause the content clock; completion waits for decode, render, and scheduled-buffer work; decode failures stop visibly; cloud/local payloads are magic-byte checked; encoded chunks replace an unbounded PCM timeline and decode/render work runs off the main actor.
- **Privacy and cost boundaries**: AX protected-content refusal, source-aware routing, Local-mode cloud cancellation, late-copy clipboard recovery, bounded 250,000-character reads, and concurrent per-chunk cloud budget reservations now fail closed.
- **Daemon hardening**: verified-manifest-only model startup, symlink repair, bounded connections, pre-generation disconnect checks, safe socket writes, content-free wire errors, parent/idle watchdogs, and generation-scoped MLX cleanup.
- **Lifecycle, performance, and verification**: shutdown awaits history cleanup and daemon/install tasks; Keychain and installer failures are surfaced; synthesis uses single-flight cache misses; cache maintenance is debounced; app CLI and daemon tests were added; strict-concurrency builds are warning-free; macOS CI runs tests/build/syntax checks and validates the dependency lock.

## Deviations from PRD

- **Normalizer** (documented in `Normalizer.swift`): no ftfy mojibake repair (no Swift equivalent; clipboard text is valid UTF-8); LaTeX accents use the reference's fallback table rather than pylatexenc. 30/30 parity fixtures pass byte-for-byte with these deviations baked into fixture generation.
- **Normalizer language** (extension beyond the reference, which is English-only):
  `Normalizer.normalize` takes a `SpeechLanguage` that defaults to `.english`, so
  the parity fixtures stay byte-identical. `NormalizerLexicon` holds the words
  each language injects; Norwegian overrides the percent forms (bare `%`, the
  `wt/vol/at/mol` compounds, LaTeX `\%`), the abbreviation table, and the logic
  connectives (∧ ∨ ¬). Fixtures for it live in `Tests/SRCoreTests/fixtures-no/`.
  Still English in a Norwegian read, in rough order of how often they show up:
  `Fig./Eq./Ref./No.` expansion, range words ("Figures 1 through 3", "1 to 5"),
  currency names, bare-URL "dot"/"slash", SI unit names, Greek letter names, and
  the whole LaTeX math-to-speech path (`MathSpeech`).
- **Toolchain**: CLT-only (no Xcode) → KeyboardShortcuts pinned to 1.15.0 (newer tags use #Preview macros that need Xcode's plugin) and tests use Swift Testing, not XCTest (`make test` wires the framework paths). Revisit both when Xcode is installed for Phase 3 signing.
