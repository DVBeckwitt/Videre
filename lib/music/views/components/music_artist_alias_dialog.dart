import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> showMusicArtistAliasEditor(
  BuildContext context, {
  required MusicLibraryService library,
  required MusicArtistIdentity identity,
  required String originalName,
  required bool Function() isCurrent,
}) {
  if (!identity.isValid || !isCurrent()) return Future.value();
  final app = context.read<AppCubit>();
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => BlocListener<AppCubit, AppState>(
      bloc: app,
      listenWhen: (_, __) => !isCurrent(),
      listener: (context, _) {
        final route = ModalRoute.of(context);
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      },
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: _ArtistAliasDialog(
          originalName: originalName,
          currentAlias: library.artistAlias(identity),
          save: (value) => library.setArtistAlias(
            identity,
            value == originalName ? null : value,
            isCurrent: isCurrent,
          ),
        ),
      ),
    ),
  );
}

class _ArtistAliasDialog extends StatefulWidget {
  const _ArtistAliasDialog({
    required this.originalName,
    required this.currentAlias,
    required this.save,
  });

  final String originalName;
  final String? currentAlias;
  final Future<bool> Function(String?) save;

  @override
  State<_ArtistAliasDialog> createState() => _ArtistAliasDialogState();
}

class _ArtistAliasDialogState extends State<_ArtistAliasDialog> {
  late final _text =
      TextEditingController(text: widget.currentAlias ?? widget.originalName);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (!_saving) Navigator.of(context).pop();
  }

  void _submit() {
    final alias = normalizeMusicArtistAlias(_text.text);
    if (alias == null) {
      setState(
          () => _error = AppLocalizations.of(context)!.musicArtistAliasInvalid);
    } else {
      _write(alias);
    }
  }

  Future<void> _write(String? alias) async {
    if (_saving) return;
    final route = ModalRoute.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    var applied = false;
    try {
      applied = await widget.save(alias);
    } catch (_) {
      // Preserve the input so the listener can retry the write.
    }
    if (!mounted || !route.isActive) return;
    if (applied) {
      if (route.isCurrent) {
        route.navigator!.pop();
      } else {
        route.navigator!.removeRoute(route);
      }
      return;
    }
    setState(() {
      _saving = false;
      _error = AppLocalizations.of(context)!.musicLibraryActionError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PlayerModalBackHandler(
      priority: 5,
      onBack: _dismiss,
      child: PopScope(
        canPop: !_saving,
        child: AlertDialog(
          scrollable: true,
          title: Text(locals.musicEditArtistAlias),
          content: TextField(
            key: const ValueKey('music-artist-alias-input'),
            controller: _text,
            enabled: !_saving,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: locals.musicArtistAlias,
              errorText: _error,
              errorMaxLines: 3,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          actions: [
            if (widget.currentAlias != null)
              TextButton(
                onPressed: _saving ? null : () => _write(null),
                child: Text(locals.musicResetArtistAlias),
              ),
            TextButton(
              onPressed: _saving ? null : _dismiss,
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(locals.save),
            ),
          ],
        ),
      ),
    );
  }
}
