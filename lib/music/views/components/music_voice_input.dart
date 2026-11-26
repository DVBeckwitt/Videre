import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const _channel = MethodChannel('videre/music_voice_search');

Future<bool> musicVoiceInputAvailable() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await _channel.invokeMethod<bool>('isAvailable') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Future<String?> requestMusicVoiceInput(
  BuildContext context, {
  required bool Function() isCurrent,
  required VoidCallback onConsent,
  bool collectionFilter = false,
}) async {
  if (!isCurrent()) return null;
  final locals = AppLocalizations.of(context)!;
  final languageTag =
      parseSavedLocale(context.read<SettingsCubit?>()?.state.locale)
          ?.toLanguageTag();

  void showFailure() {
    if (!isCurrent()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(locals.musicVoiceSearchFailed)),
    );
  }

  try {
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(locals.musicVoiceSearch),
        content: Text(collectionFilter
            ? locals.musicVoiceCollectionPrivacy
            : locals.musicVoiceSearchPrivacy),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(locals.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(locals.musicVoiceSearchStart),
          ),
        ],
      ),
    );
    if (consent != true || !isCurrent()) return null;
    onConsent();
    final transcript = (await _channel.invokeMethod<String>(
      'recognize',
      {if (languageTag != null) 'languageTag': languageTag},
    ))
        ?.trim();
    return transcript != null && transcript.isNotEmpty && isCurrent()
        ? transcript
        : null;
  } on MissingPluginException {
    showFailure();
  } on PlatformException {
    showFailure();
  }
  return null;
}
