import '../../network/youtube_privacy.dart';
import '../../settings/models/db/server.dart';

abstract class ShareLinks {
  Uri getInvidiousLink(Server server, int? timestamp);

  /// Construct an address for sharing only; never fetch YouTube directly.
  Uri getYoutubeLink(int? timestamp);
}

class PublicPlaylistShareLinks implements ShareLinks {
  final String id;

  const PublicPlaylistShareLinks(this.id);

  @override
  Uri getInvidiousLink(Server server, int? timestamp) =>
      invidiousShareLink(server,
          pathSegments: const ['playlist'], queryParameters: {'list': id});

  @override
  Uri getYoutubeLink(int? timestamp) =>
      Uri.https('www.youtube.com', '/playlist', {'list': id});
}

/// Share the configured instance address without account or request metadata.
Uri invidiousShareLink(Server server,
    {required List<String> pathSegments,
    Map<String, String>? queryParameters}) {
  final base = Uri.parse(server.url);
  if (!const {'http', 'https'}.contains(base.scheme) ||
      base.host.isEmpty ||
      isOfficialYoutubeUrl(base)) {
    throw const FormatException('An Invidious instance is required');
  }
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      ...pathSegments,
    ],
    queryParameters: queryParameters,
  );
}
