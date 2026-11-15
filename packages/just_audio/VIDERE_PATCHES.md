Vendored from the published just_audio 0.10.5 package (the previously pinned
dependency), https://pub.dev/packages/just_audio/versions/0.10.5.
Upstream licenses are retained. Examples, tests and build outputs are excluded.

Videre changes: Android AudioPlayer delegates HTTP data sources to videre_proxy,
including native media requests and redirects. Android Gradle adds the local
videre_proxy dependency. The existing Dart header-forwarding proxy remains local;
its upstream HttpClient uses Videre's SOCKS5 transport. The Dart header proxy
returns a gateway failure on upstream errors instead of retrying HTTP/0.9 with
a raw origin socket, which would bypass SOCKS. It closes its upstream client
after every request. Supplied instance headers are scoped to their original
origin on redirects, cached redirect destinations and native media source
requests. Generated media range headers remain available across origins.
Truncated or disconnected local forwarding responses observe completion errors
and promptly close their upstream client instead of leaving a detached failing
future or waiting indefinitely for another origin chunk.

Music's optional Android equalizer uses lazy `AudioPlayer` helpers to read real
band parameters, enable/disable the effect, and set band gains. These reuse the
existing per-player effect method names with `lazyAndroidEqualizer` and an
expected audio-session ID. The native handler checks an already-active session
before effect creation; it cannot initialize a decoder. No effect is inserted
into the ordinary `AudioPipeline`, so unsupported hardware cannot prevent media
loading. Native control ownership, gain bounds, status codes and readback are
checked. The existing session/disposal lifecycle releases effects; Videre's Music
controller owns reapplication and clears its settings on playback/account exit.
An explicit source-load revision rejects effect replies across source replacement
or reload. Ordinary native playback events and successful load completion do not
invalidate the session's effect operations. Focused regressions in
`test/backend_retryability_test.dart` cover lazy creation, unsupported effects,
stale/inactive/disposed sessions, failed native writes, and effect reads/writes
which overlap ordinary playback updates.
