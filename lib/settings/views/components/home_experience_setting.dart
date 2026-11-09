import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../globals.dart';
import '../../../home/models/content_mode.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../states/settings.dart';

String homeExperienceLabel(
        HomeExperience experience, AppLocalizations locals) =>
    switch (experience) {
      HomeExperience.videosAndMusic => locals.homeExperienceVideosAndMusic,
      HomeExperience.videosOnly => locals.homeExperienceVideosOnly,
      HomeExperience.musicOnly => locals.homeExperienceMusicOnly,
    };

Future<void> showHomeExperiencePicker(BuildContext context) async {
  final settings = context.read<SettingsCubit>();
  final profileId = db.profileId;
  final sessionRevision = settings.appCubit.state.sessionRevision;
  final locals = AppLocalizations.of(context)!;
  final selected = settings.state.homeExperience;
  final choice = await showDialog<HomeExperience>(
    animationStyle: AppMotion.dialogStyle(context),
    context: context,
    useRootNavigator: false,
    builder: (context) => SimpleDialog(
      title: Text(locals.homeExperience),
      children: [
        for (final experience in HomeExperience.values)
          ListTile(
            key: ValueKey('home-experience-${experience.name}'),
            title: Text(homeExperienceLabel(experience, locals)),
            selected: selected == experience,
            trailing: selected == experience ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, experience),
          ),
      ],
    ),
  );
  if (choice != null &&
      context.mounted &&
      !settings.isClosed &&
      db.profileId == profileId &&
      settings.appCubit.state.sessionRevision == sessionRevision) {
    await settings.setHomeExperience(choice);
  }
}

class HomeExperienceSetting extends StatelessWidget {
  const HomeExperienceSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final experience =
        context.select((SettingsCubit cubit) => cubit.state.homeExperience);
    final locals = AppLocalizations.of(context)!;
    return ListTile(
      key: const ValueKey('home-experience-setting'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.home_outlined),
      title: Text(locals.homeExperience),
      subtitle: Text(homeExperienceLabel(experience, locals)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showHomeExperiencePicker(context),
    );
  }
}
