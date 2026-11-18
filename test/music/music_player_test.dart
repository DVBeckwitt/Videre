import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/selected_server.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:clipious/videos/views/components/info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Player extends TestPlayerCubit {
  int nextCalls = 0;
  int previousCalls = 0;
  int playlistRetries = 0;
  Object? playlistError;
  Duration? sought;

  _Player(super.initialState, super.settings);

  Future<void> seed(PlayerState next) async {
    // Start session persistence outside the widget test's fake frame clock.
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }

  @override
  void playNext({bool userInitiated = true}) => nextCalls++;

  @override
  void playPrevious() => previousCalls++;

  @override
  Object? get playlistLoadingError => playlistError;

  @override
  void retryPlaylistLoading() {
    playlistRetries++;
    playlistError = null;
    playlistLoadingRevision.value++;
  }

  @override
  void seek(Duration position) {
    sought = position;
    super.seek(position);
  }
}

class _Settings extends TestSettingsCubit {
  _Settings(super.initialState, super.appCubit);

  @override
  Future<void> saveSetting(SettingsValue value) async {
    emit(state.copyWith(settings: {...state.settings, value.name: value}));
  }
}

// A captioned track must never substitute speech recognition for missing lyrics.
class _CaptionService extends Service {
  int requests = 0;

  @override
  Future<String> getPlaybackCaptions(String videoId, Caption caption,
      {required Server server}) async {
    requests++;
    throw StateError('Unexpected caption lookup');
  }

  @override
  Future<VideoTranscript> getTranscript(String videoId, Caption caption,
      {Server? serverOverride}) async {
    requests++;
    throw StateError('Unexpected transcript lookup');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  const song = Video(
      videoId: 'song',
      title: 'Song',
      author: 'Singer',
      lengthSeconds: 180,
      musicMetadata:
          MusicMetadata(title: 'Song', artist: 'Singer', album: 'Album'));
  const next = Video(
      videoId: 'next',
      title: 'Next',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Singer'));

  setUp(() async {
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = _Settings(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
            currentlyPlaying: song,
            playQueue: ListQueue.of([next.videoId]),
            isAudio: true,
            isMini: false,
            isHidden: false,
            top: 0,
            position: const Duration(seconds: 30),
            mediaEvent: const MediaEvent(state: MediaState.ready)),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {Size size = const Size(390, 844),
      double scale = 1,
      Widget child = const MusicPlayer()}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(body: child),
        )));
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
  }

