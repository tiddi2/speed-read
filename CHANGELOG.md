# Changelog

## Unreleased

- **Norwegian reads offline.** Kokoro has no Norwegian voice, so until now a
  Norwegian selection always went to ElevenLabs and was refused outright in
  Local-Only mode. Settings → General now offers a second, independent
  download — an [F5-TTS checkpoint trained on
  Norwegian](https://huggingface.co/akhbar/F5_Norwegian), run through
  `f5-tts-mlx` in the same venv, the same supervised daemon and the same 0600
  socket as Kokoro. Install either voice, both, or neither; a daemon starts
  with whatever is there, and loads the Norwegian model only when a Norwegian
  read actually arrives.

  F5-TTS is a zero-shot cloner rather than a model with baked-in speakers: it
  reads in the voice of a short reference recording. So a Norwegian offline
  voice in sr *is* a recording — the sample the model repo ships, if it ships
  one, plus any you add yourself under Settings → Voices. sr converts whatever
  you pick to the 24 kHz mono the model wants, keeps only that copy, and never
  sends it anywhere. The transcript you type has to match the recording word
  for word; that pairing is how F5 lines a voice up with text.

  Two details worth knowing. The install resolves the model repo's layout
  rather than assuming it — a community fine-tune names its checkpoint
  whatever it likes, and may ship `.pt` instead of `.safetensors` — then
  records the commit it resolved and the SHA-256 of every file it wrote, and
  re-checks that record on each launch. `make pin-f5-model` prints those
  values as Swift constants to freeze the model to one commit for good. And
  because the two F5-TTS architectures share every tensor shape, a checkpoint
  cannot be inspected to tell which it is: sr goes by what the repo's config
  declares, and Settings → Voices has a one-click switch for when Norwegian
  comes out as babble rather than speech.

  One thing to do after updating, if you already had the English offline
  voice: the shared dependency lock gained `f5-tts-mlx`, so the existing
  install no longer matches it and Settings → General offers **Update English
  Voice Runtime…**. Click it once — the Kokoro model is already in the
  Hugging Face cache, so it rebuilds the environment rather than
  re-downloading anything. Until then, English reads fall back to the cloud.

- An offline-voice install no longer inherits the user's uv settings. uv reads
  `UV_*` from the environment as well as from `uv.toml`, and sr passed its
  whole environment through — so a `UV_EXCLUDE_NEWER` left in a login shell
  made `uv venv` refuse to start, and the install died before creating
  anything. `--no-config` covers the files but not the variables, so the
  installer now strips `UV_*` from every child process as well. The quieter
  case matters more than the noisy one: a stray `UV_INDEX_URL` would have
  resolved the pinned closure from somewhere else instead of failing outright.

- Installing an offline voice now shows what it is doing, and says so when it
  fails. The Norwegian model is a 1.4 GB download and the only feedback was a
  spinner with a fixed caption, which looks the same at 2% as at 98% as at
  hung. `sr_f5_fetch.py` now reports bytes as they land — huggingface_hub
  offers no byte callback, so it watches the partial file in the hub cache,
  which works whichever download backend is in play — and Settings draws a real
  progress bar with a percentage.

  More importantly, a failed install was invisible. The status label cleared,
  the button came back looking untouched, and the reason went to the same
  transient banner used for a read that went wrong mid-sentence — on screen for
  a moment, gone before it could be read. The most likely failure by far is
  having no `uv` installed, which fails in well under a second, so in practice
  the install appeared to do nothing at all. The error now stays under the
  button until the next attempt, and is selectable, because the useful ones
  name a command to run.

  Both progress and failures also appear in the menu bar panel, which is what
  stays visible once the Settings window is closed — and a download this size
  is exactly the thing you close the window and walk away from.

- A failed signing-identity setup no longer aborts `make update`, and says what
  went wrong when it does fail. `setup-signing.sh` judged its two certificate
  import routes by exit status, but a PKCS#12 that macOS accepts without
  pairing the key to the certificate exits 0 and leaves no identity — so the
  fallback import never ran, and the script gave up with a bare "could not
  create the sr-dev identity" and no hint which half was missing. Both routes
  are now judged by what they leave in the keychain, and their output is shown
  when neither works.

  It also self-signs into a chicken-and-egg: a fresh self-signed certificate is
  not valid for code signing until something trusts it, and the existence check
  lists only *valid* identities — while `trust_certificate()` ran only after
  that check had already passed, so it could never rescue the one case it was
  written for. Trust is now applied before giving up.

  And because the script's own message says a failure means "builds stay ad-hoc
  signed", `install` and `update` no longer stop on it: they warn and carry on,
  which is what that message promises. `make setup-signing` on its own still
  exits non-zero, so the failure is still visible when you ask for it directly.

- Accessibility and Keychain access no longer reset on every `make update`.
  macOS keys the Accessibility (TCC) grant and a Keychain item's ACL on an app's
  code signature, and with no certificate on the machine `codesign` signs
  ad-hoc — an identity that *is* the binary's hash, so it changed with every
  build and each update looked like a brand-new app. The `sr-dev` certificate
  that fixes this existed before but had to be created by hand in Keychain
  Access, and the only hint was a warning printed after the fact; in practice
  builds stayed ad-hoc signed. `scripts/setup-signing.sh` now creates and
  maintains that identity automatically on the first build, so the bundle's
  designated requirement stops moving and one approval holds for good. The key
  lives in its own keychain unlocked from `~/.config/sr`, so signing never
  prompts for the login password either; an `sr-dev` identity you already have
  is adopted rather than replaced, since a new certificate would cost the grant
  it holds. `make reset-permissions` clears the dead TCC rows that earlier
  ad-hoc builds left behind (one per build, each looking enabled while granting
  nothing), and `make signing-status` checks the identity still signs. Saving
  the API key now replaces the keychain item instead of updating it in place: an
  item's ACL is fixed at creation, so one written by an ad-hoc build or by
  `security add-generic-password` named an app that no longer existed and made
  macOS ask for a password on every read. README > Development documents the
  trade-off of keeping a local signing key, and how to undo it.

- sr has an app icon, and can keep a Dock icon while it runs. The artwork is
  generated by `scripts/make-icon.py` (one readable source of truth instead of a
  folder of PNGs) into `resources/sr.icns`, which `build-app.sh` now bundles;
  small sizes drop waveform bars rather than shrinking them, so the 16-point
  icon still reads as speech. sr stays an `LSUIElement` app and raises its
  activation policy at launch instead, so nothing flashes in the Dock before
  preferences are read. "Show sr in the Dock" in Settings → General turns it
  back off; clicking the Dock icon opens Settings.

- Fixed the Settings toolbar icons jittering. The window used to resize itself
  to whatever tab was showing — and again whenever a row inside a tab appeared
  or disappeared ("Saved to Keychain", the install spinner, the language-lock
  warning) — re-laying out the tab bar each time. Every tab is now drawn on one
  fixed canvas and scrolls its own overflow.

- Voices can be listened to while you pick them. Settings → Voices is now a
  searchable list — one language at a time — with a play button on every row,
  for the offline voices too. A sample is synthesized with that language's own
  model and language lock rather than being a canned demo clip, so a Norwegian
  voice is auditioned in Norwegian; samples are one sentence and are cached, so
  hearing the same voice again is instant and free. Auditions respect
  Local-Only mode, the daily budget and history auto-delete like any other read.

- Added custom pronunciations, per language (Settings → Pronunciation). Two
  kinds of entry, matching ElevenLabs' pronunciation dictionaries:
  *respellings* ("Nguyen" → "Nwin"), which sr applies itself right after
  normalization — so they work on every model, work with the offline voice, and
  never leave the Mac — and *phonemes* (IPA or CMU Arpabet), which only
  ElevenLabs can apply and which are uploaded as a pronunciation dictionary and
  referenced on the request. Every entry can be heard both ways before you keep
  it, as it sounds now and as the rule would have it, using inline markup so a
  rule can be tested before it is saved or uploaded. Entries are matched on
  whole words, longest first, in a single pass, so one entry never rewrites
  another's output. The audio cache key carries the dictionary version, so
  editing a pronunciation invalidates exactly the sentences that contained the
  word. Settings warns when a language's chosen model ignores phoneme rules —
  which includes the Flash/Turbo v2.5 pair sr language-locks with.
- Added a reader overlay: a borderless, always-on-top window that shows the
  text while it is read, with the word being spoken highlighted. It appears in
  the top-right of the display the selection was made on, can be dragged
  anywhere (sr remembers the spot relative to that screen's corner), and shows
  the previous, current and next sentence — each of the three can be switched
  off in Settings → General, as can the overlay itself. All three are shown
  whole — nothing is truncated — and the window's height follows the text; a
  sentence too long for the screen makes the pane scroll and follow the read
  rather than clip. It carries previous-sentence / play-pause / next-sentence
  buttons, a progress bar, the sentence counter, and read-only readouts of the
  playback speed and the language being read. The overlay never takes keyboard
  focus, so the selection in the app you read from stays intact. ⌥⇧[ and ⌥⇧]
  (new defaults) change the speed the readout shows; the overlay itself is
  bound to no key by default but can be given one in Settings → Shortcuts.
  - The word cursor is estimated, not measured: neither backend returns word
    timings, and cached audio has none to return. Each word is weighted by its
    length and the pause its punctuation buys, and the estimate is re-anchored
    at every sentence boundary, so error stays inside one sentence instead of
    accumulating. The sentence the overlay emphasizes is always exact.
  - The overlay shows sr's *normalized* text — the exact strings sent to the
    synthesizer — so what you read is what you hear, with LaTeX spoken out and
    PDF line breaks repaired, and with your custom respellings applied. It
    holds that text only while the read is in progress and drops it on stop.

- Normalization now follows the language of the read instead of always injecting
  English words into it. The words the normalizer spells out come from a
  per-language table: percent forms ("50 %" → "50 prosent", "12 wt %" →
  "12 vektprosent", LaTeX `\%`), the abbreviation table (`f.eks.` → "for
  eksempel", plus `dvs.`, `jf.`, `ca.`, `osv.` and Norwegian readings of the
  Latin forms), and the logic connectives (∧ ∨ ¬ → "og", "eller", "ikke"). The
  language is the one the read was started with, so there is no new setting;
  English output is byte-identical to before.

- Added `make update` for routine updates of an installed sr.app: pull, rebuild,
  swap the bundle in place, relaunch. It quits sr the way the Quit menu item
  does, so `applicationShouldTerminate` runs and pending ElevenLabs history
  deletions are persisted and the local daemon stopped — `make install`
  previously `pkill`ed the app, skipping that shutdown work entirely, which is
  now fixed there too.

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
