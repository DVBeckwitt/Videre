import 'package:audio_service/audio_service.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_media_save.dart';
import 'package:uuid/uuid.dart';

const _likePrefix = 'videre.music.like.';
const _radioPrefix = 'videre.music.radio.';

bool isMusicMediaAction(String name) =>
    name.startsWith(musicMediaSaveActionPrefix) ||
    name.startsWith(_likePrefix) ||
    name.startsWith(_radioPrefix);

class MusicMediaControls {
  MusicMediaControls(this._labels, this._library, this._song,
      {required bool canStartRadio})
      : save = _action(musicMediaSaveActionPrefix, 'audio_service_playlist_add',
            _labels.musicSaveToPlaylist),
        radio = canStartRadio
            ? _action(
                _radioPrefix, 'audio_service_radio', _labels.musicRadioStart)
            : null;

  final AppLocalizations _labels;
  final MusicLibraryService? _library;
  final MusicLibraryEntry? _song;
  final MediaControl save;
  final MediaControl? radio;
  ({MediaControl control, bool liked})? _like;

  ({MediaControl control, bool liked})? get like {
    final library = _library;
    final song = _song;
    if (library == null || song == null) return null;
    final liked = library.isLiked(song.id);
    if (_like?.liked != liked) {
      _like = (
        control: _action(
          _likePrefix,
          liked ? 'music_widget_liked' : 'music_widget_like',
          liked ? _labels.musicUnlikeSong : _labels.musicLikeSong,
        ),
        liked: liked,
      );
    }
    return _like;
  }

  static MediaControl _action(String prefix, String icon, String label) =>
      MediaControl.custom(
        name: '$prefix${const Uuid().v4()}',
        androidIcon: 'drawable/$icon',
        label: label,
      );

  List<MediaControl> addTo(List<MediaControl> transport,
      {required bool playing}) {
    // Android reserves one of five slots for Play/Pause. Rewind and fast
    // forward are custom actions on Android 13+, so order them ahead of Music.
    final available = 4 - transport.where(_isSideTransport).length;
    final likeControl = like?.control;
    final radioControl = radio;
    final actions = [
      if (likeControl != null) likeControl,
      if (playing && radioControl != null) radioControl,
      save,
      if (!playing && radioControl != null) radioControl,
    ].take(available);
    return [
      for (final control in transport)
        if (control != MediaControl.stop && control != MediaControl.skipToNext)
          control,
      ...actions,
      // Keep Stop available to transport clients and to legacy notifications.
      if (transport.contains(MediaControl.stop)) MediaControl.stop,
      if (transport.contains(MediaControl.skipToNext)) MediaControl.skipToNext,
    ];
  }
}

bool _isSideTransport(MediaControl control) =>
    control == MediaControl.skipToPrevious ||
    control == MediaControl.skipToNext ||
    control == MediaControl.rewind ||
    control == MediaControl.fastForward;

List<int> androidCompactTransportIndices(List<MediaControl> controls) {
  // audio_service filters custom actions from the pre-Android 13 notification.
  final native = controls.where((control) => control.customAction == null);
  return [
    for (final (index, control) in native.indexed)
      if (control == MediaControl.play ||
          control == MediaControl.pause ||
          _isSideTransport(control))
        index,
  ];
}
