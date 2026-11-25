import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';

const _settingPrefix = 'music-playlist-cover-v1:';
const _localPrefix = 'local:';
const _maximumSourceBytes = 10 * 1024 * 1024;
const _maximumSourceEdge = 8192;
const _maximumSourcePixels = 24 * 1024 * 1024;
const _coverEdge = 320;
const _maximumCoverBytes = 512 * 1024;
const _maximumEncodedLength = (_maximumCoverBytes + 2) ~/ 3 * 4;

/// Local-only artwork attached to a playlist ID in one person's library.
class MusicPlaylistCovers {
  final String profileId;
  final IDbClient _owner;
  final MusicLibraryService _library;

  MusicPlaylistCovers.forProfile(IDbClient database, this.profileId)
      : _owner = database.forProfile(profileId),
        _library = MusicLibraryService.forProfile(database, profileId);

  static bool supports(String id) =>
      id.startsWith(_localPrefix) &&
      id.length > _localPrefix.length &&
      id.length <= 128;

  String? encodedCover(String playlistId) {
    if (!supports(playlistId)) return null;
    final value = _owner.getSettings('$_settingPrefix$playlistId')?.value;
    if (value == null ||
        value.isEmpty ||
        value.length > _maximumEncodedLength) {
      return null;
    }
    return value;
  }

  Future<bool> save(String playlistId, Uint8List source,
      {required bool Function() isCurrent}) async {
    if (!supports(playlistId)) throw ArgumentError('Choose a local playlist');
    if (!isCurrent()) return false;
    final cover = await _normalize(source);
    if (!isCurrent()) return false;
    await _owner.saveSetting(
        SettingsValue('$_settingPrefix$playlistId', base64Encode(cover)));
    _library.notifyChanged();
    return true;
  }

  Future<bool> reset(String playlistId, {bool Function()? isCurrent}) async {
    if (!supports(playlistId)) throw ArgumentError('Choose a local playlist');
    if (isCurrent?.call() == false) return false;
    await _owner.deleteSetting('$_settingPrefix$playlistId');
    _library.notifyChanged();
    return true;
  }

  static Uint8List? decode(String? value) {
    if (value == null) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  static Future<Uint8List> _normalize(Uint8List source) async {
    if (source.isEmpty || source.length > _maximumSourceBytes) {
      throw const FormatException('Invalid playlist cover size');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 ||
          height < 1 ||
          width > _maximumSourceEdge ||
          height > _maximumSourceEdge ||
          width * height > _maximumSourcePixels) {
        throw const FormatException('Invalid playlist cover dimensions');
      }
      codec = await descriptor.instantiateCodec(
          targetWidth:
              width >= height && width > _coverEdge ? _coverEdge : null,
          targetHeight:
              height > width && height > _coverEdge ? _coverEdge : null);
      // The re-encoded first frame contains neither source metadata nor a URI.
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > _maximumCoverBytes) {
        throw const FormatException('Could not encode playlist cover');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
