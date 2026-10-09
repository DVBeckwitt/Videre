import 'dart:math';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class PublicInstancesButton extends StatelessWidget {
  final Future<void> Function(BuildContext) openDirectory;
  final Future<List<PublicInstance>> Function() loadInstances;

  const PublicInstancesButton({
    super.key,
    required this.openDirectory,
    this.loadInstances = AddServerCubit.getPublicInstances,
  });

  @override
  Widget build(BuildContext context) {
    final loading =
        context.select((AddServerCubit cubit) => cubit.state.loading);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: OutlinedButton.icon(
        onPressed: loading
            ? null
            : () async {
                final cubit = context.read<AddServerCubit>();
                final url = await showDialog<String>(
                    context: context,
                    builder: (_) => _PublicInstancesDialog(
                        loadInstances: loadInstances,
                        openDirectory: openDirectory));
                if (context.mounted && url != null) {
                  cubit.selectPublicInstance(url);
                  FocusManager.instance.primaryFocus?.unfocus();
                }
              },
        icon: const Icon(Icons.public),
        label: Text(AppLocalizations.of(context)!.publicInstances),
      ),
    );
  }
}

class _PublicInstancesDialog extends StatefulWidget {
  final Future<List<PublicInstance>> Function() loadInstances;
  final Future<void> Function(BuildContext) openDirectory;

  const _PublicInstancesDialog(
      {required this.loadInstances, required this.openDirectory});

  @override
  State<_PublicInstancesDialog> createState() => _PublicInstancesDialogState();
}

class _PublicInstancesDialogState extends State<_PublicInstancesDialog> {
  late Future<List<PublicInstance>> instances = widget.loadInstances();

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.publicInstances),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.publicInstancesDescription),
            const SizedBox(height: 12),
            SizedBox(
              height: min(360, MediaQuery.sizeOf(context).height * 0.4),
              child: FutureBuilder<List<PublicInstance>>(
                future: instances,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final hosts = snapshot.data ?? [];
                  if (snapshot.hasError || hosts.isEmpty) {
                    return SingleChildScrollView(
                      child: Column(children: [
                        Text(locals.publicInstancesUnavailable),
                        TextButton(
                            autofocus: true,
                            onPressed: () => setState(() {
                                  instances = widget.loadInstances();
                                }),
                            child: Text(locals.retry)),
                      ]),
                    );
                  }
                  return ListView.builder(
                    itemCount: hosts.length,
                    itemBuilder: (context, index) {
                      final host = hosts[index];
                      return TextButton(
                        autofocus: index == 0,
                        onPressed: () => Navigator.of(context).pop(host.url),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(Uri.parse(host.url).host),
                                  Text(
                                      host.api
                                          ? locals.publicInstanceApiReported
                                          : locals.publicInstanceApiLimited,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => widget.openDirectory(context),
              child: Text(locals.publicInstancesDirectory)),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(locals.cancel)),
        ],
      ),
    );
  }
}
