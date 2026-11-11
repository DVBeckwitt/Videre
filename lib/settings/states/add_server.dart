import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../globals.dart';
import '../../network/nerdvpn_access.dart';
import '../../network/network_proxy.dart';
import '../../utils/invidious_image.dart';
import '../models/db/server.dart';
import '../models/errors/invidious_service_error.dart';

part 'add_server.freezed.dart';

typedef PublicInstance = ({String url, bool api});

class NerdVpnApiKeyException extends FormatException {
  const NerdVpnApiKeyException(super.message);
}

class AddServerCubit extends Cubit<AddServerState> {
  static const directoryUrl = 'https://api.invidious.io/instances.json';
  // Being listed in the directory does not mean a host accepts app requests.
  static const _recommendedInstances = {
    'https://invidious.f5.si',
    'https://inv.nadeko.net',
    'https://invidious.nerdvpn.de',
  };

  final TextEditingController urlController =
      TextEditingController(text: 'https://');
  final TextEditingController headerNameController = TextEditingController();
  final TextEditingController headerValueController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController apiKeyController = TextEditingController();
  final String _profileId = db.profileId;
  String? _apiKeyOrigin;

  AddServerCubit(super.initialState) {
    urlController.addListener(
      () {
        if (!isClosed) {
          final normalizedUrl = normalizeUrl(urlController.text);
          final origin =
              normalizedUrl == null ? null : Uri.parse(normalizedUrl).origin;
          if (origin != _apiKeyOrigin) {
            apiKeyController.clear();
            _apiKeyOrigin = origin;
          }
          emit(state.copyWith(
              valid: validUrl,
              publicInstance: normalizedUrl == state.publicInstance
                  ? state.publicInstance
                  : null));
        }
      },
    );
  }

  @override
  Future<void> close() {
    urlController.dispose();
    headerNameController.dispose();
    headerValueController.dispose();
    nameController.dispose();
    apiKeyController.dispose();
    return super.close();
  }

