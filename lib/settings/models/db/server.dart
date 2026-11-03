import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';

import '../backend_selector.dart';
import '../../../network/gateway_context.dart';

part 'server.freezed.dart';

part 'server.g.dart';

final _log = Logger('Server');

@freezed
sealed class Server with _$Server {
  const factory Server(
      {required String url,
      @Default('default') String profileId,
      String? id,
      @Default('') String name,
      @Default(false) bool gatewayEnabled,
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

  /// Legacy accounts retain their URL key; new accounts use stable IDs so
  /// several accounts can share an endpoint without overwriting credentials.
  String get accountId => id ?? url;

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
    return useHeaders
        ? gatewayContextHeaders(
            profileId: profileId,
            accountId: accountId,
            serverUrl: this.url,
            targetUrl: url,
            headers: customHeaders)
        : null;
  }

  factory Server.fromJson(Map<String, Object?> json) => _$ServerFromJson(json);
}
