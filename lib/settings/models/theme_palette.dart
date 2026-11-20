import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

enum ThemePalette {
  neutral,
  classicPurple,
  dynamicColors;

  String label(AppLocalizations locals) => switch (this) {
        neutral => locals.neutralPalette,
        classicPurple => locals.classicPurplePalette,
        dynamicColors => locals.useDynamicTheme,
      };

  ColorScheme seededScheme(Brightness brightness) => this == classicPurple
      ? ColorScheme.fromSeed(
          seedColor: const Color(0xff4f0096), brightness: brightness)
      : ColorScheme.fromSeed(
          seedColor: const Color(0xff757575),
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        );

  static final classicDark = classicPurple.seededScheme(Brightness.dark);
}
