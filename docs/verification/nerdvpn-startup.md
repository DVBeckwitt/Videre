# NerdVPN startup and backend recovery

Checked on 10 November 2026 against `6094238cbeff` plus the startup and recovery
changes prepared for `1.22.41-beta.2+60906`. These changes are not part of
`v1.22.41-beta.1`.

## Scope and observations

The reported 70% playback rate came from an instance operator. It is not a
Videre measurement, and no historical startup-time baseline was available.
The goal is to remove demonstrated client overhead and handle known transient
backend failures without relaxing Invidious-only routing.

Three alternating request-stage samples per instance used the saved accounts
and video `tV5UilNUYRY` on the persistent `Videre_NerdVPN_Test` Android emulator.
All metadata requests returned HTTP 200. On warmed requests, metadata plus DASH
preparation took 2,426/2,391 ms on NerdVPN and 84/105 ms on the DVBeckwitt
instance. NerdVPN required the watch/check-ID sequence on every sample;
manifest preparation alone took 1,567/2,092/2,010 ms. These are request-stage
times, not first-frame or audible-playback times. Local request construction
and postprocessing were small in these samples. Receipts are in the ignored
`build/startup-comparison/timings.json`.

History inspection found that the watch/check-ID workaround predates these
recent changes, and the DASH preference and native buffering defaults were
unchanged. The privacy changes require instance-proxied media. Direct Google
media cannot be used as a performance fallback. The measurements do not
isolate the effect of a particular server/companion update.

## Changes

- Reuse the static MPD response already fetched successfully by the resolver
  during this playback attempt. Eligible Android playback avoids fetching that
  same manifest again for native setup and ASMS track discovery. The required
  watch/signature-resolution sequence remains.
- Reuse requires an exact request-URL attribution, at most 1 MiB, strict UTF-8,
  and a recognized static MPD. Live, redirected, oversized, HTML and unfamiliar
  responses retain normal URL loading. Original XML and its signed base URL
  stay unchanged. Bodies and signed URLs are not added to the route cache.
- Keep original account ownership, cancellation checks, audio-language tracks,
  selected quality, proxy transport and native child-request/redirect guards.
- A subsequent beta review reproduced an audio-track initialization race with
  inline manifests: discovery could select audio before native creation, and
  overwrite an early language choice with the default. Selection is retained
  until the current native source is initialized, with replacement and disposal
  guards. Delayed-create, early-selection, replacement and disposal regressions
  failed before the repair.
- Recognize the complete structured HTTP 500 metadata messages that say a
  Companion backend is starting or blocked. They can reach the existing
  bounded alternate-backend recovery after the existing same-route retry.
  Arbitrary 500s, HTML responses, gateway refusals, server cooldowns and the
  automatic-fallback opt-out keep their previous behavior. This is not a new
  manifest-500 classifier.

## Measurement limits and runtime evidence

Three old and three manifest-reuse runs measured Play to controller
initialization/play-command acceptance. Their medians were 22.4 and 20.4
seconds, with overlapping ranges of 21.0–31.0 and 18.0–31.6 seconds. These
small, noisy samples do **not** establish an end-to-end startup improvement:
native playback can still be buffering after initialization.

Separate native checks on the manifest-reuse build observed playhead movement
from 21,000 to 21,507 ms with the inline manifest, six quality tracks and one
audio track. Seeking to 45 seconds and restoring 21 seconds succeeded. Another
run used the ordinary fallback source, advanced from 21,906 to 22,455 ms, held
at 22,482 ms after an awaited pause, and passed seek/restoration. See
`build/startup-comparison/acceptance-progress-seek.json` and `acceptance.json`.
The known-500 recovery was added afterward and is covered by deterministic
metadata/recovery fixtures; an actual backend outage was not forced.

The final Beta 2 APK was then checked on the same signed-in emulator. Its
inline-manifest source exposed six quality tracks and one audio track; native
position advanced from 21,000 to 21,510 ms. The public cubit Pause action held
the native position at 22,037 ms for the one-second check. Seeking reached
45,000 ms and restored 21,000 ms. An earlier direct-controller pause probe did
not update the app's pending play intent and was unsuitable for UX acceptance;
the final check used the public action before awaiting native acknowledgement.
The controller and source remained the same throughout. This server's single
audio track had no language label, so language-choice ordering is established
by the delayed-initialization fixtures, not an audible multi-language device
check. The receipt is `build/beta2-validation/acceptance.json`.

Authenticated history and subscriptions both returned HTTP 200 after the
data-preserving update. The selected host remained `invidious.nerdvpn.de`, with
the original DASH/quality preferences (`true|null|true`). Playback was stopped,
the 21-second resume restored, debugger mappings removed, and Music Home
restored at 540 × 1080 / 240 dpi. Receipts are `auth-final.json`,
`safe-restored-state.json` and `final-restored-home.png` in
`build/beta2-validation/`.

A four-attempt adaptive/progressive comparison produced no valid timing
samples because diagnostic sampling failed. Its timeouts are not evidence of
playback failures. Playback was stopped, original preferences were restored,
the saved login was preserved, and task-owned debugger mappings were removed.
No playback default was changed on the strength of that experiment.

The final combined canonical check passed formatting, configured analysis and
**2,698 offline tests, with four opt-in live skips**. App analysis retains its
242 existing nonfatal diagnostics; strict regression analysis passed. The
resolver/player tests cover static-manifest handoff, encoding/size/HTML/live
exclusions, signed routes, stale completions and preserved track selection.
Recovery tests cover the exact known messages, fallback limits and exclusions.
The beta review found and repaired the audio race described above; the four new
regressions passed with the existing player suites (66 focused tests). Strict
analysis and formatting of the changed player controller and lifecycle tests
also passed. Independent review of that repair found no consequential defect.

Fresh Windows profile compilation and APK assembly passed for `armeabi-v7a`,
`arm64-v8a` and `x86_64`. Fresh libraries matched merged outputs and packaged ELF
build IDs. The final debug APK's packaged kernel matched the fresh compilation;
its SHA-256 also matched the installed APK:
`28a4c54e0642cfb046b5ee1e06febe62f3d028feeed2b8602832dec6d3df39d4`.
APK metadata confirmed `1.22.41-beta.2+60906`. Five validation-helper checks,
14 release-script safety checks and 10 signing-verifier tests passed.
Build and identity receipts are in `build/beta2-validation/`. These are local
Windows checks; release preparation additionally requires exact-commit Linux
CI and the signed release workflow. The `nix-shell` live-integration suite was
not run locally because `nix-shell` is unavailable here.

Server buffering and intermittent backend availability remain outside a client
fix's guarantees. Restoring the earlier experience or measuring a fleet-wide
success rate requires comparable real-device observations and server evidence.
