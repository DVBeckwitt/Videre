Vendored from lamarios/river_player commit
55f1f374adbeeab7aefba5684dc2b014cbc87a63 (the previously pinned dependency).
Upstream licenses are retained. Examples, tests and build outputs are excluded.

Videre changes: Android DataSourceUtils delegates HTTP data sources to
videre_proxy. This applies the same SOCKS5 policy to manifests, child streams,
redirects and media requests without rewriting their URLs. Android Gradle adds
the local videre_proxy dependency. Native media/cache factory calls carry the
original source URL so instance headers stay confined to its origin, including
independent DASH/HLS child requests. Other upstream source is unchanged.
