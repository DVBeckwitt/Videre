import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:http/http.dart' as http;

import '../../globals.dart';
import '../models/db/server.dart';

part 'add_server.freezed.dart';

typedef PublicInstance = ({String url, bool api});

class AddServerCubit extends Cubit<AddServerState> {
  static const directoryUrl = 'https://api.invidious.io/instances.json';

  final TextEditingController urlController =
      TextEditingController(text: 'https://');
  final TextEditingController headerNameController = TextEditingController();
  final TextEditingController headerValueController = TextEditingController();

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
    return super.close();
  }

  Future<Server?> validateServer() async {
    if (isClosed || state.loading) return null;
    final serverUrl = normalizeUrl(urlController.text);
    final headers = Map<String, String>.from(state.headers);
    final advancedTest = state.advancedTest || state.publicInstance != null;
    emit(state.copyWith(loading: true));
    try {
      if (serverUrl == null) {
        throw const FormatException(
            'Enter an instance address, such as https://invidious.example.');
      }

      final existingServer = db.getServer(serverUrl);

      if (existingServer != null) {
        throw ServerAlreadyExists();
      }

      await service
          .validateServer(serverUrl, headers)
          .timeout(const Duration(seconds: 15));

      if (advancedTest) {
        Server server = Server(url: serverUrl, customHeaders: headers);
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

      return Server(url: serverUrl, customHeaders: headers);
    } finally {
      if (!isClosed) emit(state.copyWith(loading: false));
    }
  }

  setShowAdvanced(bool advanced) {
    if (isClosed || state.loading) return;
    emit(state.copyWith(showAdvanced: advanced));
  }

  addHeader(String key, String value) {
    if (isClosed || state.loading) return;
    final Map<String, String> headers = Map.from(state.headers);
    headers[key] = value;
    emit(state.copyWith(headers: headers));
  }

  removeHeader(String key) {
    if (isClosed || state.loading) return;
    final Map<String, String> headers = Map.from(state.headers);
    headers.remove(key);
    emit(state.copyWith(headers: headers));
  }

  bool get validUrl => normalizeUrl(urlController.text) != null;

  void selectPublicInstance(String url) {
    if (isClosed || state.loading) return;
    urlController.text = url;
    // Headers entered for a private server must not follow a public choice.
    emit(state.copyWith(headers: {}, publicInstance: url, advancedTest: true));
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
      return parsePublicInstances(jsonDecode(utf8.decode(response.bodyBytes)));
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

  setAdvancedTest(bool advancedTest) {
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
      String? publicInstance,
      @Default({}) Map<String, String> headers}) = _AddServerState;
}
