# SOCKS5 and Orbot

Settings → Network proxy provides an off-by-default SOCKS5 connection with a
127.0.0.1:9050 Orbot preset. The endpoint is editable. Start Orbot's SOCKS listener
before testing; its VPN mode is not required. The test uses the currently
selected Invidious instance and requires a JSON stats response. A local loopback
instance cannot establish Internet proxy coverage, so that test is rejected.
Authentication for arbitrary SOCKS servers is outside this initial implementation.

This setting is separate from the Invidious **Proxy videos** setting. It applies
to API requests, image loading, manifests, captions, downloads, background
notification checks, and Android video/audio HTTP data sources. Destination
hostnames are sent through SOCKS rather than resolved locally. Certificate
verification is retained. A proxy failure does not enable a direct fallback.

Internal loopback traffic (including just_audio's header-forwarding proxy) stays
local; its upstream request uses SOCKS. Phone/TV remote control only accepts
literal LAN addresses and refuses redirects, and remains local. External browser
authentication and links opened in another app use that app's networking.
Proxy endpoints are device-specific and are excluded from exported backups.

Applying changed settings aborts existing Dart connections and native media requests,
stops playback, and pauses incomplete downloads. Resume playback or downloads
explicitly after saving. Saving an unchanged, healthy configuration leaves active
playback and downloads alone. Workers send API requests through the same native
transport as playback, so they follow policy changes even while already running.
Invalid saved configuration blocks network traffic until
the user saves a valid setting, including explicitly disabling it.

## Implementation and checks

`lib/network` owns the Dart SOCKS handshake, TLS, policy, and connection lifecycle.
The local `packages/videre_proxy` Android plugin supplies Media3 HTTP data sources
using OkHttp and a SOCKS-only route. The two existing player versions are retained
under `packages/river_player` and `packages/just_audio`; their `VIDERE_PATCHES.md`
files record the native changes and upstream provenance. Never patch Pub caches.

The regression sweep removed the audio library's raw HTTP fallback, which could
bypass SOCKS, and closes its forwarding clients after each request. Media headers
are scoped to the original source origin across redirects, cached destinations,
and independent DASH/HLS child requests. Proxy changes also close active HTTP
connections whose wrapper was already collected or gracefully closed, cancel
download work before waiting for audio disposal, and use one authoritative native
settings store on Android.

A second regression pass found two remaining custom-header redirect paths. The
unsaved connection test now rejects redirects, and native background API calls
scope all caller-provided headers to the original origin. Synthetic credential
tests cover both paths; the native regression failed before the repair and passed
afterward. Same-origin headers and generated transport headers remain available.
The phone also exposed a detached HTTP completion error when cancelling a
partially forwarded audio response. The URI forwarder now observes both success
and failure of downstream completion and closes upstream once, including when
the player disconnects. A regression reproduced the exact truncated-body error
before the repair and passes afterward.
The repaired profile build was also checked on the phone while a throttled audio
body was still streaming: saving the changed policy moved the media session from
PLAYING to inactive/NONE, and the fresh process log contained zero unhandled
cancellation or truncated-content errors.

The final lifecycle pass found that delayed initial or queued video metadata
could complete after a proxy change had stopped playback. The parent player now
invalidates pending playback requests on proxy changes, hide and close. Late
successes, failures and queue continuations cannot restore a stopped source or
overwrite a newer queue. Dormant restored queues and valid decoder-mode changes
are preserved. Nine additional regression tests cover these cancellation paths.
The final phone check queued a minimal video whose metadata first returned HTTP
429 with a two-second retry delay. A proxy save stopped the existing decoder;
the delayed metadata then returned HTTP 200. The media session stayed inactive
with state NONE, and native player initialization count stayed at 6 rather than
creating a hidden replacement decoder.

A follow-up startup check reproduced the same class of race while the real
`AudioSession.instance` initialization was waiting for its native configuration.
TV autoplay and saved-session resume now honor cancellation that occurs during
that wait. Initialization still completes after a stop so later explicit Play
works, while closing the player prevents late observer or back-handler
registration. The regression covers cancellation, explicit recovery, normal TV
queue/start position, saved resume and close during initialization.
The updated profile app also rendered video with the supported Force TV
interface on the attached phone, accepted D-pad pause/resume, and released both
test decoders when leaving playback without unhandled player errors. This used
a local API fixture and direct sample media, not a physical TV or a new Tor run.

The optimized release check also reproduced a native policy-save failure after
HTTPS playback completed and left an idle TLS connection in the pool. Native
channel handling now uses Flutter's serial background task queue, keeping
preference writes and TLS socket shutdown off Android's main thread. Queued HTTP
requests still check engine attachment before registration, preserving detach
cancellation. Policy failures record their phase, type and stack without logging
settings, URLs or request headers.
An isolated optimized Android target then completed two 2,429,896-byte HTTPS
responses through the native bridge, which shares the media connection pool.
Each was followed by a successful policy save and native configuration readback.
This exercised the repaired native save operation while the secure lock screen
remained active; it does not establish a new full-UI playback run after the fix.

Run the canonical Dart checks with the pinned SDK:

```powershell
.\submodules\flutter\bin\dart.bat tools/validate.dart
.\submodules\flutter\bin\dart.bat tools/validate_test.dart
```

Native transport tests: from `android`, run
`./gradlew :videre_proxy:testDebugUnitTest` with JDK 21 and the configured Android
SDK. These tests use local SOCKS fixtures; they do not establish Android playback
or real Tor connectivity.

Device tests use a separate library instrumentation APK. With an authorized
Android device, run `./gradlew :videre_proxy:connectedDebugAndroidTest` from
`android/`. By default, five local SOCKS tests run and the real-Orbot test is
skipped. To include it, start Orbot with its SOCKS listener enabled and VPN mode
off, then supply an explicitly chosen HTTPS video URL:

```text
./gradlew :videre_proxy:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.orbotMediaUrl=HTTPS_VIDEO_URL
```

`-Pandroid.testInstrumentationRunnerArguments.orbotPort=PORT` overrides 9050.
The local fixture is synthetic H.264/AAC media; its source command is recorded in
[`packages/videre_proxy/README.md`](../packages/videre_proxy/README.md).

## Observed verification and limits

Verification on 27–28 October 2026 used Flutter 3.35.3 / Dart 3.9.2 and JDK 21 on
Windows. Canonical formatting/analysis and all 367 offline tests in the isolated
1.22.29 release checkout passed, along
with 19 native JVM tests, validation-helper tests and Windows release-script
safety tests. Existing analyzer warnings remain. Profile APKs built for ARM64,
ARMv7 and x86_64 under `build/app/outputs/flutter-apk/`.

All six instrumentation tests passed on a Pixel 8 Pro running Android 17
(API 37). They verified actual video-frame and AAC decoding, pause, a seek to
4.5 seconds, byte-range reads, SOCKS destination hostname forwarding, refused-proxy
failure without direct origin DNS, and HTTPS video playback through real Orbot.
The expanded tests also decoded DASH and HLS media and sought to 4.5 seconds,
checked that independent external manifest children received no instance
credentials, and verified that policy changes abort simultaneous video/audio
body reads before retained sources reopen through the new SOCKS endpoint.
The Orbot version was 17.9.7-RC-1 with Tor 0.4.9.14; VPN mode was off. In that
version, SOCKS-only operation used **More → Orbot Settings → General → Power User
Mode**. Android reported no Orbot VPN activation.
The final local device rerun passed all five local tests; the optional real-Orbot
test was skipped for that rerun, and its earlier successful report was preserved.

An isolated profile build of the full app, using the same production code, also
rendered the butterfly video through Orbot. Its local API fixture redirected media
from the instance origin to external HTTPS media. The app's **Test connection**
action succeeded against a public instance through Orbot, and saved proxy settings
survived an app restart. Early public-instance attempts were limited by NerdVPN's
HTTP 401 video response, independently reproduced with curl through Orbot.

Subsequent live YouTube acceptance used the user's already configured Invidious
instance and **Big Buck Bunny** (`aqz-KE-bpKQ`, 10:35). The installed Videre 1.22.27
rendered the real video and advanced to 00:58. The isolated patched profile build
also rendered it with SOCKS enabled at 127.0.0.1:9050, Orbot VPN mode off, and
Invidious **Proxy videos** enabled. A large seek advanced from 02:49 to 06:38 and
resumed rendered playback. The runtime selected the progressive fallback from
the instance; this live check does not establish YouTube DASH playback.

An initial Tor connection to the instance timed out. After refreshing the Tor
circuit, the same stats endpoint returned HTTP 200 in about three seconds; the
video API also returned HTTP 200 through Orbot. Tor's own check reported
`IsTor=true`, and Android reported no Orbot VPN activation. This does not identify
the precise cause of the first timeout. The first test clip, **Me at the zoo**
(`jNQXAC9IVRw`), returned HTTP 200 with an empty JSON body even without Tor, so it
could not establish playback acceptance on this instance.

The audio-only player completed the sample, and a second run continued in the
background: the app's Android media session remained PLAYING and advanced from
11 ms to 6033 ms while the activity was in the background. After Orbot was stopped
and the test app cold-started, fresh video playback failed with a SOCKS connection
refusal at 127.0.0.1:9050 and displayed **Retry / Connection help**.

The second on-device UI pass used controlled local media for deterministic
lifecycle checks, separate from the real-Orbot playback test. Saving unchanged
settings kept audio playing. Disabling the proxy stopped and cleared its active
media session; restoring the proxy did not resume playback. A changed save also
paused an active WebM download without marking it failed. Restoring the proxy
left it paused, and explicit resume requested the remaining bytes starting at
offset 4096 rather than restarting the video transfer.
The resumed video completed, muxed successfully on the phone, and rendered its
synthetic VP9 video from the downloaded file with Orbot stopped.

Longer audio sessions, lock-screen interruptions, captions, protected streams,
live YouTube DASH, real-Tor downloads, background notifications, and physical TV interaction still need
acceptance coverage. There was no
packet capture establishing complete absence of unintended direct traffic. Hosted
Linux CI is tracked separately in the repository's GitHub Actions; the live
Invidious test suite was not run locally. The user's existing Videre installation
and data were not replaced. The
temporary test app, Orbot installation, fixture server and USB port mappings were
removed after acceptance testing.
