import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

import 'community_filter.dart';

class CommunityMatchLabels extends StatelessWidget {
  const CommunityMatchLabels({
    super.key,
    required this.matches,
    this.compact = false,
    this.interactive = true,
  });

  final List<CommunityMatch> matches;
  final bool compact;
  final bool interactive;

  String _label(AppLocalizations locals, CommunityMatch match) =>
      switch (match.source) {
        CommunityList.aislist => match.warning
            ? locals.communityListedYoutubeWarn
            : locals.communityListedYoutubeBlock,
        CommunityList.aimusic => locals.communityListedMusic,
      };

  Future<void> _allow(BuildContext context, CommunityMatch match) async {
    try {
      await communityFilters.allow(match);
    } catch (_) {
      if (context.mounted) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(locals.communityAllowFailed)),
        );
      }
    }
  }

  Future<void> _showMatches(BuildContext context) async {
    final locals = AppLocalizations.of(context)!;
    final controller = communityFilters;
    final profile = controller.profileSelection;
    final entry = await showDialog<CommunityMatch>(
      context: context,
      builder: (context) => SimpleDialog(
        children: [
          for (final match in matches)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, match),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_label(locals, match)),
                subtitle: Text(locals.communityAllowChannel),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
      ),
    );
    if (entry != null &&
        context.mounted &&
        identical(controller, communityFilters) &&
        profile == controller.profileSelection) {
      await _allow(context, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    if (compact) {
      final details = matches.map((match) => _label(locals, match)).join('\n');
      const shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: Color(0xff362100), width: 2),
      );
      final label = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'AI',
              semanticsLabel: 'AI. $details',
              style: const TextStyle(
                color: Color(0xff281900),
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      );
      return Tooltip(
        message: details,
        excludeFromSemantics: true,
        child: Material(
          color: const Color(0xffffbf47),
          elevation: 2,
          shape: shape,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 52,
              minHeight: interactive ? 48 : 40,
            ),
            child: interactive
                ? Semantics(
                    button: true,
                    child: InkWell(
                      customBorder: shape,
                      onTap: () => _showMatches(context),
                      child: label,
                    ),
                  )
                : label,
          ),
        ),
      );
    }
    const icon = Icon(Icons.info_outline, size: 18);
    return Wrap(
      spacing: 8,
      children: [
        for (final match in matches)
          if (interactive)
            ActionChip(
              avatar: icon,
              label: Text(_label(locals, match)),
              tooltip: locals.communityAllowChannel,
              onPressed: () => _showMatches(context),
            )
          else
            Chip(avatar: icon, label: Text(_label(locals, match))),
      ],
    );
  }
}

class CommunityHiddenNotice extends StatelessWidget {
  const CommunityHiddenNotice({
    super.key,
    required this.count,
    required this.showing,
    required this.onToggle,
    this.compact = false,
  });

  final int count;
  final bool showing;
  final VoidCallback onToggle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final button = TextButton(
      onPressed: onToggle,
      child: Text(
          showing
              ? locals.communityHideHidden
              : compact
                  ? locals.communityShowHidden
                  : '${locals.communityHiddenCount(count)} · ${locals.communityShowHidden}',
          maxLines: compact ? 2 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          textAlign: TextAlign.center),
    );
    return compact
        ? Tooltip(message: locals.communityHiddenCount(count), child: button)
        : button;
  }
}
