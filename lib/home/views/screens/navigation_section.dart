import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../models/db/home_layout.dart';

@RoutePage()
class NavigationSectionScreen extends StatelessWidget {
  const NavigationSectionScreen({super.key, required this.source});
  final HomeDataSource source;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(source.getLabel(AppLocalizations.of(context)!)),
            actions: [
              if (source == HomeDataSource.home)
                IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () async {
                      final app = context.read<AppCubit>();
                      await context.router.push(const EditHomeLayoutRoute());
                      if (!app.isClosed) app.updateLayout();
                    }),
              if (source == HomeDataSource.subscription)
                IconButton(
                    icon: const Icon(Icons.checklist),
                    onPressed: () =>
                        context.router.push(const ManageSubscriptionsRoute())),
            ]),
        body: SafeArea(child: source.build(context, false)),
      );
}
