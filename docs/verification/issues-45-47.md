# Android verification for issues 45–47

The saved `Videre_NerdVPN_Test` emulator ran Android API 36 with a 540 × 1080
display, 240 dpi and default text size. A separate Videre profile used a
loopback Invidious fixture that served a two-minute test pattern and audio
track. It advertised three backends and recorded the route, response and
transferred bytes for each request.

The baseline was build 60952. The candidate was built from the issue branch
based on `v1.22.51-beta.3` (60954). The installed baseline used the local
Android debug certificate, so the test APK used that same certificate for an
in-place update. All 1,496 non-signature ZIP entries matched the release build
by SHA-256. The installed test APK SHA-256 was
`92dbbce6c88f59425813e975a8842fa49ce511abe97a1312ce86438afc2bbfeb`.

## Audio-only layout

On the same recording, the Info tabs ended at physical y=881 before the
change. The bottom inset began at y=1044, leaving 163 pixels unused. After
switching from Video to Audio on the candidate, the tabs ended at y=1044 and
the description appeared above them. The tabs kept their position after
minimizing and restoring the player. Android reported active playback in both
modes. The widget regression also covers tablet layout, short windows and
large text.

## Playback and download routing

For the same Video item, the baseline requested A twice and then loaded
metadata from B. The candidate received the classified outage from A and
loaded the metadata from B on its next request. The measured interval between
the first request to A and success on B was 1,147 ms on the baseline and
69 ms on the candidate. These are individual fixture observations. B served
the candidate 2,016,908 bytes of combined video and audio, and later served
a range starting at byte 355,397.

| Android action | Fixture requests and result |
| --- | --- |
| Open the download format picker and queue a video | The picker and the queued job each received an outage from A and loaded metadata from B. B served 749,435 bytes of AAC and 1,242,026 bytes of H.264. The video download completed. |
| Download audio when a media request fails | A returned valid metadata followed by HTTP 503 for the audio. The job fetched fresh metadata from B, received the 749,435-byte audio response and completed. |
| Play two different videos with backends A, B and C | On the first video, A and B reported outages and C served the stream. On the second video, the app tried the preferred A, then went directly to C and played the stream. B received no request for that video. |
| Receive an instance-wide rate limit | A returned HTTP 429 with a three-second `Retry-After`. The next request went to A after 3.073 seconds. No backend received an intervening request. |
| Switch a fresh Video item to audio-only | After A failed, C served the video and AAC-only sources. Android reported 12.348 seconds of playback. |

## History and appearance

The test profile played the recording on build 60952 before the in-place
upgrade. The candidate showed that entry under **All history on this device**
with its existing progress. A new audio-only play from Video appeared in
**Video history** and left **Music history** empty. Playing the same ID from
Music added it to **Music history**. Removing that Music entry preserved the
Video entry and the recording’s resume progress.

The **Classic purple** selection survived an app process restart. Its colors
were visible in Appearance and Music Now Playing.

## Automated checks

The pinned SDK ran 4,376 passing offline tests. Six opt-in live catalog cases
were skipped. The formatter checked 851 files. Strict analysis passed and
the application analyzer added no diagnostics relative to Beta 3. The Android
JVM suites passed 65 app tests, 146 transport tests and 72 recommendation
tests.

## Follow-up regression pass

At 760 × 360 logical pixels and 1.7× text, the expanded audio-only player
could allocate zero height to Info. A widget regression now opens both Info
and Queue with automatic fullscreen disabled. A separate Android check found
that stopping playback after rotation could leave a blank fullscreen surface
over Home until Back was pressed.

The download regressions cover two jobs sharing a server-provided cooldown,
a paused row updating at the deadline without another state change, and a
partial transfer moving to a backend with ambiguous rendition metadata. The
latter must begin at byte zero. Transfer tests also exercise servers that
return text, an image or the wrong media container with HTTP 200. Playback
tests change accounts or reset the session while a retry is waiting and
check that the old request is never sent.

History tests queue the same upload from Video while it is playing from
Music, restore the queue, and verify which history receives each play. They
also cover ordering imported timestamps, refreshing an empty list, reopening
a previously played download and stripping its device-specific file binding
from a portable backup.

On the initial issue build, the API 36 phone emulator ran in forced TV mode.
D-pad and Center opened Video
history, focused a video card and switched to combined history. Back restored
focus to History. Music Library opened the separately cleared Music history.
In TV Settings, choosing Classic purple returned focus to the palette row
with the selected value.

The follow-up release-mode x64 build had SHA-256
`956230fc3139208c3c7799f2e7c399d6677e3ed99e85c4fb19c4300419ef9283`.
The in-place emulator update used the installed test certificate and had
SHA-256 `baf537e182de37d8cdad25adfbb3b3bf22d819392af82ebd1c4f254f6a1e6787`.
All 1,496 application entries matched. The packaged Dart binary changed from
the earlier candidate and contained the new offline-history field.

With Android text at 170%, a 1080 × 540 landscape viewport and automatic
fullscreen disabled, the earlier build showed only the header and artwork.
The updated build showed the controls and Info content. Its four tabs ended
at y=504, the start of the bottom inset. Tapping Queue displayed the current
item and kept the controls visible.

With automatic fullscreen enabled, Android’s media Stop key restored Home and
both system bars from landscape audio playback. The media session reported
`NONE`, and tapping Downloads opened it immediately without pressing Back.

On the phone, a completed audio-only download was paused at 11.910 seconds
and stopped. Video history displayed the item at 9%. Selecting it there
reopened the offline player at 11 seconds, and playback advanced to 16.891
seconds. In TV mode, D-pad selection of the same history entry played the
download through Android’s audio output. The available test server received
zero metadata or media requests during either replay.

The final offline run passed all 4,398 tests in 4 minutes 2 seconds and
skipped six opt-in live Music cases. Formatting checked 851 files. Strict
analysis passed and the application analyzer matched all 221 pre-existing
diagnostics. All 283 Android JVM tests, 14 Windows release-helper checks,
10 APK-signing tests and five validation-helper groups passed.
