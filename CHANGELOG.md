# Changelog

## Unreleased

- Added a reader overlay: a borderless, always-on-top window that shows the
  text while it is read, with the word being spoken highlighted. It appears in
  the top-right of the display the selection was made on, can be dragged
  anywhere (sr remembers the spot relative to that screen's corner), and shows
  the previous, current and next sentence — each of the three can be switched
  off in Settings → General, as can the overlay itself. It carries
  previous-sentence / play-pause / next-sentence buttons, a progress bar, the
  sentence counter, and read-only readouts of the playback speed and the
  language being read. The overlay never takes keyboard focus, so the selection
  in the app you read from stays intact. ⌥⇧[ and ⌥⇧] (new defaults) change the
  speed the readout shows; the overlay itself is bound to no key by default but
  can be given one in Settings → Shortcuts.
  - The word cursor is estimated, not measured: neither backend returns word
    timings, and cached audio has none to return. Each word is weighted by its
    length and the pause its punctuation buys, and the estimate is re-anchored
    at every sentence boundary, so error stays inside one sentence instead of
    accumulating. The sentence the overlay emphasizes is always exact.
  - The overlay shows sr's *normalized* text — the exact strings sent to the
    synthesizer — so what you read is what you hear, with LaTeX spoken out and
    PDF line breaks repaired. It holds that text only while the read is in
    progress and drops it on stop.

- Reading is now per language, and only Norwegian or English. Each language has
  its own hotkey, voice and model, and the language is pinned on the ElevenLabs
  request (`language_code`) rather than detected from the text, so a read never
  drifts into a third language. Norwegian is cloud-only — Kokoro has no
  Norwegian voice, so it is never used as a fallback for it and a Norwegian read
  in Local-Only mode is refused instead of spoken with an English voice. Only
  Flash v2.5 and Turbo v2.5 accept `language_code`; picking Multilingual v2 or
  v3 for a language now shows a warning that the language cannot be locked. The
  audio cache key includes the pinned language, so the same sentence cached as
  English is never replayed for a Norwegian read.
- Every global hotkey is configurable in Settings → Shortcuts: speak selection
  and speak clipboard per language, pause/resume, stop, previous/next sentence,
  ±5 s seek, restart, and speed up/down. Defaults: ⌥A English, ⌥⇧A Norwegian,
  and ⌥⇧, / ⌥⇧. / ⌥⇧/ for previous sentence / pause / next sentence. The rest
  are unset, so sr claims less of the global key space. Replaces the single
  ⌥⇧/ speak hotkey.
- Added sentence-level seeking: previous/next sentence jump on the real chunk
  boundaries, and "previous" restarts the current sentence unless pressed right
  at its start. The menu panel gained buttons for both.
- Moved configuration out of the menu bar panel into the Settings window (⌘,),
  now tabbed: General (backend, offline voice, permissions), Voices (per-language
  voice and model), Shortcuts, Privacy, and Cost (API key, credits, budget). The
  panel keeps transport, progress, speed, and Speak Clipboard — one button per
  language, since sr never guesses what language a clipboard holds.
- CLI: `--lang en|no` selects the language profile; it defaults to English
  rather than letting the model detect the language.

- Fixed jarring pauses between sentences on the local voice at faster playback
  rates: Kokoro bakes ~0.4 s leading / ~0.6 s trailing silence into every
  generated segment, so each boundary carried ~1 s of dead air on top of the
  configured sentence pause. The daemon now trims edge silence per segment
  (keeping a 60 ms natural pad), and the local cache key was bumped so
  previously cached untrimmed audio is re-synthesized.

- Audit hardening: unified GUI/CLI backend routing so Local never reaches the
  cloud and Cloud never silently falls back; added AX protected-content and
  delayed-copy clipboard safeguards; enforced per-chunk cloud budgets and a
  bounded input size; made shutdown await history, installer, and daemon work;
  surfaced Keychain, install, decode, engine, and invalid-audio failures.
- Playback now accounts for pending decode/render/buffer work, pauses its
  content clock during underruns, and stores encoded timeline audio instead of
  unbounded PCM. Decode, resample, normalization, and chunking work runs off the
  main actor.
- Hardened the Kokoro daemon and installer with a fully hashed dependency lock,
  exact Python/model pins, verified-manifest-only startup, bounded connections,
  disconnect checks, safe Unix-socket writes, watchdogs, cancellation cleanup,
  and content-free errors.
- Added synthesis single-flight, debounced cache maintenance, CLI parser and
  daemon tests, warning-free strict-concurrency verification, and macOS CI.

- Phase 2: history auto-delete janitor (P-6, on by default); content-addressed
  audio cache with LRU/TTL/purge/no-cache toggle (P-10/F-9); per-app routing
  rules with password managers blocked by default + Local-Only backend mode
  (P-8); Kokoro local TTS — hardened daemon (Unix socket, per-launch token,
  content-free logs), supervised with backoff, uv-managed installer with
  pinned mlx-audio 0.4.4 and SHA-256-verified model (P-9/P-12); Auto mode
  cloud→local fallback (T-7 wiring); cost controls: exact billed-character
  ledger, 30k/day budget with warning/hard-stop/override, large-read
  confirmation (C-1..C-4).

- Phase 0: cloned Speak11 reference, completed §6.3 privacy audit, recorded
  decisions (name: sr; KeyboardShortcuts dep; history-ID mechanism
  header-first pending live verification). See PROGRESS.md.
- Phase 1 (in progress): SwiftPM scaffold; ElevenLabs streaming provider with
  API speed pinned at 1.0 (F-8); Keychain-only key storage (P-1); AX-first
  selection capture with pasteboard save/restore and concealed-content
  refusal (P-2/P-3/P-4); content-free logging (P-5); sentence chunking with
  bounded-concurrency synthesis (F-5); AVAudioEngine playback with live
  0.5–3.0× pitch-preserving speed (F-8); MenuBarExtra UI with transport,
  speed slider, voice/model pickers, credits display.
