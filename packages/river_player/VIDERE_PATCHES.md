Vendored from lamarios/river_player commit
55f1f374adbeeab7aefba5684dc2b014cbc87a63 (the previously pinned dependency).
Upstream licenses are retained. Examples, tests and build outputs are excluded.
Unused promotional images and orphaned documentation assets are also excluded;
the upstream documentation's absolute image links remain unchanged.

Videre changes: Android DataSourceUtils delegates HTTP data sources to
videre_proxy. This applies the same SOCKS5 policy to manifests, child streams,
redirects and media requests without rewriting their URLs. Android Gradle adds
the local videre_proxy dependency. Native media/cache factory calls carry the
original source URL so instance headers stay confined to its origin, including
independent DASH/HLS child requests. The optional native notification-artwork
worker also reads through this transport and closes both image-decoding streams.
It writes artwork inside the application cache directory and closes its output
stream before publishing the resulting path.
DRM license requests use it with custom headers scoped to the license origin.
These optional paths cannot bypass SOCKS or fall back to direct HTTP, even though
Videre currently uses audio_service notifications and does not configure DRM.

Android uses Media3's AudioTrack playback-parameter path so temporary speed
changes take effect at the mixer without waiting for previously queued PCM.
Speed and pitch remain independent. Media3 keeps software adjustment on Android
versions below API 23; the Videre app requires API 24. A platform rejection keeps
the previous effective parameters without switching to software adjustment.
Native acceptance must check actual playback progression and pitch controls,
not only the requested speed or the on-screen indicator. See the
[Media3 1.4.1 renderer-factory contract](https://github.com/androidx/media/blob/1.4.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/DefaultRenderersFactory.java#L208).
