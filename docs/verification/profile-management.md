# Add, rename, and delete local profiles

The shared phone/tablet/TV Profiles picker keeps the existing Add and Rename
actions and adds Delete. Its confirmation names the profile and explains that
local accounts, library, history, subscriptions, settings, and download records
are removed; downloaded media files remain in their existing storage location.
The only remaining profile cannot be deleted. Default can be deleted when
another profile exists.

Deletion shares the account-switch queue. An active profile first leaves its
playback/download session through the existing switch lifecycle. Saved sign-ins
are revoked, its background mirror is retired, and its database records are
removed last. A cleanup failure remains visible and leaves the profile listed
for a retry. Other profiles and shared network/storage/TV settings are preserved.

The database checks profile ownership again inside queued writes, including
playlist and watched-history updates. Deleted Default metadata is not recreated
on reopening. A durable background-file deletion marker prevents captured worker
views from recreating credentials or notification files after deletion. The
shared periodic worker remains available to surviving profiles.

Background file commits and deletion use one lock per profile, with the shared
selection lock taken first when required. On Android, `flock` serializes separate
file opens from foreground and worker isolates. Dart's ordinary POSIX file lock
does not provide that isolation. The platform helper has bounded asynchronous
lock waits and closes its handle on success or failure. See the
[Dart locking contract](https://api.dart.dev/dart-io/RandomAccessFile/lock.html)
and [Linux flock contract](https://man7.org/linux/man-pages/man2/flock.2.html).

Protected sign-out also closes a matching browser that is still installing its
proxy, then checks the current native revision before revocation. A newer Dart
sign-in waits for that cleanup. This closes the race where profile removal could
otherwise leave an unfinished sign-in alive.

## Verification scope

Implementation checks use in-memory databases and temporary file fixtures.
Android acceptance must create, rename, and delete only a uniquely named test
profile and preserve the existing NerdVPN profile and login. A native lock
fixture must use its own temporary directory. No real profile deletion,
credential export, app-data reset, push, or release is part of this task.

Final combined validation, artifact identity, and device results are recorded
after the implementation is frozen. Earlier Music-only test results do not
validate the profile changes.

Focused database/history/playlist checks passed **93 tests**. Profile-picker and
real session-lifecycle checks passed **48 tests**, covering creation/rename,
confirmation/cancellation, last-profile protection, active/inactive deletion,
cleanup failure and retry, queued selection, failure visibility during navigation,
and narrow-screen/large-text/TV Select behavior. These groups overlap other
validation and are not a combined distinct-test count. Logs are under
`build/profile-management/`.

Protected-authentication checks passed **18 tests**. Background FileDB checks
passed **30 tests**, including separate-isolate lock contention, throwing-action
release, stale-account rejection, partial deletion retry, and preservation of
other profiles and downloaded files. These host checks ran on Windows; Android's
different lock implementation requires its separate device fixture below.

The initial combined canonical validator passed formatting, configured application
analysis, strict regression analysis, and **2,648 tests**, with four opt-in live
skips. The configured application analysis retained the existing 242 nonfatal
diagnostics; strict regression analysis was clean. The validation-helper checks,
Windows release-script safety checks, and ten APK-signing verifier tests passed.
Evidence is in `build/music-invidious-only/combined-before-welcome-fix.log`
and the adjacent helper/release/signing logs.

The first combined run exposed an obsolete account-authentication fixture that
completed its status-read completer twice after sign-out gained a fresh status
read. The fixture now models both reads and asserts their count; its newer-login
preservation assertions remain unchanged. All 27 gateway/account-authentication
tests passed before the final full run. No production workaround was needed.

On the persistent Android x86_64 emulator (`emulator-5596`), the ignored
`build/profile-crud/lock_device.dart` entrypoint imported the production lock
helper and passed separate-isolate contention, exception release, and a modeled
retired-writer refusal. It used only its own temporary directory and did not
open the app database or actual FileDB. The observed marker was
`VIDERE_FILE_LOCK_FIXTURE_PASS cross-isolate-contention exception-release retirement-no-write`;
run/result logs are under `build/profile-crud/`. Full FileDB deletion semantics
are covered by the host tests above and the normal-app profile acceptance below.

The combined normal debug APK and all three profile APKs passed fresh-compilation
identity checks; hashes and build details are recorded in
[the Music verification report](invidious-music-library.md#combined-music-and-profile-validation).

## Welcome-screen acceptance repair

The first normal-app Android pass exposed missing profile controls on Welcome:
creating an empty profile opened setup without a direct profile-switch/manage
action, and Android Back left the app. Both phone and TV Welcome now expose the
existing Profiles dialog before server setup. This allows rename, cancellation,
deletion, or return to a saved profile without adding an unnecessary server.

Both missing-entry failures were reproduced in widget tests. The repair passed
86 profile-picker/session/deep-link tests, clean scoped analysis, and formatting.
Coverage includes first launch with no server, 320-pixel/large-text phone layout,
TV focus/Select, rename and return, and cancel/confirm active-empty-profile deletion.
Evidence: `build/profile-management/welcome-profiles-{red,green,analysis}.log`.
The final normal-app artifacts and full-suite result below include this repair;
the first-pass native Music receipt retains its original artifact identity.

After the Welcome repair, the complete canonical validator passed again:
**2,654 tests**, four opt-in live skips, formatting, configured application
analysis, and strict regression analysis. The final log is
`build/music-invidious-only/combined-canonical-validation-final.log`.

On the Welcome-fixed `29e17e9e…` APK (installed SHA-256 verified), ordinary Android
UI acceptance passed: open Profiles from Welcome, rename the temporary profile,
cancel its named deletion confirmation, switch to Default, and delete the
inactive temporary profile. A second temporary profile was created and deleted
while active; the app returned to Default. Only Default remained, with its delete
action disabled. The original NerdVPN/DV accounts were retained; no server or
credential was added for these temporary profiles. Both test profiles were
removed through the product UI.

Native TV acceptance also passed on that APK: D-pad Down/Select opened
Profiles from Welcome for a third disposable profile. Deleting that active
profile returned to Default. All three temporary profiles were removed, and
the device was restored to phone layout. This supplements the widget focus
coverage with actual Android remote-key evidence.

## Compact-dialog focus repair

Review of the 720-by-360 logical-pixel TV screenshot found that the initially
focused second profile's name and actions could be clipped by the dialog's
scroll viewport. The picker now reveals the whole row after initial focus and
Edit/Delete focus changes. It checks that focus still belongs to that row before
scrolling, honors reduced motion, and preserves row identity when renaming
changes sort order.

Six deterministic visibility regressions failed with the reveal behavior disabled
and passed after restoration. They include the exact two-profile TV arrangement
with Android system insets, compact phone layouts, long lists, and normal/reduced
motion. A rename-reordering regression also preserves the existing focus node.
All 73 focused profile/session/motion checks passed; analysis and formatting were
clean (`build/profile-management/profile-focus-*.log`). The final full gate and
focused native recheck below include this repair.

After the focus repair, the complete canonical validator passed **2,661 tests**
with four opt-in live skips, formatting, configured application analysis, and
strict regression analysis. The final log remains
`build/music-invidious-only/combined-canonical-validation-final.log`; the prior
Welcome-only result is retained in `combined-before-focus-fix.log`.

The final `e218e716…` APK was installed and its hash verified on the persistent
Android emulator. At the original compact TV dimensions, the newly created
temporary profile's full name and Edit/Delete actions were visible immediately.
Actual D-pad traversal focused Delete and then Edit while retaining the visible
name. Root also visually inspected these screenshots. Evidence is under
`build/music-invidious-only/focus-final/` (`active-initial-focus.png`,
`actual-delete-focus.png`, and `actual-edit-focus.png`).
