# Changelog

## Unreleased

- Normalization now follows the language of the read instead of always
  injecting English. A `Reading language` preference (menu panel, or
  `--language en|nb` on the CLI) selects the words the normalizer spells out:
  percent forms ("50 %" → "50 prosent", "12 wt %" → "12 vektprosent",
  LaTeX `\%`), the abbreviation table (`f.eks.` → "for eksempel", `dvs.`,
  `jf.`, `ca.` and friends), and the logic connectives (∧ ∨ ¬ → "og", "eller",
  "ikke"). English is the default and is byte-identical to before.

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
