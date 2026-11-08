import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../globals.dart';
import '../../network/nerdvpn_access.dart';
import '../models/db/server.dart';
import '../models/errors/invidious_service_error.dart';

part 'add_server.freezed.dart';

typedef PublicInstance = ({String url, bool api});

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
  final String _profileId = db.profileId;

  AddServerCubit(super.initialState) {
    urlController.addListener(
      () {
        if (!isClosed) {
          emit(state.copyWith(
              valid: validUrl,
              publicInstance:
                  normalizeUrl(urlController.text) == state.publicInstance
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
    return super.close();
  }

  Future<Server?> validateServer() async {
    if (isClosed || state.loading) return null;
    final serverUrl = normalizeUrl(urlController.text);
    final headers = Map<String, String>.from(state.headers);
    final protectedServer = state.protectedServer;
    final accountName = nameController.text.trim();
    final advancedTest = state.advancedTest || state.publicInstance != null;
    Server? protectedSession;
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
      final manualKeys = headers.entries
          .where((entry) => entry.key.toLowerCase() == 'x-invidious-token');
      if (nerdVpn && manualKeys.isNotEmpty) {
        if (manualKeys.length != 1) {
          throw const FormatException('Enter one API key for this account.');
        }
        await NerdVpnAccess.instance.setKey(server, manualKeys.single.value);
        server = server.copyWith(
            customHeaders: Map<String, String>.from(headers)
              ..removeWhere(
                  (name, _) => name.toLowerCase() == 'x-invidious-token'));
        protectedSession = server;
      }
      if (protectedServer || (nerdVpn && manualKeys.isEmpty)) {
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
        if (isClosed) {
          await service.logOutProtected(server);
          protectedSession = null;
          return null;
        }
      }

      // Eligibility and disabled access are saved account states. The gateway
      // can reject the API probes until the account receives a working key.
      if (nerdVpn) {
        final access = await NerdVpnAccess.instance.status(server);
        if (isClosed) {
          await service.logOutProtected(server);
          protectedSession = null;
          return null;
        }
        if (!access.ready) return server;
      }

      await service
          .validateServer(serverUrl, server.headersForUrl(serverUrl))
          .timeout(const Duration(seconds: 15));

      if (advancedTest) {
        final video = await service
            .getVideo('dQw4w9WgXcQ', serverOverride: server)
            .timeout(const Duration(seconds: 15));

        final invalidThumbnailUrls = video.videoThumbnails
            .map(
              (e) => e.url,
            )
            .any((u) => u.startsWith("/"));

        if (invalidThumbnailUrls) {
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
