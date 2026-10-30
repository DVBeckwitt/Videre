import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';

import '../backend_selector.dart';

part 'server.freezed.dart';

part 'server.g.dart';

final _log = Logger('Server');

@freezed
sealed class Server with _$Server {
  const factory Server(
      {required String url,
      String? authToken,
      String? sidCookie,
      @Default({}) Map<String, String> customHeaders,
      // Freezed copies this parameter annotation to the generated field.
      // ignore: invalid_annotation_target
      @JsonKey(
          fromJson: BackendSelector.tryFromJson,
          toJson: BackendSelector.optionalToJson)
      BackendSelector? backendSelector,
      @Default(false) bool inUse}) = _Server;

  const Server._();

  Map<String, String>? headersForUrl(String url) {
    final serverUri = Uri.tryParse(this.url);
    final targetUri = Uri.tryParse(url);
    final useHeaders = serverUri != null &&
        targetUri != null &&
        (serverUri.scheme == 'http' || serverUri.scheme == 'https') &&
        targetUri.scheme == serverUri.scheme &&
        serverUri.host.isNotEmpty &&
        targetUri.host == serverUri.host &&
        targetUri.port == serverUri.port;

    _log.fine('Use server headers: $useHeaders');
    return useHeaders ? customHeaders : null;
  }

  factory Server.fromJson(Map<String, Object?> json) => _$ServerFromJson(json);
}
