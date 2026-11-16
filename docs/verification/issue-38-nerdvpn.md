# NerdVPN sign-in regression — 15 November 2026

This work addresses the NerdVPN portion of
[issue #38](https://github.com/DVBeckwitt/Videre/issues/38). The report did not
include a version, logs, or reproduction steps. Existing account data and the
persistent `Videre_NerdVPN_Test` AVD were preserved.

## Reproduction and repairs

The original app reached the ordinary NerdVPN login form in a fresh Add Server
draft on the persistent Android 16 AVD. Canceling the native sign-in browser
then produced “The protected server session is unavailable.” No login
credentials were submitted during that reproduction.

Token-only browser cleanup called `ProfileStore.deleteProfile` after loading
the profile through `getOrCreateProfile`. AndroidX explicitly documents that
[loaded profiles cannot be deleted in that process](https://developer.android.com/reference/androidx/webkit/ProfileStore#deleteProfile(java.lang.String)).
The exception converted cancellation into an error and also discarded any
successful token before returning it to Dart. An isolated native regression
reproduced this failure using fixture cookies and a destroyed WebView.

Cleanup now clears the temporary profile's web storage and cookies, using the
existing account-scoped clearing path. The browser route remains denied and
its lease remains reserved until the asynchronous cookie callback completes.
A ten-second deadline fails closed; late callbacks cannot complete a newer
sign-in. Failure still prevents token delivery. The saved account profile is
separate and is not cleared.

Anonymous public probes also encountered a conditional Gandalf JavaScript
challenge. Following its no-script redirect returned HTTP 403 and “JavaScript
is disabled.” A Dart HTTP probe reproduced the challenge with an Android
browser user agent. This is separate from the cleanup defect: the native AVD
reached the normal login form without that challenge. A deliberately invalid,
anonymous PKCE exchange returned the expected `400 invalid_grant`; it did not
establish an authenticated exchange failure.

The Add Server form now exposes an optional API-key fallback for canonical
clearnet NerdVPN, alongside the existing onion setup. It offers a copyable
preferences address and explains that another browser has its own network and
privacy settings. Videre does not launch an external browser or enable page
JavaScript. A manual key enables API browsing and playback; it does not sign
in to synchronize remote subscriptions or history. A new manual-key account
must pass authenticated statistics and video checks before being saved. Any
failure or cancellation clears only the new draft's credential. Existing
browser-auth eligibility and pending-approval behavior remain intact.

## Verification

- Five new clearnet onboarding regressions failed before the fix. The focused
  onboarding, phone/TV settings, copy-only handoff, and gateway suites then
  passed all 105 tests. Scoped Dart analysis reported no issues.
- The isolated native cleanup fixture failed with the previous deletion path
  and passed both tests after the repair. It verifies temporary-cookie removal,
  preservation of a separate saved profile, and cleanup of an absent profile
  without creating browser state.
- Native JVM checks passed: 121 proxy tests and 15 application tests.
- The complete isolated proxy device suite contained 34 cases: 32 passed and
  two optional live Orbot playback checks were skipped. No test used the main
  application's account, cookies, or browser profiles.
- Independent source review found no actionable issue in the manual-key
  rollback or asynchronous browser-completion paths.
- The final canonical check for `1.22.46-beta.2+60917` passed all 3,163 offline
  tests with six optional live checks skipped. Formatting checked 711 files
  without changes; strict analysis was clean. The broader source analyzer
  retained its baseline four warnings and 236 informational diagnostics. All
  five validation-helper tests passed.

Local evidence is under `build/issue38/`: `nerdvpn-public-signin-evidence.json`,
`nerdvpn-dart-probe.json`, `nerdvpn-onboarding-red.log`,
`nerdvpn-focused-tests.log`, `nerdvpn-analysis.log`,
`profile-cleanup-red.log`, `profile-cleanup-green.log`, and `native-final.log`.
Full gate logs are `final-validation.log` and `final-validation-helper.log`.
The original native screenshots/XML are under `build/issue-38/` as
`nerdvpn-login-form.*` and `nerdvpn-cancel-error.*`. Evidence excludes keys,
cookies, passwords, and grant values.

## Limits

The native fixture establishes browser-data cleanup and isolation, not an
end-to-end successful account login. Fresh valid-credential submission,
successful-token delivery in the real app, and a valid clearnet manual-key
submission require separate acceptance. No onion key was transmitted to the
clearnet host. The conditional gateway challenge and upstream API eligibility
remain server-controlled. Real-app acceptance after the final APK is recorded
separately below when performed.

## Final app acceptance

Installed `1.22.46-beta.2+60917` with a data-preserving update on the same
signed-in Android 16 x86_64 AVD. Profile APK SHA-256:
`09d4beea7324100e99ed83778b9b2931441ab7a38eb79e3c2483cce9ffe828d5`.

- A fresh Add Server draft reached NerdVPN's ordinary login page. Cancel
  returned to the draft without the original protected-session error.
- The existing account's **Log in with token** action also loaded that page.
  Cancel returned cleanly; the account still showed **Logged in** and a saved
  API key. No credentials were entered or replaced.
- Browsing and video playback still worked afterward. Native media-session
  snapshots reported `PLAYING`, advancing from 33,744 to 39,218 ms. Forward seek
  also advanced the paused position from 22,801 to 32,801 ms.
- The optional clearnet key form and copy-only preferences address were visible
  on Android. The public instance picker omitted Nadeko as intended.

Screenshots and media-session receipts are in `build/issue-38/` with the
`beta2` suffix. These checks verify cancellation and preserved account access;
they do not add fresh valid-credential login or clearnet key-submission coverage.
