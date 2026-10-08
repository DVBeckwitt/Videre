import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';

import '../../globals.dart';
import '../models/db/server.dart';

part 'add_server.freezed.dart';

class AddServerCubit extends Cubit<AddServerState> {
  final TextEditingController urlController =
      TextEditingController(text: 'https://');
  final TextEditingController headerNameController = TextEditingController();
  final TextEditingController headerValueController = TextEditingController();

  AddServerCubit(super.initialState) {
    urlController.addListener(
      () {
        emit(state.copyWith(valid: validUrl));
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
    emit(state.copyWith(loading: true));
    try {
      final serverUrl = normalizeUrl(urlController.text);
      if (serverUrl == null) {
        throw const FormatException(
            'Enter an instance address, such as https://invidious.example.');
      }

      final existingServer = db.getServer(serverUrl);

      if (existingServer != null) {
        throw ServerAlreadyExists();
      }

      await service
          .validateServer(serverUrl, state.headers)
          .timeout(const Duration(seconds: 15));

      if (state.advancedTest) {
        Server server = Server(url: serverUrl, customHeaders: state.headers);
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

      return Server(url: serverUrl, customHeaders: state.headers);
    } finally {
      if (!isClosed) emit(state.copyWith(loading: false));
    }
  }

  setShowAdvanced(bool advanced) {
    emit(state.copyWith(showAdvanced: advanced));
  }

  addHeader(String key, String value) {
    final Map<String, String> headers = Map.from(state.headers);
    headers[key] = value;
    emit(state.copyWith(headers: headers));
  }

  removeHeader(String key) {
    final Map<String, String> headers = Map.from(state.headers);
    headers.remove(key);
    emit(state.copyWith(headers: headers));
  }

  bool get validUrl => normalizeUrl(urlController.text) != null;

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
      @Default({}) Map<String, String> headers}) = _AddServerState;
}
