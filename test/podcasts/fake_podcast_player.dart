import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:flutter/foundation.dart';

class FakePodcastPlayer extends ChangeNotifier implements PodcastPlayer {
  static const sample = PodcastEpisode(
      id: 'episode-one',
      title: 'Local podcast episode',
      mediaUrl: 'https://podcast.example/episode.mp3',
      mimeType: 'audio/mpeg');

  @override
  PodcastEpisode? episode;
  @override
  String feedTitle = 'Independent podcast';
  @override
  bool playing = false;
  @override
  bool loading = false;
  @override
  bool offline = false;
  @override
  String? error;
  @override
  Duration position = const Duration(seconds: 20);
  @override
  Duration duration = const Duration(minutes: 2);
  @override
  double speed = 1;
  @override
  int generation = 0;

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final seeks = <Duration>[];

  @override
  bool get active => episode != null;

  void start() {
    episode = sample;
    generation++;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    playCalls++;
    playing = true;
    error = null;
    notifyListeners();
  }

  @override
  Future<void> stop({bool clearMediaSession = true}) async {
    stopCalls++;
    generation++;
    episode = null;
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    this.position = position;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
