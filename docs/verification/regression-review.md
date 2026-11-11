# Regression review of local issue and privacy changes

Reviewed on 10 November 2026 in the existing working tree based on `40826fd6`.
Scope: the local fixes for issues 27–29, standard-Invidious Music, mandatory
proxied playback, and the concrete layout defects observed during acceptance.
This is one bounded review and verification pass, not a claim that the entire
application is free of defects. No dependency versions were changed.

## Reproduced defects and repairs

- A display-mode dialog could write to a different profile after the active
  profile changed. Results now belong to the opening profile and session.
- Saving Music artist or playlist bookmarks discarded recognized relative
  Invidious artwork. Those paths now survive persistence without saving query
  credentials or permitting arbitrary relative paths.
- An unsupported preferred storyboard or TV banner hid a usable smaller image.
  Candidate selection now considers whether the image has a permitted route.
- Optional artwork deliberately omitted by the privacy policy made server
  validation reject an otherwise usable instance. Omitted artwork is optional;
  malformed remaining URLs still fail validation.
- Subtitle intervals included their end, showing the previous cue at a shared
  boundary. Cue ends are now exclusive, including when playback is paused.
- Transcript normalization omitted WebVTT nonbreaking-space and bidi entities
  and could decode nested entities twice. One-pass decoding preserves the
  intended text through normalized WebVTT output.
- Phone video statistics overflowed a narrow row. Icon/count groups now wrap,
  and expired premiere timestamps no longer create invalid date ranges in
  either phone statistics or TV cards.
- TV History and generic video grids allocated too little space for the
  thumbnail and three text lines. Rows now account for theme font metrics and
  text scaling while preserving the existing three columns and D-pad behavior.
  Native acceptance caught an additional 1.5 px overflow for a mixed Korean
  title; the thumbnail now yields space to actual text layout while preserving
  its proportions. That exact case has a regression test too.
- An empty TV playlist card let fixed-size artwork consume the title's space,
  hiding Watch Later and overflowing the card. Title and detail text now get
  space first; D-pad Select retains the same local playlist identity.
- A retryable failure loading the preferred audio format skipped usable formats
  from the same instance. Playback now tries a bounded list of admitted formats
  before backend recovery; access refusals remain terminal.
- Downloads ranked formats before route validation, so an inadmissible high
  bitrate format hid a usable one. Only admitted routes enter format ranking.
- Caption and watch-page response reads outlived their timeout and buffered
  without a limit. Reads now cancel at their deadline or 4 MiB limit.
- A pending NerdVPN startup retry could survive a switch away from and back to
  the same account. A session revision invalidates obsolete retries.

Every listed repair has a focused regression that failed before its fix.
Mandatory Invidious source admission and official-endpoint blocking remain in
place. A separate read-only review found no introduced defect in the landed
profile, artwork-persistence, metrics, cue-boundary and audio-fallback repairs.

## Verification

- Pinned `dart tools/validate.dart` passed formatting, configured analysis and
  **2,293 offline tests**, with four opt-in live skips. Existing nonfatal
  application diagnostics remain. The earlier isolated Music batch stall did
  not recur in the complete final run.
- Validation-helper tests: 5 passed. Windows release-helper safety tests: 14
  passed. APK-signing helper tests: 10 passed.
- Feedback relay: 52 tests passed using its pinned Node 24.22.1. The system's
  older Node could not run the suite; the already installed pinned executable
  was used without changing dependencies.
- The native transport Gradle test task passed with unchanged outputs from the
  previously verified 82 JVM tests. No Kotlin transport source changed in this
  review.
- The final debug APK was built after all production fixes. Its packaged kernel
  matches the forced fresh compile, and both native privacy guards are present.
  Artifact: `build/regression-audit-acceptance/app-debug-regression-review-complete.apk`.
  SHA-256: `5aea0d3c2c4fd4ed87dd29701c6ff4036dff70113f27afff3b1a91a3dc628fc1`.
- Profile APKs built for `armeabi-v7a`, `arm64-v8a` and `x86_64`. For each ABI,
  freshly compiled and merged libraries matched, stripping preserved the ELF
  build ID, and the packaged library matched the stripped output. Both privacy
  guards are packaged. Hashes are in `profile-build-identity-complete.json` alongside the
  debug receipt.

Focused evidence is retained locally in ignored `build/review-*.log`,
`build/privacy-review-focused-green.log`, and corresponding agent test logs.
Build identity and native screenshots/receipts are under
`build/regression-audit-acceptance/`.

## Android acceptance

The first review APK (`77d06d9e…`, retained as
`app-debug-regression-review.apk`) was installed over the signed-in app on the
Android 16/API 36 x86_64 emulator. At the original phone dimensions, the M7 video
decoded and advanced, its statistics wrapped without the previous 53 px
overflow, the Video display dialog opened with Fit selected and returned to the
player, and manual English captions rendered over the video. Screenshot evidence
includes `phone-m7-metadata.png`, `phone-display-picker.png` and
`phone-manual-captions.png`.

NerdVPN Music audio advanced from 00:27 to 00:33 while Android Home was in front
for six seconds, then paused after returning. D-pad navigation between TV cards
and Settings worked. The first TV pass caught the mixed-script card overflow
described above; its evidence is retained in `native-initial-acceptance.json`.
Only TV card layout and its premiere badge changed after those phone/Music
checks.

The second APK (`a5463435…`) was then tested at the same 720 × 360 logical TV
viewport. The focused mixed-script PSY card now shows both title lines and the
full channel label within its bounds, without the previous overflow. Evidence:
`final-tv-history-psy.png`.

The final APK (`5aea0d3c…`) also passed the targeted TV playlist check at that
viewport: Watch Later and its empty-playlist details fit without overflow,
including while focused, and D-pad Select opened the existing empty local
playlist without changing its data. Evidence: `complete-tv-watch-later-card.png`,
`complete-tv-watch-later-focused.png` and `complete-tv-watch-later-opened.png`.
Only the TV playlist-card branch changed after the preceding History check.

After acceptance, Force TV was disabled, the original 540 × 1080 physical size
and 240 dpi density were restored, and the emulator was left on NerdVPN Music
Home with no active playback. Fit mode, login, account, network settings and
playlist data were preserved. The final receipt is
`native-complete-acceptance.json`; earlier receipts retain their original
findings and artifact identities.

No commit, push, release or remote CI run is part of this review. Windows local
checks and an Android emulator do not establish physical-TV, Linux-hosted CI or
the full Nix live-service-suite coverage. Download format selection and failure
recovery were exercised with controlled integration fixtures; this review did
not perform a new Android file-download/export acceptance run. Source failures,
stale-session races and exact subtitle boundaries were likewise covered by
deterministic tests rather than forcing those failures on a live instance.
