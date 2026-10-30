import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/models/db/server.dart';
import '../../states/player.dart';

bool canChoosePlayerBackend(PlayerState state) =>
    !state.isClosing &&
    state.offlineCurrentlyPlaying == null &&
    state.currentlyPlaying != null &&
    (state.requestedBackend ?? state.currentlyPlaying?.backendPlayback)
            ?.server
            .backendSelector !=
        null;

Future<void> showPlayerBackendPicker(BuildContext context,
    {required PlayerCubit player}) async {
  if (!canChoosePlayerBackend(player.state)) return;
  final videoId = player.state.currentlyPlaying!.videoId;
  final request = player.state.requestedBackend ??
      player.state.currentlyPlaying!.backendPlayback!;
  final selection = await showDialog<PlayerBackendChoice>(
    context: context,
    useRootNavigator: false,
    builder: (_) => PlayerBackendPicker(server: request.server),
  );
  if (selection == null || !context.mounted || player.isClosed) return;
  try {
    await player.selectBackend(selection.value,
        saveAsPreferred: selection.saveAsPreferred,
        expectedVideoId: videoId,
        expectedRequest: request);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.backendPlayerChangeFailed),
    ));
  }
}

class PlayerBackendChoice {
  final String? value;
  final bool saveAsPreferred;

  const PlayerBackendChoice(this.value, {this.saveAsPreferred = false});
}

/// This picker changes only the current video unless the user opts in to saving.
class PlayerBackendPicker extends StatefulWidget {
  final Server server;

  const PlayerBackendPicker({super.key, required this.server});

  @override
  State<PlayerBackendPicker> createState() => _PlayerBackendPickerState();
}

class _PlayerBackendPickerState extends State<PlayerBackendPicker> {
  late String? _value =
      widget.server.backendSelector?.selectedValue(widget.server);
  bool _saveAsPreferred = false;

  void _reveal(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        Scrollable.ensureVisible(context,
            duration: const Duration(milliseconds: 150),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  Widget _choice(String? value, String label, {bool enabled = true}) {
    final selected = value == _value;
    return MergeSemantics(
      child: Semantics(
        checked: selected,
        inMutuallyExclusiveGroup: true,
        child: Builder(
          builder: (tileContext) => ListTile(
            key: ValueKey('player-backend-${value ?? 'default'}'),
            selected: selected,
            enabled: enabled,
            autofocus: selected && enabled,
            onFocusChange: (focused) {
              if (focused) _reveal(tileContext);
            },
            leading: ExcludeSemantics(
              child: Icon(selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
            ),
            title: Text(label),
            onTap: enabled ? () => setState(() => _value = value) : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final selector = widget.server.backendSelector;
    final known = _value == null || selector?.labelFor(_value) != null;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable: true,
        title: Text(locals.backendChoose),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(locals.backendPlayerHelp),
              const SizedBox(height: 12),
              _choice(null, locals.backendDefault),
              if (!known) _choice(_value, locals.backendCustom, enabled: false),
              for (final option in selector?.options ?? [])
                _choice(option.value, option.label),
              const Divider(),
              Builder(
                builder: (saveContext) => CheckboxListTile(
                  key: const ValueKey('player-backend-save-preference'),
                  title: Text(locals.backendSavePreferred),
                  subtitle: Text(locals.backendSavePreferredHelp),
                  value: _saveAsPreferred,
                  controlAffinity: ListTileControlAffinity.leading,
                  onFocusChange: (focused) {
                    if (focused) _reveal(saveContext);
                  },
                  onChanged: (value) =>
                      setState(() => _saveAsPreferred = value ?? false),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('player-backend-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          FilledButton.icon(
            key: const ValueKey('player-backend-try'),
            onPressed: selector == null || !known
                ? null
                : () => Navigator.of(context).pop(PlayerBackendChoice(_value,
                    saveAsPreferred: _saveAsPreferred)),
            icon: const Icon(Icons.refresh),
            label: Text(locals.backendTry),
          ),
        ],
      ),
    );
  }
}
