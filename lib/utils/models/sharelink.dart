import '../../network/youtube_privacy.dart';
import '../../settings/models/db/server.dart';

abstract class ShareLinks {
  Uri getInvidiousLink(Server server, int? timestamp);
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
