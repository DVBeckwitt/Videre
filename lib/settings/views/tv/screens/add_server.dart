import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:gap/gap.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/components/public_instances.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/add_server_options.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/settings/views/screens/network_proxy.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';

import '../../../../utils/views/tv/components/tv_text_field.dart';

@RoutePage()
class TvAddServerScreen extends StatelessWidget {
  const TvAddServerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: TvOverscan(
          child: BlocProvider(
            create: (BuildContext context) =>
                AddServerCubit(const AddServerState()),
            child: BlocBuilder<AddServerCubit, AddServerState>(
                builder: (context, state) {
              final cubit = context.read<AddServerCubit>();
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: state.loading
                            ? null
                            : () => showProfilePicker(context),
                        icon: const Icon(Icons.account_circle_outlined),
                        label: Text(locals.profiles),
                      ),
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => Text(cubit.usesNerdVpnOnion
                            ? locals.nerdVpnOnionSetup
                            : cubit.usesNerdVpn
                                ? locals.nerdVpnAccessSignIn
                                : locals.instanceAddressDescription),
                      ),
                      const Gap(12),
                      OutlinedButton.icon(
                        onPressed: state.loading
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const NetworkProxySettingsScreen())),
                        icon: const Icon(Icons.vpn_lock_outlined),
                        label: Text(locals.networkProxy),
                      ),
                      const Gap(12),
                      const PublicInstancesButton(
                          openDirectory: AddServerScreen.openInstanceDirectory),
                      Text(locals.instanceAddress),
                      ExcludeFocus(
                        excluding: state.loading,
                        child: TvTextField(
                          controller: cubit.urlController,
                          autocorrect: false,
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => cubit.usesNerdVpn
                            ? const SizedBox.shrink()
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Gap(10),
                                  Text(locals.accountName),
                                  ExcludeFocus(
                                    excluding: state.loading,
                                    child: TvTextField(
                                        controller: cubit.nameController),
                                  ),
                                ],
                              ),
                      ),
                      AddServerOptions(
                        state: state,
                        television: true,
                        onSubmit: () =>
                            AddServerScreen.validateAndClose(context),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