  Future<Server?> validateServer() async {
    if (isClosed || state.loading) return null;
    final serverUrl = normalizeUrl(urlController.text);
    final headers = Map<String, String>.from(state.headers);
    final onionManualSetup = usesNerdVpnOnion;
    final enteredApiKey = apiKeyController.text.trim();
    final protectedServer = state.protectedServer && !onionManualSetup;
    // NerdVPN collects the username on its own sign-in page. Ignore any local
    // label left in the hidden field after switching from another instance.
    final accountName = usesNerdVpn ? '' : nameController.text.trim();
    final advancedTest =
        state.advancedTest || state.publicInstance != null || onionManualSetup;
    Server? protectedSession;
    var credentialsStored = false;
    emit(state.copyWith(loading: true));
    try {
      if (serverUrl == null) {
        throw const FormatException(
            'Enter an instance address, such as https://invidious.example.');
      }
      if (accountName.length > 80) {
        throw const FormatException(
            'Account name must not exceed 80 characters');
      }

      final sameEndpointAccounts =
          (await db.forProfile(_profileId).getServers())
              .where((account) => account.url == serverUrl)
              .length;
      var server = Server(
          id: const Uuid().v4(),
          profileId: _profileId,
          name: accountName.isEmpty && sameEndpointAccounts > 0
              ? '${Uri.parse(serverUrl).host} (${sameEndpointAccounts + 1})'
              : accountName,
          url: serverUrl,
          customHeaders: headers);
      final nerdVpn = NerdVpnAccess.supports(server);
      if (isClosed && (nerdVpn || protectedServer)) return null;
      final manualKeys = headers.entries
          .where((entry) => NerdVpnAccess.isKeyHeader(entry.key))
          .toList();
      String? manualKey;
      if (nerdVpn) {
        if (manualKeys.length > 1) {
          throw const NerdVpnApiKeyException(
              'Enter one API key for this account. Remove duplicate API key headers.');
        }
        final headerKey =
            manualKeys.isEmpty ? null : manualKeys.single.value.trim();
        if (onionManualSetup &&
            enteredApiKey.isNotEmpty &&
            headerKey != null &&
            headerKey != enteredApiKey) {
          throw const NerdVpnApiKeyException(
              'The API key field and custom header contain different keys. Remove the custom API key header and try again.');
        }
        manualKey = onionManualSetup && enteredApiKey.isNotEmpty
            ? enteredApiKey
            : headerKey;
        if (onionManualSetup && (manualKey == null || manualKey.isEmpty)) {
          throw const NerdVpnApiKeyException(
              'Open NerdVPN in Tor Browser, enable API access in your preferences, then paste the API key here.');
        }
        if (manualKey != null && !NerdVpnAccess.isValidKey(manualKey)) {
          throw const NerdVpnApiKeyException(
              'Enter the complete NerdVPN API key: nvpn_ followed by 32 letters or numbers.');
        }
      }
      if (manualKey != null) {
        // Match the transport's fail-closed onion policy before creating
        // an unsaved native credential or starting either validation request.
        if (onionManualSetup && !NetworkProxy.instance.config.enabled) {
          throw const NerdVpnAccessRequired('proxyRequired');
        }
        server = server.copyWith(
            customHeaders: Map<String, String>.from(headers)
              ..removeWhere((name, _) => NerdVpnAccess.isKeyHeader(name)));
        // Track the new account before crossing the platform channel: a failed
        // response must not leave a key that was already written natively.
        protectedSession = server;
        await NerdVpnAccess.instance.setKey(server, manualKey);
        credentialsStored = true;
        if (isClosed) {
          await service.logOutProtected(server);
          protectedSession = null;
          return null;
        }
      }
      if (protectedServer || (nerdVpn && manualKey == null)) {
        final authenticated = protectedServer
            ? await service.authenticateProtected(server)
            : await service.authenticateNerdVpn(server);
        if (authenticated == null) {
          if (protectedSession != null) {
            await service.logOutProtected(protectedSession);
            protectedSession = null;
          }
          return null;
        }
        server = authenticated;
        protectedSession = server;
        credentialsStored = true;
        if (isClosed) {
          await service.logOutProtected(server);
          protectedSession = null;
          return null;
        }
      }

      // Browser sign-in can retain an account awaiting approval. Manual onion
      // setup only succeeds after its key and authenticated API both work.
      if (nerdVpn) {
        final access = await NerdVpnAccess.instance.status(server);
        if (isClosed) {
          await service.logOutProtected(server);
          protectedSession = null;
          return null;
        }
        if (!access.ready) {
          if (onionManualSetup) throw NerdVpnAccessRequired(access.state);
          return server;
        }
      }

      await service
          .validateServer(serverUrl, server.headersForUrl(serverUrl))
          .timeout(const Duration(seconds: 15));
      if (isClosed && protectedSession != null) {
        await service.logOutProtected(protectedSession);
        protectedSession = null;
        return null;
      }

      if (advancedTest) {
        final video = await service
            .getVideo('dQw4w9WgXcQ', serverOverride: server)
            .timeout(const Duration(seconds: 15));

        final thumbnails = video.videoThumbnails
            .map((thumbnail) => thumbnail.url.trim().isEmpty
                ? ''
                : invidiousImageUrl(thumbnail.url, server))
            .whereType<String>()
            .toList();
        // Validate the resolved URLs that the image loader uses. One usable
        // candidate is enough because the loader tries the available sizes.
        // Artwork deliberately omitted for privacy is optional, like an empty
        // thumbnail list; it must not reject an otherwise usable instance.
        if (thumbnails.isNotEmpty &&
            !thumbnails.any((thumbnail) {
              if (thumbnail.trim().isEmpty) return false;
              final url = Uri.tryParse(thumbnail);
              return url != null &&
                  const {'http', 'https'}.contains(url.scheme) &&
                  url.host.isNotEmpty;
            })) {
          throw WrongThumbnailUrl();
        }
      }

      if (isClosed && protectedSession != null) {
        await service.logOutProtected(protectedSession);
        protectedSession = null;
        return null;
      }
      return server;
    } catch (error) {
      if (!isClosed &&
          !onionManualSetup &&
          credentialsStored &&
          protectedSession != null &&
          NerdVpnAccess.supports(protectedSession) &&
          (error is NerdVpnAccessRequired ||
              error is InvidiousServiceError && error.isGatewayAccessFailure)) {
        return protectedSession;
      }
      if (protectedSession != null) {
        await service.logOutProtected(protectedSession);
      }
      rethrow;
    } finally {
      if (!isClosed) emit(state.copyWith(loading: false));
    }
  }

