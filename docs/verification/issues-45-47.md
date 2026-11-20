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
