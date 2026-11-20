import 'dart:ui';

import 'package:intl/locale.dart' as intl;

import 'generated/app_localizations.dart';

final nativeLanguageNames = {
  for (final locale in AppLocalizations.supportedLocales)
    locale: lookupAppLocalizations(locale).nativeLanguageName,
};

Locale? parseSavedLocale(String? value) {
  if (value == null) return null;
  final parsed = intl.Locale.tryParse(value);
  if (parsed == null) return null;
  final locale = Locale.fromSubtags(
    languageCode: parsed.languageCode,
    scriptCode: parsed.scriptCode,
    countryCode: parsed.countryCode,
  );
  return AppLocalizations.delegate.isSupported(locale) ? locale : null;
}
