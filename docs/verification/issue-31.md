# Playlist and download release verification

The 1.22.45 release adds playlist metadata, private Invidious playlist copies, batch download quality/container choices, M4A audio, selectable audio languages, and subtitles for exported videos and offline playback.

## Repairs and coverage

Reviews repaired duration wrap beyond 24 hours, concurrent server-copy duplication, stale save-button state, unavailable audio/video combinations, XML parsing of DASH tracks, offline subtitle access, and short TV layouts. The final release review additionally repaired empty-playlist metadata visibility, discovery of default audio available only through DASH, and unbounded DASH response buffering. Cold and signed-manifest reads now cancel on timeout and retain access-refusal status.

The canonical pinned-SDK validation passed formatting on 684 files, configured application analysis, strict test analysis, and 2,985 offline tests with six skips. Application analysis reported 240 nonfatal diagnostics. Focused privacy suites passed 373 tests. The Node 24.22.1 feedback service passed 52 tests. Validation-helper, release-helper, and signing-verification fixtures passed five, 14, and 10 tests respectively.

Native JVM tests were rebuilt and rerun with 115 passing cases. Controlled Android privacy and transport fixtures passed 14 cases with two optional live-Orbot skips. Stale adaptive-playback fixtures were corrected to require same-origin decoding and seeking. Separate DASH and HLS cases now require foreign-child refusal before a SOCKS handshake or HTTP request, with zero decoded output.

## Direct-YouTube boundary

The audit examined Dart IO/Dio, SOCKS and environment proxies, redirects, captions, images, storyboards, notification artwork, Music, download manifests, external-link handling, Android media/DRM/cache paths, and embedded WebViews. No direct-YouTube bypass was demonstrated in those paths. Tests exercise refusal of recognized YouTube/Google media destinations and preserve the selected-instance media boundary. Controlled fixtures establish refusal without making requests to official YouTube endpoints.

These checks apply to Videre-owned paths and the destinations recognized by its policy. Hostname rules cannot establish ownership of every arbitrary configured IP address, DNS alias, or future domain. OS and separate external-app traffic fall outside Videre's transport boundary. This record provides evidence for the reviewed release and the tested cases.

## Native feature acceptance

On the persistent API 36 x86_64 NerdVPN emulator, the preview pass verified playlist count/duration/date, private server-copy creation and independent listing, batch quality choices, an actual 8,860,752-byte M4A download, pause/resume, and local playback. Media inspection found one AAC audio stream. TV metadata, header scrolling, and video-tile focus passed with D-pad input at 720 by 360 logical pixels. Test-created downloads/playlists were removed and the phone layout restored.

The multilingual sample exposed actual audio/caption choices and transferred both selected media streams. Its caption retrieval failed with upstream HTTP 500/API 400, so that live attempt did not establish subtitle mux or rendering success. A bounded historical-caption sample follow-up also encountered HTTP 500 while opening download options. Fixture-based software tests cover caption selection, mux arguments, retained VTT, offline subtitle parsing, missing files, and zero-network offline loading.

A controlled local-media check on the final 1.22.45+60915 debug build verified actual Android FFmpegKit subtitle muxing into both MP4 (mov_text) and WebM (webvtt), with output streams independently inspected using ffprobe. Normal offline playback then displayed decoded local video and the selected VTT caption without a player or subtitle error. This verifies native mux and offline rendering independently of upstream caption availability. Test media and its local history were removed, and Music home was restored.

Evidence is retained locally in `build/issue31/`, `build/issue31-release/`, and `build/native-release-security-audit/`. The native privacy receipt identifies the exact test APK and records original failures and final XML results. The repository's Nix-backed full live-service suite is unavailable locally because the installed Windows/WSL environment has no `nix-shell`. Hosted Linux build and release verification are tracked on GitHub for the pushed commit.
