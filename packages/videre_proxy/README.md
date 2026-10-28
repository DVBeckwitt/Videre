# Videre Android proxy transport

This local Flutter plugin shares the saved SOCKS5 policy between Videre's Android
video and audio backends. Both backends use `ProxyDataSource.factory` instead of
constructing a default HTTP data source. The `videre/proxy` channel exposes
`configure` (`enabled`, `host`, `port`) and `getConfiguration`.

Background isolates use the same native policy through `request` with `method`,
`url`, `headers`, and optional body bytes. The response contains `statusCode`,
`headers`, and body bytes. Calls run on OkHttp's background dispatcher, have a
30-second total timeout, and allow at most 4 MiB for each request/response body.
`followRedirects` defaults to true; `maxRedirects` defaults to 5 and accepts 0–20.
Calls are cancelled on engine detach and proxy changes, preventing a worker with
an old Dart settings snapshot from continuing to use a direct Internet route.

Media3 1.4.1's `OkHttpDataSource` retains its handling of HTTP ranges, streaming
responses, redirects and headers. The policy-specific OkHttp selector offers one
SOCKS route for each Internet destination. OkHttp passes unresolved destination
names to Java's SOCKS socket, and a DNS guard prevents accidental local origin
lookups. TLS uses OkHttp's platform trust manager and hostname verification.
Caller-supplied session and authentication headers stay with their original
origin and are stripped before cross-origin redirects for both media and API
requests. Media factories also carry the original source origin and configured
header names so independent DASH/HLS child requests cannot inherit instance
credentials. Media3-generated headers such as byte ranges remain available.

Only literal loopback addresses and `localhost` bypass SOCKS so that just_audio's
internal header-forwarding proxy can work. Its upstream requests still need the
application's Dart SOCKS transport. LAN remote control is handled separately by
the application. No external browser traffic is configured by this plugin.

Policy updates cancel calls, including responses whose media bodies are still
being read, and evict old pooled connections. Invalid stored configuration blocks
network requests rather than selecting a direct route.

Native transport tests: from `android/`, run
`./gradlew :videre_proxy:testDebugUnitTest` using the repository's JDK and SDK.
These JVM tests exercise SOCKS hostname forwarding, redirect routing and active
stream cancellation. They do not establish Android decoding or lifecycle
acceptance; Orbot playback must also be checked on an Android device/emulator.

Device decoding acceptance uses a separate library instrumentation APK, preserving
the installed Videre application's data. With an authorized Android device, from
`android/` run `./gradlew :videre_proxy:connectedDebugAndroidTest`. Five default
tests verify real H.264/AAC decoding, video frames, audio buffers, pause/seek,
byte-range reopening, unresolved origin hostnames through a local SOCKS fixture,
and refusal without direct origin DNS after the proxy is stopped. They also
exercise simultaneous held video/audio response bodies during a policy change:
old reads and sockets must close, and the same retained data sources must reopen
through the new proxy. DASH and HLS fixtures verify actual decoding and a seek to
4.5 seconds; their independently requested child resources use a different origin
and must not receive instance credentials. The video tests are muted and consume
decoded frames through an EGL surface. They do not change
system volume or use the device's Internet connection.

The optional real-Orbot test is skipped unless `orbotMediaUrl` is provided. Start
Orbot's SOCKS listener with VPN mode disabled, then run, for an explicitly chosen
HTTPS video URL:

```text
./gradlew :videre_proxy:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.orbotMediaUrl=HTTPS_VIDEO_URL
```

`-Pandroid.testInstrumentationRunnerArguments.orbotPort=PORT` overrides 9050. This
test establishes native HTTPS video playback through the Orbot listener, while
the full app still needs its UI, background and download acceptance checks.

`android/src/androidTest/assets/socks_fixture.mp4` is a six-second synthetic
160×90 H.264 baseline/AAC clip generated with the following FFmpeg command; it
contains no external media or user data:

```text
ffmpeg -f lavfi -i testsrc2=size=160x90:rate=15 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 6 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -crf 32 -g 15 -c:a aac -b:a 24k -movflags +faststart socks_fixture.mp4
```

The AAC-only `socks_audio.m4a` is extracted with
`ffmpeg -i socks_fixture.mp4 -vn -c:a copy -movflags +faststart socks_audio.m4a`.
The adaptive fixtures retain the same six-second video/audio streams. From the
`assets/dash` and `assets/hls` directories respectively, generate them with:

```text
ffmpeg -i ../socks_fixture.mp4 -c copy -f dash -seg_duration 1 -use_template 1 -use_timeline 1 -adaptation_sets "id=0,streams=v id=1,streams=a" -init_seg_name 'init-$RepresentationID$.m4s' -media_seg_name 'chunk-$RepresentationID$-$Number%02d$.m4s' manifest.mpd
ffmpeg -i ../socks_fixture.mp4 -c copy -f hls -hls_time 1 -hls_list_size 0 -hls_playlist_type vod -hls_segment_filename segment%02d.ts manifest.m3u8
```

The manifests in the APK use relative URLs. At test runtime only, the fixture
server rewrites child URLs to a second `.invalid` hostname, proving both remote
destination DNS and origin-scoped headers without depending on external media.

Primary references:

- [Media3 network stacks](https://developer.android.com/media/media3/exoplayer/network-stacks)
- [Media3 1.4.1 OkHttp data source](https://github.com/androidx/media/blob/1.4.1/libraries/datasource_okhttp/src/main/java/androidx/media3/datasource/okhttp/OkHttpDataSource.java)
- [OkHttp 4.12 SOCKS route selection](https://github.com/square/okhttp/blob/parent-4.12.0/okhttp/src/main/kotlin/okhttp3/internal/connection/RouteSelector.kt)
