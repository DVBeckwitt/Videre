import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';

/// Opens a current-format database before a widget test constructs its player.
/// Migration tests should open an unseeded database and supply legacy data.
Future<SembastSqfDb> createPlayerTestDatabase() async {
  final database = await SembastSqfDb.createInMemory();
  await database.saveSetting(SettingsValue(
      namedMusicQueuesSetting, NamedMusicQueue.encodeAll(const [])));
  return database;
}

class TestPlayerCubit extends PlayerCubit {
  TestPlayerCubit(super.initialState, super.settings,
      {super.learningTimeMicroseconds});

  @override
  Future<void> onReady() async {}

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}
}
