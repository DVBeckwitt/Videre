import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import '../screens/music.dart';

bool get supportsLocalMusicFolders =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The Settings switch and Library page share the same device folder grant.
class LocalMusicFolder extends StatefulWidget {
  const LocalMusicFolder.settings({super.key, this.library}) : _settings = true;
  const LocalMusicFolder.library({super.key, this.library}) : _settings = false;

  final LocalMusicLibrary? library;
  final bool _settings;

  @override
  State<LocalMusicFolder> createState() => _LocalMusicFolderState();
}

class _LocalMusicFolderState extends State<LocalMusicFolder> {
  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;
  bool _ready = false;
  bool? _routeCurrent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && _routeCurrent == false) {
      // A covered library route stays mounted while Settings or Now Playing is open.
      _ready = false;
      _load();
    }
    _routeCurrent = current;
  }

  Future<void> _load() async {
    await _library.initialize();
    if (!mounted) return;
    await _library.revalidate();
    if (!mounted) return;
    setState(() => _ready = true);
    if (!widget._settings &&
        _library.enabled &&
        !_library.unavailable &&
        !_library.loaded) {
      await _library.refresh();
    }
  }

  Future<void> _play(List<LocalMusicTrack> tracks, int index) async {
    try {
      await MusicScreen.playLocalTracks(context, tracks, startIndex: index);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: ListenableBuilder(
            listenable: _library,
            builder: (context, _) {
              final available = _ready && !_library.busy;
              final enabled = _library.enabled;
              final name = _library.folderName;
              final status = _library.unavailable
                  ? locals.localMusicFolderUnavailable
                  : switch (_library.error) {
                      'PICKER_UNAVAILABLE' =>
                        locals.localMusicPickerUnavailable,
                      null => null,
                      _ => locals.localMusicFolderError,
                    };
              if (widget._settings) {
                final toggle = SwitchListTile(
                    key: const ValueKey('local-music-setting'),
                    secondary: const Icon(Icons.library_music_outlined),
                    title: Text(locals.localMusicSetting),
                    subtitle:
                        Text(status ?? name ?? locals.localMusicFolderAccess),
                    value: enabled,
                    onChanged: _ready && (enabled || available)
                        ? (value) async {
                            if (value) {
                              await _library.chooseFolder();
                            } else {
                              await _library.disable();
                            }
                          }
                        : null);
                if (!_library.unavailable) return toggle;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      toggle,
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 16),
                        child: TextButton(
                          onPressed: available ? _library.chooseFolder : null,
                          child: Text(locals.localMusicChooseFolder),
                        ),
                      ),
                    ]);
              }
              final tracks = _library.tracks;
              return CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (enabled) ...[
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(name ?? locals.onDevice),
                            trailing: IconButton(
                              tooltip: locals.refresh,
                              icon: const Icon(Icons.refresh),
                              onPressed: available && !_library.unavailable
                                  ? _library.refresh
                                  : null,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Wrap(children: [
                              TextButton.icon(
                                onPressed:
                                    available ? _library.chooseFolder : null,
                                icon: const Icon(Icons.folder_open),
                                label: Text(_library.unavailable
                                    ? locals.localMusicChooseFolder
                                    : locals.localMusicChangeFolder),
                              ),
                              TextButton(
                                onPressed: _ready ? _library.disable : null,
                                child: Text(locals.localMusicForgetFolder),
                              ),
                            ]),
                          ),
                        ] else
                          ListTile(
                            leading: const Icon(Icons.folder_open),
                            title: Text(locals.localMusicChooseFolder),
                            subtitle: Text(locals.localMusicFolderAccess),
                            onTap: available ? _library.chooseFolder : null,
                          ),
                        if (!available) const LinearProgressIndicator(),
                        if (status != null ||
                            (enabled &&
                                _library.loaded &&
                                tracks.isEmpty &&
                                available))
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(status ?? locals.localMusicFolderEmpty),
                          ),
                      ]),
                ),
                if (_ready && enabled && !_library.unavailable)
                  SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      final subtitle = [track.artist, track.album]
                          .nonNulls
                          .where((s) => s.isNotEmpty)
                          .join(' • ');
                      const placeholder = Icon(Icons.music_note_outlined);
                      return ListTile(
                        key: ValueKey(track.uri),
                        leading: SizedBox.square(
                          dimension: 48,
                          child: track.artPath == null
                              ? placeholder
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.file(File(track.artPath!),
                                      fit: BoxFit.cover,
                                      cacheWidth: 144,
                                      errorBuilder: (_, __, ___) =>
                                          placeholder),
                                ),
                        ),
                        title: Text(track.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: subtitle.isEmpty
                            ? null
                            : Text(subtitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: available ? () => _play(tracks, index) : null,
                      );
                    },
                  ),
              ]);
            }));
  }
}