  void setShowAdvanced(bool advanced) {
    if (isClosed || state.loading) return;
    emit(state.copyWith(showAdvanced: advanced));
  }

  void setProtectedServer(bool value) {
    if (isClosed || state.loading) return;
    emit(state.copyWith(protectedServer: value));
  }

  Future<void> addHeader(String key, String value) async {
    if (isClosed || state.loading) return;
    final Map<String, String> headers = Map.from(state.headers);
    headers[key] = value;
    emit(state.copyWith(headers: headers));
  }

  void removeHeader(String key) {
    if (isClosed || state.loading) return;
    final Map<String, String> headers = Map.from(state.headers);
    headers.remove(key);
    emit(state.copyWith(headers: headers));
  }

  bool get validUrl => normalizeUrl(urlController.text) != null;

  bool get usesNerdVpn =>
      NerdVpnAccess.supportsUrl(normalizeUrl(urlController.text) ?? '');

  bool get usesNerdVpnOnion =>
      usesNerdVpn && isNerdVpnOnionUrl(normalizeUrl(urlController.text) ?? '');

  void selectPublicInstance(String url) {
    if (isClosed || state.loading) return;
    urlController.text = url;
    // Headers entered for a private server must not follow a public choice.
    emit(state.copyWith(
        headers: {},
        publicInstance: url,
        advancedTest: true,
        protectedServer: false));
  }

  static Future<List<PublicInstance>> getPublicInstances(
      {http.Client? client}) async {
    final directoryClient = client ?? http.Client();
    try {
      // The directory never needs the selected server's credentials.
      final response = await directoryClient
          .get(Uri.parse(directoryUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const FormatException('The instance directory is unavailable.');
      }
      return parsePublicInstances(jsonDecode(utf8.decode(response.bodyBytes)))
          .where((instance) => _recommendedInstances.contains(instance.url))
          .toList();
    } finally {
      if (client == null) directoryClient.close();
    }
  }

  static List<PublicInstance> parsePublicInstances(dynamic data) {
    if (data is! List) {
      throw const FormatException('Invalid instance directory.');
    }
    final instances = <String, PublicInstance>{};
    for (final entry in data) {
      if (entry is! List || entry.length != 2 || entry[1] is! Map) continue;
      final details = entry[1] as Map;
      // Unmonitored entries include hosts requiring a separate network.
      if (details['type'] != 'https' ||
          details['monitor'] is! Map ||
          details['uri'] is! String) {
        continue;
      }
      if (Uri.tryParse(details['uri'] as String)?.scheme != 'https') continue;
      final url = normalizeUrl(details['uri'] as String);
      if (url == null) continue;
      final uri = Uri.parse(url);
      if (uri.scheme != 'https' || uri.path.isNotEmpty) continue;
      final api = details['api'] == true;
      instances[url] = (url: url, api: api || (instances[url]?.api ?? false));
    }
    return instances.values.toList()
      ..sort(
          (a, b) => a.api != b.api ? (a.api ? -1 : 1) : a.url.compareTo(b.url));
  }

  static String? normalizeUrl(String input) {
    final value = input.trim();
    if (value.isEmpty || RegExp(r'\s').hasMatch(value)) return null;
    try {
      final uri = Uri.parse(value.contains('://') ? value : 'https://$value');
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535) {
        return null;
      }
      // Normalize before checking duplicates, including pasted trailing slashes.
      return uri
          .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
          .toString();
    } on FormatException {
      return null;
    }
  }

  void setAdvancedTest(bool advancedTest) {
    if (isClosed || state.loading || state.publicInstance != null) return;
    emit(state.copyWith(advancedTest: advancedTest));
  }
}

@freezed
sealed class AddServerState with _$AddServerState {
  const factory AddServerState(
      {@Default(false) bool loading,
      @Default(false) bool valid,
      @Default(false) bool showAdvanced,
      @Default(true) bool advancedTest,
      @Default(false) bool protectedServer,
      String? publicInstance,
      @Default({}) Map<String, String> headers}) = _AddServerState;
}
