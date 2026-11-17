import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String communityRuleLabel(AppLocalizations locals, CommunityRule rule) =>
    switch (rule) {
      CommunityRule.youtubeBlock => locals.communityYoutubeBlockRule,
      CommunityRule.youtubeWarn => locals.communityYoutubeWarnRule,
      CommunityRule.music => locals.communityMusicRule,
    };

String communityActionLabel(AppLocalizations locals, CommunityAction action) =>
    switch (action) {
      CommunityAction.off => locals.communityActionOff,
      CommunityAction.label => locals.communityActionLabel,
      CommunityAction.hide => locals.communityActionHide,
    };

Future<CommunityAction?> chooseCommunityAction(
    BuildContext context, CommunityRule rule, CommunityAction current) {
  final locals = AppLocalizations.of(context)!;
  return showDialog<CommunityAction>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => CommunityFilterShortcuts(
      child: AlertDialog(
        title: Text(communityRuleLabel(locals, rule)),
        scrollable: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in CommunityAction.values)
                ListTile(
                  autofocus: action == current,
                  selected: action == current,
                  leading: Icon(action == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(communityActionLabel(locals, action)),
                  onTap: () => Navigator.of(context).pop(action),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
        ],
      ),
    ),
  );
}

Future<({CommunityAction block, CommunityAction warning})?> chooseAiSListSetup(
  BuildContext context, {
  required CommunityAction block,
  required CommunityAction warning,
}) {
  final actions = {
    CommunityRule.youtubeBlock: block,
    CommunityRule.youtubeWarn: warning,
  };
  final locals = AppLocalizations.of(context)!;
  return showDialog<({CommunityAction block, CommunityAction warning})>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => CommunityFilterShortcuts(
      child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(locals.communityYoutubeFilters),
          scrollable: true,
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(locals.communityYoutubeSetupDescription),
                const SizedBox(height: 8),
                for (final entry in actions.entries)
                  ListTile(
                    autofocus: entry.key == CommunityRule.youtubeBlock,
                    contentPadding: EdgeInsets.zero,
                    title: Text(communityRuleLabel(locals, entry.key)),
                    subtitle: Text(communityActionLabel(locals, entry.value)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final action = await chooseCommunityAction(
                          context, entry.key, entry.value);
                      if (context.mounted && action != null) {
                        setState(() => actions[entry.key] = action);
                      }
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop((
                block: actions[CommunityRule.youtubeBlock]!,
                warning: actions[CommunityRule.youtubeWarn]!,
              )),
              child:
                  Text(MaterialLocalizations.of(context).continueButtonLabel),
            ),
          ],
        ),
      ),
    ),
  );
}

class CommunityFilterShortcuts extends StatelessWidget {
  final Widget child;

  const CommunityFilterShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: child,
      );
}
