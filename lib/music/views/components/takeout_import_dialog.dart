import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/takeout_import.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<bool?> showTakeoutImport(BuildContext context) {
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent) return Future.value(false);
  return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (_) => _TakeoutImportDialog(session: session));
}

class _TakeoutImportDialog extends StatefulWidget {
  final MusicLibrarySession session;

  const _TakeoutImportDialog({required this.session});

  @override
  State<_TakeoutImportDialog> createState() => _TakeoutImportDialogState();
}

class _TakeoutImportDialogState extends State<_TakeoutImportDialog> {
  List<TakeoutCollection>? _collections;
  int _selected = 0;
  bool _reading = true;
  bool _saving = false;
  bool _cancelled = false;
  String? _error;
  int? _added;

  bool get _current =>
      mounted && !_cancelled && ModalRoute.of(context)?.isCurrent == true;

  void _close(bool result) {
    _cancelled = true;
    Navigator.pop(context, result);
  }

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final result = await const MethodChannel('videre/files')
          .invokeListMethod<dynamic>('openTakeout');
      if (!_current) return;
      if (result == null) {
        _close(false);
        return;
      }
      final files = result
          .map((row) => TakeoutFile(
              name: (row as Map)['name'] as String,
              text: row['text'] as String))
          .toList();
      // CSV decoding and validation are local, and run away from the UI isolate.
      final collections = await compute(TakeoutImport.parse, files);
      if (!mounted || !_current) return;
      if (!widget.session.isCurrent) {
        throw StateError(AppLocalizations.of(context)!.takeoutProfileChanged);
      }
      if (collections.isEmpty) {
        throw const FormatException('No supported song lists were found.');
      }
      final liked = collections
          .indexWhere((item) => item.kind == TakeoutCollectionKind.likedMusic);
      setState(() {
        _collections = collections;
        _selected = liked < 0 ? 0 : liked;
        _reading = false;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _reading = false;
          _error = _message(error);
        });
      }
    }
  }

  String _message(Object error) => switch (error) {
        FormatException() => error.message,
        PlatformException() => error.message ?? error.code,
        StateError() => error.message,
        _ => AppLocalizations.of(context)!.takeoutImportFailed,
      };

  Future<void> _import() async {
    if (!_current || _saving || _added != null) return;
    if (!widget.session.isCurrent) {
      setState(
          () => _error = AppLocalizations.of(context)!.takeoutProfileChanged);
      return;
    }
    setState(() => _saving = true);
    try {
      final added = await widget.session.library
          .importSongs(_collections![_selected].songs);
      if (!_current) return;
      if (!widget.session.isCurrent) {
        _close(false);
        return;
      }
      setState(() {
        _saving = false;
        _added = added;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _saving = false;
          _error = _message(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final collection = _collections?[_selected];
    return PopScope<bool>(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true;
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.takeoutImport),
        content: SizedBox(
          width: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_reading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(locals.takeoutReading),
              ] else if (_error != null)
                Text(_error!)
              else if (_added != null)
                Text(locals.takeoutComplete(
                    _added!, collection!.songs.length - _added!))
              else if (collection != null) ...[
                Text(locals.takeoutImportDescription),
                const SizedBox(height: 12),
                if (_collections!.length > 1)
                  DropdownButtonFormField<int>(
                    initialValue: _selected,
                    isExpanded: true,
                    decoration:
                        InputDecoration(labelText: locals.takeoutCollection),
                    items: [
                      for (var index = 0; index < _collections!.length; index++)
                        DropdownMenuItem(
                            value: index,
                            child: Text(_collections![index].name,
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _saving
                        ? null
                        : (index) => setState(() => _selected = index!),
                  )
                else
                  Text(collection.name,
                      style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(locals.takeoutPreview(collection.songs.length)),
                if (collection.kind == TakeoutCollectionKind.musicLibrary)
                  Text(locals.takeoutLibraryNotice),
                if (collection.kind == TakeoutCollectionKind.likedVideos)
                  Text(locals.takeoutLikedVideosNotice),
                if (collection.metadataMissing)
                  Text(locals.takeoutMissingTitles),
                if (collection.skippedRows + collection.duplicateRows > 0)
                  Text(locals.takeoutSkipped(
                      collection.skippedRows, collection.duplicateRows)),
                const SizedBox(height: 12),
                for (final song in collection.songs.take(3))
                  Text(
                      song.subtitle.isEmpty
                          ? song.title
                          : '${song.title} — ${song.subtitle}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                if (_saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => _close(_added != null),
              child: Text(_added != null || _error != null
                  ? MaterialLocalizations.of(context).closeButtonLabel
                  : locals.cancel)),
          if (!_reading && _error == null && _added == null)
            FilledButton(
                onPressed:
                    _saving || collection!.songs.isEmpty ? null : _import,
                child: Text(locals.takeoutConfirm)),
        ],
      ),
    );
  }
}
