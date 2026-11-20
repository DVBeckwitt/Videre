# Local music library and queue verification

Tests ran on November 20, 2026, using the pinned Flutter SDK and the
existing `Videre_NerdVPN_Test` Android 16 (API 36) x86_64 emulator.
The baseline was release 1.22.50 (`10e75121`). The candidate was a locally
signed profile APK installed in place. The fixture had three longer MP3
tracks and 500 short MP3s in nested folders. A disposable Videre profile
isolated playback and queue changes from the signed-in profile.

| Run | First playable row after process restart | Native scan time | Tag reads |
| --- | ---: | ---: | ---: |
| 1.22.50 baseline | 27.93 s | | |
| Candidate, initial index | 2.77 s | 28.30 s | 503 |
| Final candidate, existing index | 3.20 s | 4.08 s | 0 |

First-row measurements are accessibility polling upper bounds, including
UI automation idle time. The first candidate showed the row while indexing
continued. A second warm run logged 3.95 s and zero tag reads.

- Date modified sorted the fixture in both directions. The direction
  persisted through restart.
- **Play next** started playback from idle. Two copies of the same song
  appeared independently. Dragging the later copy to the top of the upcoming
  queue changed the song played by **Next**.
- Android's folder picker granted write access for the rename. The resulting
  MP3 was visible under the new filename, and the library and player kept the
  embedded title. Resume restored the renamed track and its saved position.
- The system source displayed Android's music and audio permission prompt.
  It played the renamed MP3 from MediaStore. Revoking permission removed
  the playable indexed rows and displayed the access message.

The pinned validation passed formatting, analysis, and 4,287 offline tests
with six skips. All 63 Android app unit tests passed. The Windows release
helper and APK signing tests passed. Shuffle and remote actions have widget
or player tests. Native acceptance used touch on Android 16. Older Android
versions and physical TV and screen-reader use remain unverified.

## Signed-in NerdVPN and regression follow-up

The original signed-in Default profile was active on the same API 36
emulator. Live Music search returned NerdVPN results. Android's media
session confirmed playback of GUZARISH and advanced past 30 seconds.
While that stream was active, Videre loaded a local folder. Local
**Play next** showed the queue replacement prompt. Cancelling kept the
online queue, and confirming later started the local file. Switching
back to a second NerdVPN track played audio, showed artwork on Now Playing,
and continued in the Android background with a media notification.

Review found and repaired stale notification actions after a local queue
length change, direct accessibility reorder, scan interruption when a
child directory disappears, and artwork missing after Android evicts a
thumbnail. Warm scans can repair up to four missing cover images without
rereading cached tags. Interrupted rename recovery now requires matching
file evidence and avoids reusing the saved queue ID for ambiguous files.
When Android 7 can prove equivalent MediaStore and folder references from
the same file descriptor identity, those references stay linked.

The follow-up pinned check passed formatting, analysis, and 4,290 offline
tests with six skips. The restricted NerdVPN, audio recovery, and
notification run passed 322 tests. A fresh Android app run passed 65 unit
tests. The rebuilt profile APK has SHA-256
`E3331CA5AC77301CA4312B95F3CFE5DE8B7AE455B5E252B1386CBB5E68DBE8A5`.
The x86_64 Dart payload and native dex both differ from the previous
profile APK. The APK has the same signer as the installed test app.

The emulator's installed APK matched that SHA-256. On this final build,
NerdVPN resumed at 45 seconds and advanced to 56 seconds while the local
library was browsed and a replacement request was cancelled. A deleted
thumbnail from the four-track test folder was regenerated on Refresh.
Android logged one cover read and zero tag reads for that scan.
Android background Pause held the local playhead at 20.006 seconds.
Resume advanced it to 22.627 seconds. The original saved playback record
was restored and matched its pre-test hash. The original signed-in profile
and source selection were restored, and the synthetic files were removed.
