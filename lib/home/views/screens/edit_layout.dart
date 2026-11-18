import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

import '../../../settings/views/components/app_customizer.dart';

/// App destinations only. Home feed controls have their own editor.
@RoutePage()
class EditHomeLayoutScreen extends StatelessWidget {
  const EditHomeLayoutScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(AppLocalizations.of(context)!.phoneNavigationTitle)),
        body: const SafeArea(child: AppCustomizer()),
      );
}
