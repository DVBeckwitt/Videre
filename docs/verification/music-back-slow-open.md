# Android Back during a slow Music open

## Recorded Android evidence

The persistent Android 16 phone AVD previously ran Videre
`1.22.52-music-tablet-collections-check+60957`. The archived x86_64 APK
matches SHA-256 `fff3357fa926da91c6664dd03646e2a6168203f55149272c995ac67e6063c608`.
Its source fingerprint includes local changes based on
`870c6889eb533cf6b3a4165ab628864a5c299565`. The primary checkout holds the
fixture script `music_pending_swipe_native.py` and its original captures under
`build/music-player-parity/build/acceptance-toolchain`.

Native pointer cancellation kept Tablet Track 01 active and its playhead
advanced from 10,865 to 15,305 ms. A committed artwork swipe reached Tablet
Track 02 in MediaSession `CONNECTING` at 0 ms while the fixture response was
held. After release, Track 02 reached 4,485 ms and 151,939 audio frames.
The recorded Android Back action occurred afterward and returned to the
album with Track 02 paused at 170,778 ms. The record lacks a Back action
during the request hold.

## Local regression

On `30db50013222852a9dd160f38a82c8e540b4caad`, Back minimized the player
while a manual song replacement was preparing. A late successful response
then replaced the active occurrence and could reopen Now Playing. The
regression in `test/player/queue_navigation_test.dart` holds the replacement
while the second occurrence of the same song plays, invokes the Back handler,
and releases the replacement with success. It checks that the mini player,
exact active occurrence, transport command, traversal, and playing media
session survive. Native playback is simulated in this test.

Artwork swipes take the Next or Previous path. That path can promote the new
occurrence before the native decoder opens, as the older Track 02 capture
shows. The local fix covers a manual replacement while its candidate decoder
is still preparing. The original artwork-swipe scenario remains open.

## Device acceptance case

A build with recorded provenance for the current candidate and coordinated
access to the existing `Videre_NerdVPN_Test` AVD are required. No matching
artifact was located during this batch. Run the original fixture from an
isolated evidence directory and use a temporary QA profile. Keep the archived
captures and persistent AVD account data.

1. Open the fixture album and play Tablet Track 01. Keep it away from its
   natural end and record the source album, active queue row, MediaSession
   title, playhead and output frames.
2. Expand Now Playing and swipe the artwork to Tablet Track 02. Wait for
   the fixture to log its held `/videoplayback` request. Confirm Track 02 is
   presented as pending. Capture a screenshot and MediaSession sample while
   the gate is still closed. A hierarchy dump during the hold can let the
   Android open time out.
3. Send Android Back before releasing the gate. Capture the album and mini
   player, plus MediaSession and playhead. Release the response in cleanup
   even if the assertion fails.
4. Confirm the same album is visible and Now Playing stays minimized after
   release. Confirm the exact Track 01 queue row and MediaSession title stay
   active, its playhead and output frames advance, and Track 02 remains
   queued without taking over. Reopen the queue only after recording the
   post-release navigation. The fixture supplies identical audio bytes
   under distinct track IDs, so output frame counts establish activity while
   the queue row and MediaSession identify the occurrence.