  Future<void> pressAndroidBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
  }

  Future<void> skipSponsor(WidgetTester tester) async {
    player.setEvent(const MediaEvent(
        type: MediaEventType.sponsorSkipped, state: MediaState.playing));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Lyrics asks before contacting LRCLIB and looks up the song once',
      (tester) async {
    final calls = <(String, String, int?, String)>[];
    await pump(tester,
        child: MusicPlayer(lyricsLoader: (track, duration, id) async {
      calls.add((track.title, track.artist, duration, id));
      return const MusicLyrics.synced([
        (start: Duration(seconds: 30), text: 'Fixture refrain'),
        (start: Duration(seconds: 33), text: 'Fixture refrain'),
      ], source: 'LRCLIB');
    }));
    expect(isLrclibEnabled(), isFalse);
    expect(calls, isEmpty);
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(isLrclibEnabled(), isFalse);
    expect(calls, isEmpty);

    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(isLrclibEnabled(), isTrue);
    expect(calls, [
      (
        song.musicMetadata!.title,
        song.musicMetadata!.artist,
        song.lengthSeconds,
        song.videoId
      )
    ]);
    expect(find.text('LRCLIB'), findsOneWidget);
    final lines = find.widgetWithText(ListTile, 'Fixture refrain');
    expect(lines, findsNWidgets(2));
    expect(tester.widget<ListTile>(lines.first).selected, isTrue);
    expect(tester.widget<ListTile>(lines.last).selected, isFalse);
    await tester.tap(lines.last);
    expect(player.sought, const Duration(seconds: 33));
    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pumpAndSettle();
    expect(lines, findsNothing);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(player.state.currentlyPlaying?.videoId, next.videoId);
  });

  testWidgets(
      'A lyric database miss on a captioned track never fetches speech text',
      (tester) async {
    final previousService = service;
    final captions = _CaptionService();
    service = captions;
    addTearDown(() => service = previousService);
    await tester.runAsync(() => setLrclibEnabled(true));
    final captioned = song.copyWith(
        captions: [
          Caption('English (auto-generated)', 'en', '/api/v1/captions/song')
        ],
        playbackConnection:
            BackendPlayback(const Server(url: 'https://playing.example')));
    await player.seed(player.state.copyWith(currentlyPlaying: captioned));
    var lookups = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      lookups++;
      return const MusicLyrics.unavailable();
    }));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    expect(lookups, 1);
    expect(captions.requests, 0);
    await pressAndroidBack(tester);
    expect(player.state.position, const Duration(seconds: 30));
  });

  testWidgets(
      'Lyrics distinguishes plain text, instrumental, and a provider error',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    var calls = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      calls++;
      if (calls == 1) throw StateError('temporary service failure');
      if (calls == 2) {
        return const MusicLyrics.plain('First line\nSecond line',
            source: 'LRCLIB');
      }
      return const MusicLyrics.instrumental(source: 'LRCLIB');
    }));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Unable to load lyrics'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.text('First line\nSecond line'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-lyrics-lines')), findsNothing);
    await pressAndroidBack(tester);
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Instrumental'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(calls, 3);
  });

  testWidgets('Lyrics drops a late database response after consent is revoked',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    final pending = Completer<MusicLyrics>();
    await pump(tester,
        child: MusicPlayer(lyricsLoader: (_, __, ___) => pending.future));
    await tap(tester, 'music-player-lyrics');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => setLrclibEnabled(false));
    pending.complete(const MusicLyrics.plain('Stale result'));
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
  });

  for (final (size, scale) in [
    (const Size(320, 568), 2.5),
    (const Size(390, 844), 1.0),
    (const Size(680, 320), 1.0),
    (const Size(1024, 720), 2.0),
  ]) {
    testWidgets('music artwork and controls fit $size at text scale $scale',
        (tester) async {
      await pump(tester, size: size, scale: scale);
      final artwork =
          tester.getSize(find.byKey(const ValueKey('music-player-artwork')));
      expect(artwork.width, artwork.height);
      expect(find.text('Singer'), findsWidgets);
      expect(find.text('Album'), findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const ValueKey('music-player-repeat')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short landscape keeps artwork beside reachable transport',
      (tester) async {
    await pump(tester, size: const Size(568, 256));
    final art = find.byKey(const ValueKey('music-player-artwork'));
    final before = tester.getRect(art);
    final play =
        tester.getRect(find.byKey(const ValueKey('music-player-play')));
    expect(play.left, greaterThan(before.right));
    expect(play.bottom, lessThanOrEqualTo(256));
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');
    expect(tester.getRect(art), before);
    expect(tester.takeException(), isNull);
  });

  for (final (source, present, catalogCover, savedCover, savedFrame) in [
    ('admitted download', true, true, false, false),
    ('admitted download', false, true, false, true),
    ('admitted download', true, true, true, true),
    ('explicit download', true, true, false, false),
    ('explicit download', true, false, false, true),
    ('explicit download', true, true, true, true),
    ('stream', true, false, false, false),
    ('stream', true, true, true, false),
  ]) {
    testWidgets(
        'Music artwork for $source (poster: $present, catalog: $catalogCover, saved: $savedCover, frame: $savedFrame)',
        (tester) async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      final documents = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('videre-music-poster-')))!;
      messenger.setMockMethodCallHandler(
          pathProvider, (_) async => documents.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathProvider, null);
        await documents.delete(recursive: true);
      });
      late String poster;
      File? coverFile;
      File? frameFile;
      late Server server;
      late DownloadedVideo saved;
      const songId = 'stockSong01';
      final idSong = song.copyWith(videoId: songId);
      final frame = ImageObject(
          'medium', 'https://i.ytimg.com/vi/$songId/mqdefault.jpg', 320, 180);
      final cover = ImageObject(
          null, 'https://lh3.googleusercontent.com/album=w512-h512', 512, 512);
      final music = MusicMetadata(
          title: 'Song',
          artist: 'Singer',
          thumbnails: [frame, if (catalogCover) cover]);
      await tester.runAsync(() async {
        await db.upsertServer(
            const Server(url: 'https://inv.example', inUse: true));
        await app.initState();
        server = app.state.server!;
        final audio = AdaptiveFormat(
            null,
            '128000',
            null,
            'https://inv.example/audio?itag=251',
            '251',
            'audio/webm; codecs="opus"',
            '12345',
            '1700000000000',
            'RECTANGULAR',
            'webm',
            'opus',
            null,
            null);
        final proof = DownloadPlaybackProvenance.create(
            video: idSong.copyWith(adaptiveFormats: [audio]),
            server: server,
            audioOnly: true,
            container: DownloadContainer.webm,
            audio: audio,
            videoFormat: null,
            byteLength: 12345,
            sha256: 'a' * 64)!;
        saved = DownloadedVideo(
            videoId: songId,
            title: 'Saved song',
            accountId: server.accountId,
            downloadComplete: true,
            audioOnly: true,
            container: DownloadContainer.webm,
            quality: 'audio',
            lengthSeconds: 180,
            musicMetadata: music,
            playbackProvenance: proof);
        await db.upsertDownload(saved);
        poster = await saved.thumbnailPath;
        final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAKklEQVR4nGP4z8BAEiJNNRlo1IJRC4ajBaTq+P+fgSQ0asGoBaMW/GcAAMouzU/PxmgLAAAAAElFTkSuQmCC');
        if (present) {
          await File(poster).writeAsBytes(bytes);
        }
        if (savedCover) {
          coverFile = (await saved.songCoverFile)!;
          await coverFile!.parent.create(recursive: true);
          await coverFile!.writeAsBytes(bytes);
        }
        if (savedFrame) {
          frameFile = (await saved.stockSongPosterFile)!;
          await frameFile!.parent.create(recursive: true);
          await frameFile!.writeAsBytes(bytes);
        }
      });

      final queued =
          idSong.copyWith(videoThumbnails: [frame], musicMetadata: music);
      final explicit = source == 'explicit download';
      final admitted = source == 'admitted download';
      await player.seed(player.state.copyWith(
          videos: explicit ? [] : [queued, next],
          offlineVideos: explicit ? [saved] : [],
          offlineCurrentlyPlaying: explicit ? saved : null,
          currentlyPlaying: explicit
              ? null
              : queued.copyWith(
                  playbackConnection: BackendPlayback(server),
                  playbackSourceId: admitted
                      ? DownloadPlaybackSource('file:///song', null, saved, {})
                      : null,
                  downloadPlaybackOnly: admitted)));
      // Exercise fallback selection without starting the image cache client.
      await pump(tester,
          size: const Size(1024, 720),
          child: const ServerScope(server: null, child: MusicPlayer()));

      final showsLocal = source != 'stream' && (savedCover || savedFrame);
      final files = find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is FileImage);
      Future<void> finishLocalCoverReads() async {
        final lookups = tester
            .widgetList<FutureBuilder<File?>>(find.byType(FutureBuilder<File?>))
            .map((widget) => widget.future!)
            .toList();
        if (lookups.isEmpty) return;
        var pending = lookups.length;
        for (final lookup in lookups) {
          unawaited(lookup.then<void>((_) {
            pending--;
          }));
        }
        final decoded = find.descendant(
            of: files,
            matching: find.byWidgetPredicate(
                (widget) => widget is RawImage && widget.image != null));
        bool waiting() =>
            pending > 0 ||
            (showsLocal && decoded.evaluate().length < lookups.length);
        await tester.runAsync(() async {
          final clock = Stopwatch()..start();
          while (waiting() && clock.elapsed < const Duration(seconds: 5)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            await tester.pump();
          }
        });
        await tester.pump();
        expect(waiting(), isFalse,
            reason: 'The mounted cover reads must finish');
      }

      final proxy = find.byType(Thumbnail);
      const queueKey = 'music-queue-$songId';
      final queue = find.byKey(const ValueKey(queueKey));
      void verifyArtwork(String artworkKey, IconData note) {
        final artwork = find.byKey(ValueKey(artworkKey));
        expect(artwork, findsOneWidget);
        final local = find.descendant(of: artwork, matching: files);
        final coverWidget = find.descendant(of: artwork, matching: proxy);
        if (showsLocal) {
          final file = tester.widget<Image>(local).image as FileImage;
          expect(file.file.path, (savedCover ? coverFile! : frameFile!).path);
          expect(file.file.path, isNot(poster));
          expect(coverWidget, findsNothing);
          expect(find.descendant(of: artwork, matching: find.byIcon(note)),
              findsNothing);
        } else if (source == 'stream') {
          expect(local, findsNothing);
          final thumbnail = tester.widget<Thumbnail>(coverWidget);
          expect(thumbnail.useInvidiousProxy, isTrue);
          expect(thumbnail.images!.map((image) => image.url), [
            if (catalogCover) cover.url,
            '/vi/$songId/mqdefault.jpg',
          ]);
        } else {
          expect(local, findsNothing);
          expect(coverWidget, findsNothing);
          expect(find.descendant(of: artwork, matching: find.byIcon(note)),
              findsOneWidget);
        }
      }

      await finishLocalCoverReads();
      verifyArtwork('music-player-artwork', Icons.music_note);
      expect(queue, findsOneWidget);
      verifyArtwork(queueKey, Icons.music_note);
      await pump(tester,
          child: const ServerScope(server: null, child: MusicMiniPlayer()));
      await finishLocalCoverReads();
      verifyArtwork('music-mini-artwork', Icons.music_note_rounded);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('only the active queue occurrence uses the hydrated artwork',
      (tester) async {
    const id = 'stockSong01';
    final queued = song.copyWith(videoId: id, queueEntryId: 'first');
    final second = queued.copyWith(queueEntryId: 'second');
    final frame = ImageObject('high', '/vi/$id/hqdefault.jpg', 480, 360);
    final playing = second.copyWith(
        videoThumbnails: [frame],
        musicMetadata: const MusicMetadata(
            title: 'Song', artist: 'Singer', isArtTrack: true));
    await player.seed(player.state.copyWith(
        videos: [queued, second],
        playedVideos: const ['first'],
        playQueue: ListQueue<String>(),
        currentlyPlaying: playing));
    await pump(tester,
        size: const Size(1024, 720),
        child: const ServerScope(server: null, child: MusicPlayer()));

    MusicPlaybackArtwork artwork(String occurrence) =>
        tester.widget<MusicPlaybackArtwork>(find.descendant(
            of: find.byKey(ValueKey('music-queue-$occurrence')),
            matching: find.byType(MusicPlaybackArtwork)));
    expect(artwork('first').video, same(queued));
    expect(artwork('first').video!.videoThumbnails, isEmpty);
    expect(artwork('second').video, same(playing));
    expect(artwork('second').video!.videoThumbnails.single, frame);
    expect(artwork('second').music!.isArtTrack, isTrue);
  });

  testWidgets(
      'portrait Lyrics and transport are visible with a long song title',
      (tester) async {
    final longSong = song.copyWith(
      musicMetadata: const MusicMetadata(
        title: 'James Brown - People Get Up And Drive That Funky Soul',
        artist: 'Uttkarsh Narayan',
      ),
    );
    await player.seed(player.state.copyWith(currentlyPlaying: longSong));
    await pump(tester,
        size: const Size(360, 720),
        child: const Padding(
          padding: EdgeInsets.only(top: 70, bottom: 24),
          child: MusicPlayer(),
        ));

    // The real player shares the viewport with Android bars and a toolbar.
    // All primary and secondary controls should be reachable without a scroll.
    final rail = find.byKey(const ValueKey('music-player-actions'));
    expect(tester.getRect(rail).bottom, lessThanOrEqualTo(696));
    for (final control in ['play', 'queue', 'sleep', 'sound']) {
      expect(find.byKey(ValueKey('music-player-$control')).hitTestable(),
          findsOneWidget);
    }
    final lyrics = find.byKey(const ValueKey('music-player-lyrics'));
    expect(lyrics.hitTestable(), findsOneWidget);
    expect(find.descendant(of: lyrics, matching: find.text('Lyrics')),
        findsOneWidget);
    await tester.tap(lyrics);
    await tester.pumpAndSettle();
    expect(find.text('Enable LRCLIB lyrics?'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary music actions remain reachable with large text',
      (tester) async {
    player.sleep(const SleepTimer(duration: Duration(minutes: 5)));
    await pump(tester, size: const Size(320, 568), scale: 1.8);
    await tap(tester, 'music-player-sleep');
    expect(player.state.hasTimer, isFalse);
    await tap(tester, 'music-player-sound');
    await tester.pumpAndSettle();
    final increase = find.byKey(const ValueKey('playback-speed-increase'));
    await tester.ensureVisible(increase);
    await tester.tap(increase);
    await tester.pump();
    expect(player.state.speed, 1.05);
    Navigator.of(tester.element(increase)).pop();
    await tester.pumpAndSettle();
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android Back unwinds Music queue popup, selection and player',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    final originalInterceptors = BackButtonInterceptor.describe();

    final songMenu = find.byTooltip('Music actions');
    await tester.ensureVisible(songMenu);
    await tester.tap(songMenu);
    await tester.pumpAndSettle();
    expect(find.text('Save song'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.text('Save song'), findsNothing);
    expect(player.state.isMini, isFalse);

    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);

    await tap(tester, 'music-queue-menu-${next.videoId}');
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.text('Delete'), findsNothing);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await tap(tester, 'music-queue-select-mode');
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);

    await pressAndroidBack(tester);
    expect(find.text('Play next'), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await pressAndroidBack(tester);
    expect(find.text('2 selected'), findsNothing);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(BackButtonInterceptor.describe(), originalInterceptors);
    await pressAndroidBack(tester);
    expect(player.state.isMini, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone queue contains keyboard focus above the browsing page',
      (tester) async {
    final browsingFocus = FocusNode(debugLabel: 'Covered Music search');
    addTearDown(browsingFocus.dispose);
    await pump(tester,
        child: Stack(children: [
          Center(child: TextField(focusNode: browsingFocus)),
          const MusicPlayer(),
        ]));
    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    for (final key in [
      ...List.filled(32, LogicalKeyboardKey.tab),
      ...List.filled(12, LogicalKeyboardKey.arrowDown),
      ...List.filled(12, LogicalKeyboardKey.arrowUp),
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(browsingFocus.hasFocus, isFalse,
          reason: 'Queue traversal must not focus the covered search field');
    }
    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    final queueButton = tester
        .widget<TextButton>(find.byKey(const ValueKey('music-player-queue')));
    expect(queueButton.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-sound-scroll')), findsOneWidget,
        reason: 'Closing the queue restores access to the Sound modal');
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue lock and selection keep duplicate occurrences independent',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song, next]);
    await player.seed(player.state.copyWith(
      videos: songs,
      currentlyPlaying: songs.first,
      playQueue: ListQueue.of(songs.skip(1).map(playbackQueueId)),
    ));
    await pump(tester);
    await tap(tester, 'music-player-queue');
    final duplicateId = playbackQueueId(songs[1]);
    final activeId = playbackQueueId(songs.first);
    final drag = find.byKey(ValueKey('music-queue-drag-$duplicateId'));
    expect(drag, findsOneWidget);
    await tap(tester, 'music-queue-lock');
    expect(drag, findsNothing);
    await tap(tester, 'music-queue-lock');
    expect(drag, findsOneWidget);

    final duplicateRow = find.byKey(ValueKey('music-queue-$duplicateId'));
    await tester.drag(duplicateRow, const Offset(340, 0));
    await tester.pumpAndSettle();
    await tester.drag(duplicateRow, const Offset(-340, 0));
    await tester.pumpAndSettle();
    expect(
        player.state.videos.map(playbackQueueId), songs.map(playbackQueueId));
    expect(
        find.byKey(ValueKey('music-queue-select-$duplicateId')), findsNothing);

    await tester.longPress(find.byKey(ValueKey('music-queue-$duplicateId')));
    await tester.pumpAndSettle();
    bool checked(String id) => tester
        .widget<Checkbox>(find.byKey(ValueKey('music-queue-select-$id')))
        .value!;
    expect(checked(duplicateId), isTrue);
    expect(checked(activeId), isFalse);
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove selected from queue'));
    await tester.pumpAndSettle();
    expect(player.state.videos.map(playbackQueueId), [activeId, next.videoId]);
    expect(player.state.currentQueueId, activeId);
  });

  testWidgets('long-pressing next seeks without changing tracks',
      (tester) async {
    await pump(tester);
    final nextButton = find.byKey(const ValueKey('music-player-next'));
    await tester.ensureVisible(nextButton);
    await tester.longPress(nextButton);
    expect(player.sought, Duration(seconds: 30 + settings.state.skipStep));
    expect(player.nextCalls, 0);
    expect(player.state.currentQueueId, playbackQueueId(song));
  });

  testWidgets(
      'music controls use shared transport seek shuffle repeat and queue',
      (tester) async {
    await pump(tester);
    await tap(tester, 'music-player-play');
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    await tap(tester, 'music-player-next');
    await tap(tester, 'music-player-previous');
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);

    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await tester.pump();
    expect(player.sought, const Duration(seconds: 45));
    await tap(tester, 'music-player-shuffle');
    expect(settings.state.playerShuffleMode, isTrue);
    final repeatButton = find.byKey(const ValueKey('music-player-repeat'));
    await tester.ensureVisible(repeatButton);
    await tester.pump();
    await tester.runAsync(() async {
      final committed = settings.stream.firstWhere(
          (state) => state.playerRepeatMode == PlayerRepeat.repeatAll);
      await tester.tap(repeatButton);
      await committed.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    expect(settings.state.playerRepeatMode, PlayerRepeat.repeatAll);
    expect(db.getSettings(playerRepeat)?.value,
        PlayerRepeat.repeatAll.index.toString());
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');
    expect(find.byKey(const ValueKey('music-player-title')), findsOneWidget);
  });

  testWidgets('expanded phone and tablet music avoid video information tabs',
      (tester) async {
    for (final widget in [
      const ExpandedPlayer(),
      const TabletExpandedPlayer()
    ]) {
      await pump(tester, child: widget);
      expect(find.byType(MusicPlayer), findsOneWidget);
      expect(find.byType(VideoInfo), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown duration and live music cannot seek to a fabricated end',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    for (final track in [
      song.copyWith(lengthSeconds: null),
      song.copyWith(liveNow: true)
    ]) {
      await player.seed(player.state.copyWith(currentlyPlaying: track));
      await pump(tester,
          child: MusicPlayer(
              lyricsLoader: (_, __, ___) async => const MusicLyrics.synced(
                  [(start: Duration(seconds: 10), text: 'Fixture line')])));
      final slider = tester
          .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
      expect(slider.onChanged, isNull);
      expect(slider.onChangeEnd, isNull);
      expect(slider.value.isFinite, isTrue);
      await tap(tester, 'music-player-lyrics');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('music-lyrics-lines')), findsNothing);
      expect(find.text('Fixture line'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Fixture line'), findsNothing);
      await tester.tap(find.text('Fixture line'));
      expect(player.sought, isNull);
      await pressAndroidBack(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('artwork swipes use the queue without seeking the current song',
      (tester) async {
    await pump(tester);
    final artwork = find.byKey(const ValueKey('music-player-artwork'));
    await tester.drag(artwork, const Offset(-150, 0));
    await tester.pump();
    expect(player.nextCalls, 1);
    await tester.drag(artwork, const Offset(150, 0));
    await tester.pump();
    expect(player.previousCalls, 1);
    expect(player.sought, isNull);
  });

  testWidgets('held artwork swipe retires when a duplicate occurrence changes',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester);
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('music-player-artwork'))));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    await player.seed(player.state.copyWith(currentlyPlaying: songs.last));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.nextCalls, 0);
    expect(player.previousCalls, 0);
  });

  testWidgets('queue menu moves an occurrence without changing the active song',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(songs.skip(1).map(playbackQueueId))));
    await pump(tester, size: const Size(1024, 720));
    await tester.tap(find
        .byKey(ValueKey('music-queue-menu-${playbackQueueId(songs.last)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(player.state.videos.map(playbackQueueId), [
      playbackQueueId(songs.first),
      playbackQueueId(songs.last),
      playbackQueueId(songs[1]),
    ]);
    expect(player.state.currentQueueId, playbackQueueId(songs.first));
    expect(player.state.currentlyPlaying, songs.first);
    expect(player.state.playQueue.toList(),
        [playbackQueueId(songs.last), playbackQueueId(songs[1])]);
    expect(player.sought, isNull);
  });

  testWidgets('wide queue shows the real upcoming order and can collapse',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final repeat = playbackQueueId(songs.last);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of([repeat, next.videoId])));
    await pump(tester, size: const Size(1024, 720));
    final repeatedRow = find.byKey(ValueKey('music-queue-$repeat'));
    final nextRow = find.byKey(ValueKey('music-queue-${next.videoId}'));
    expect(tester.getTopLeft(repeatedRow).dy,
        lessThan(tester.getTopLeft(nextRow).dy));
    final indicator = find.byKey(const ValueKey('music-queue-active'));
    expect(tester.widget<Icon>(indicator).icon, Icons.play_arrow_rounded);
    await player.seed(player.state.copyWith(
        isPlaying: true,
        mediaEvent: const MediaEvent(state: MediaState.playing)));
    await tester.pump();
    expect(tester.widget<Icon>(indicator).icon, Icons.equalizer);
    await tap(tester, 'music-player-close-queue');
    expect(find.byType(MusicQueue), findsNothing);
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(find.byKey(const ValueKey('music-queue-shuffle')).hitTestable(),
        findsOneWidget);
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets('opening a long queue scrolls to its active occurrence',
      (tester) async {
    final history =
        List.generate(30, (index) => next.copyWith(videoId: 'earlier-$index'));
    await player.seed(player.state.copyWith(
      videos: [song, next, ...history],
      playedVideos: history.map(playbackQueueId).toList(),
      playQueue: ListQueue.of([next.videoId]),
    ));
    await pump(tester);
    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-queue-active')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-queue-earlier-0')).hitTestable(),
        findsNothing);
  });

  testWidgets('remote focus keeps the selected Music queue row visible',
      (tester) async {
    final upcoming = List.generate(
        30,
        (index) => next.copyWith(
            videoId: 'upcoming-$index',
            musicMetadata:
                MusicMetadata(title: 'Upcoming $index', artist: 'Singer')));
    await player.seed(player.state.copyWith(
      videos: [song, ...upcoming],
      playQueue: ListQueue.of(upcoming.map(playbackQueueId)),
    ));
    await pump(tester,
        size: const Size(1024, 720), child: const MusicQueue(television: true));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('music-queue-upcoming-6'));
    expect(row.hitTestable(), findsOneWidget);
    Focus.of(tester.element(find.text('Upcoming 6'))).requestFocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(row.hitTestable(), findsOneWidget,
        reason: 'Focusing a row must reveal that row, not the whole sliver');
    final viewport = tester.getRect(find.byType(Scrollable));
    expect(tester.getRect(row).center.dy, closeTo(viewport.center.dy, 1));
  });

  testWidgets('a queue order change retires a pending indexed drag',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final initialOrder = songs.skip(1).map(playbackQueueId).toList();
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(initialOrder)));
    await pump(tester, size: const Size(1024, 720));
    ReorderableListView list() =>
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list().onReorderStart!(1);
    final newOrder = initialOrder.reversed.toList();
    await player.seed(player.state.copyWith(playQueue: ListQueue.of(newOrder)));
    await tester.pump();
    list().onReorder(1, 3);
    expect(player.state.playQueue.toList(), newOrder);
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets('completed song forwards Play to the shared audio decoder',
      (tester) async {
    await player.seed(player.state.copyWith(
        position: const Duration(seconds: 180),
        mediaEvent: const MediaEvent(state: MediaState.completed)));
    await pump(tester);
    await tap(tester, 'music-player-play');
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  testWidgets('a stale seek gesture cannot move a replacement song',
      (tester) async {
    await pump(tester);
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(
        player.state.copyWith(currentlyPlaying: next, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    await tester.pump();
    expect(player.sought, isNull);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('music-player-progress')))
            .value,
        0);
  });

  testWidgets('rotation cancels an unfinished seek without moving the song',
      (tester) async {
    await pump(tester);
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await tester.pump();
    await pump(tester, size: const Size(680, 256));
    oldSlider.onChangeEnd!(120000);
    await tester.pump();
    expect(player.sought, isNull);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('music-player-progress')))
            .value,
        30000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active pointer seek cannot carry into the next song',
      (tester) async {
    await pump(tester);
    final progress = find.byKey(const ValueKey('music-player-progress'));
    await tester.ensureVisible(progress);
    final rect = tester.getRect(progress);
    final gesture = await tester.startGesture(rect.center);
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(player.sought, isNull);
    await player.seed(
        player.state.copyWith(currentlyPlaying: next, position: Duration.zero));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.sought, isNull);
    expect(tester.widget<Slider>(progress).value, 0);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1024, 720)]) {
    testWidgets('Music skip feedback stays visible with its queue at $size',
        (tester) async {
      await pump(tester, size: size);
      await skipSponsor(tester);
      expect(find.text('Sponsor skipped'), findsOneWidget);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Semantics && widget.properties.liveRegion == true),
          findsOneWidget);
      if (find.byType(MusicQueue).evaluate().isEmpty) {
        await tap(tester, 'music-player-queue');
      }
      expect(find.byType(MusicQueue), findsOneWidget);
      final notice = tester.getRect(find.text('Sponsor skipped'));
      expect(notice.top, greaterThanOrEqualTo(0));
      expect(notice.bottom, lessThan(size.height));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Sponsor skipped'), findsNothing);
    });
  }

  testWidgets('skip feedback persists through events and restarts its timeout',
      (tester) async {
    await pump(tester);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Sponsor skipped'), findsNothing);
  });

  testWidgets('skip feedback clears for duplicate queue entries and disposal',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester);
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await player.seed(player.state.copyWith(currentlyPlaying: songs.last));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsNothing);
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    expect(find.byType(MusicSponsorNotice), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate song occurrences have separate selection and seek ownership',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester, size: const Size(1024, 720));
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(player.state
        .copyWith(currentlyPlaying: songs.last, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    expect(player.sought, isNull);
    final rows = tester
        .widgetList<ListTile>(find.descendant(
            of: find.byType(MusicQueue), matching: find.byType(ListTile)))
        .toList();
    expect(rows.where((row) => row.selected), hasLength(1));
    expect(rows.singleWhere((row) => row.selected).key,
        ValueKey('music-queue-${playbackQueueId(songs.last)}'));
    await tester.runAsync(
        () async => player.removeVideoFromQueue(playbackQueueId(songs.first)));
    await tester.pump();
    expect(player.state.videos.map(playbackQueueId),
        [playbackQueueId(songs[1]), playbackQueueId(songs.last)]);
    expect(player.state.currentlyPlaying, songs.last);
  });

  testWidgets('music can cancel its existing sleep timer', (tester) async {
    player.sleep(const SleepTimer(duration: Duration(minutes: 5)));
    await pump(tester);
    expect(player.state.hasTimer, isTrue);
    await tap(tester, 'music-player-sleep');
    expect(player.state.hasTimer, isFalse);
    expect(find.text('Cancel sleep timer'), findsNothing);
  });

  testWidgets(
      'sleep dialog Back preserves playback and End of song stops autoplay',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tap(tester, 'music-player-sleep');
    await tester.pumpAndSettle();
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-sleep-duration')));
    expect((slider.min, slider.max, slider.divisions, slider.value),
        (5.0, 120.0, 23, 30.0));
    await pressAndroidBack(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(player.state.hasTimer, isFalse);

    await tap(tester, 'music-player-sleep');
    await tester.pumpAndSettle();
    await tap(tester, 'music-sleep-end-of-song');
    await tester.pumpAndSettle();
    expect(player.state.hasTimer, isTrue);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await tester.pump();
    expect(player.state.hasTimer, isFalse);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(player.nextCalls, 0);
    expect(player.state.currentQueueId, playbackQueueId(song));
  });

  testWidgets('minimizing and expanding music keeps the mounted audio decoder',
      (tester) async {
    final queued = song.copyWith(
        videoThumbnails: [
          ImageObject('medium', '/vi/song/mqdefault.jpg', 320, 180)
        ],
        deArrowThumbnailUrl:
            'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=song');
    await player.seed(player.state
        .copyWith(currentlyPlaying: queued, videos: [queued, next]));
    await tester.runAsync(
        () => pump(tester, child: const Stack(children: [Player(844)])));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    final native = decoder.audioPlayer;
    for (final mini in [true, false, true, false]) {
      await player.seed(player.state.copyWith(isMini: mini));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(decoder.audioPlayer, same(native));
      expect(decoder.isClosed, isFalse);
      expect(
          find.descendant(
              of: audioBuilder,
              matching: find.byType(Thumbnail, skipOffstage: false),
              skipOffstage: false),
          findsNothing,
          reason: 'The hidden decoder must not fetch video or DeArrow artwork');
    }
    await tester.runAsync(() async {
      final closed = decoder.stream.drain<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await closed.timeout(const Duration(seconds: 2));
    });
    expect(decoder.isClosed, isTrue);
  });

  testWidgets('expanded Music keeps keyboard focus across viewport changes',
      (tester) async {
    await tester.runAsync(() async {
      await db.upsertServer(
          const Server(url: 'https://instance.example', inUse: true));
      await app.initState();
    });
    final browsingFocus = FocusNode(debugLabel: 'Covered browsing search');
    addTearDown(browsingFocus.dispose);
    final surface = LayoutBuilder(
        builder: (context, constraints) => Stack(children: [
              Center(child: TextField(focusNode: browsingFocus)),
              Player(constraints.maxHeight),
            ]));
    await tester.runAsync(() => pump(tester, child: surface));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    try {
      for (final size in [
        const Size(390, 844),
        const Size(1280, 720),
        const Size(390, 844),
      ]) {
        await pump(tester, size: size, child: surface);
        await tester.pumpAndSettle();
        expect(tester.element(audioBuilder).read<AudioPlayerCubit>(),
            same(decoder));
        // A wide player may show its side queue by default. Exercise the full
        // surface after closing it as well as the focused narrow overlay.
        final closeQueue =
            find.byKey(const ValueKey('music-player-close-queue'));
        if (closeQueue.evaluate().isNotEmpty) {
          await tester.tap(closeQueue);
          await tester.pumpAndSettle();
        }
        for (var index = 0; index < 32; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(browsingFocus.hasFocus, isFalse,
              reason: 'Expanded playback covers the browsing field at $size');
        }
        final shareIcon = find.byIcon(Icons.share);
        expect(shareIcon, findsOneWidget);
        Focus.of(tester.element(shareIcon)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Share Invidious link'), findsOneWidget);
        await pressAndroidBack(tester);
        await tap(tester, 'music-player-queue');
        await tester.pumpAndSettle();
        for (var index = 0; index < 12; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(browsingFocus.hasFocus, isFalse);
        }
        await pressAndroidBack(tester);
        expect(find.byType(MusicQueue), findsNothing);
      }
      final minimize = find.byIcon(Icons.expand_more);
      Focus.of(tester.element(minimize)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(player.state.isMini, isTrue);
      browsingFocus.requestFocus();
      await tester.pump();
      expect(browsingFocus.hasFocus, isTrue,
          reason: 'Mini playback must release the browsing page');
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(() async {
        final closed = decoder.stream.drain<void>();
        await tester.pumpWidget(const SizedBox.shrink());
        await closed.timeout(const Duration(seconds: 2));
      });
    }
  });

  testWidgets(
      'TV Music handles Select and queue Back without replacing its decoder',
      (tester) async {
    player.playlistError = StateError('next playlist page unavailable');
    // The parent supplies the displayed track. Leave the initial decoder input
    // empty so this UI test does not attempt to open a native media source.
    await tester.runAsync(() => pump(tester,
        size: const Size(1280, 720),
        child: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          child: MusicScreen.tvAudio(),
        )));
    await tester.pump();
    final audioBuilder =
        find.byType(BlocBuilder<AudioPlayerCubit, AudioPlayerState>);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    final native = decoder.audioPlayer;
    expect(tester.widget<MusicPlayer>(find.byType(MusicPlayer)).television,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(player.state.mediaCommand?.type, MediaCommandType.play);

    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    expect(
        find.text('Could not load the rest of this playlist.'), findsOneWidget);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.pump();
    expect(tester.getRect(retry).bottom, lessThan(720));

    await tester.tap(retry);
    await tester.pump();
    expect(player.playlistRetries, 1);
    expect(retry, findsNothing);
    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    expect(find.byTooltip('Next song'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsOneWidget,
        reason: 'Back returns remote focus to the queue button');
    await pressAndroidBack(tester);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final closed = decoder.stream.drain<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await closed.timeout(const Duration(seconds: 2));
    });
    expect(decoder.isClosed, isTrue);
  });
}
