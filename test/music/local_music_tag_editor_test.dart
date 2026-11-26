import 'dart:async';
import 'dart:convert';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/l10n/generated/app_localizations_en.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/music/views/components/local_music_tag_editor.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const filesChannel = MethodChannel('videre/files');
  const otherTree = 'content://provider/tree/other';
  const tree = 'content://provider/tree/music';
  const file = '$tree/document/song';
  const selection = 'approved-source';
  final revision = List.filled(64, 'a').join();
  final locals = AppLocalizationsEn();
  const plain = 'Original line\nAnother line';
  const timed = '[00:01.000]Timed line';
  const trackData = {
    'uri': file,
    'title': 'Indexed title',
    'artist': 'Indexed artist',
    'fileName': 'song.mp3',
    'canEditTags': true,
    'trackNumber': 3,
    'discNumber': 1,
    'durationMs': 4000,
  };
  const values = {
    'title': 'Embedded title',
    'artist': 'Embedded artist',
    'album': 'Embedded album',
    'albumArtist': null,
    'trackNumber': '03',
    'trackTotal': '12',
    'discNumber': '1',
    'discTotal': null,
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LocalMusicLibrary library;
  late SembastSqfDb database;
  late List<Object?> writes;
  late List<String> editableFields;
  late FutureOr<Object?> Function() writeResult;
  late bool? artworkEditable;
  late bool hasArtwork;
  late bool? artworkRemovable;
  late Uint8List? selectedArtwork;
  late int pickerCalls;
  late int? id3Version;
  late Map<String, String?> embeddedValues;

  setUp(() async {
    library = LocalMusicLibrary();
    database = await SembastSqfDb.createInMemory();
    writes = [];
    editableFields = values.keys.toList();
    id3Version = null;
    embeddedValues = values;
    artworkEditable = null;
    hasArtwork = false;
    artworkRemovable = null;
    selectedArtwork = null;
    pickerCalls = 0;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'openPlaylistCover');
      expect(call.arguments, isNull);
      pickerCalls++;
      return selectedArtwork;
    });
    writeResult = () => {
          ...trackData,
          'title': 'Corrected title',
          'artist': null,
        };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {
            'selectionId': 'combined-selection',
            'roots': [
              {
                'uri': otherTree,
                'name': 'Other',
                'selectionId': 'other-source'
              },
              {'uri': tree, 'name': 'Music', 'selectionId': selection},
            ],
          };
        case 'checkFolderAccess':
          return true;
        case 'listTracks':
          return call.arguments['treeUri'] == tree ? [trackData] : [];
        case 'readTrackTags':
          expect(call.arguments,
              {'treeUri': tree, 'selectionId': selection, 'uri': file});
          return {
            'revision': revision,
            'values': embeddedValues,
            if (id3Version != null) 'id3Version': id3Version,
            'editableFields': editableFields,
            if (artworkEditable != null) ...{
              'artworkEditable': artworkEditable,
              'hasArtwork': hasArtwork,
              'artworkRemovable': artworkRemovable ?? hasArtwork,
            },
          };
        case 'editTrackTags':
          writes.add(call.arguments);
          return writeResult();
        default:
          throw MissingPluginException(call.method);
      }
    });
    await library.refresh();
  });

  tearDown(() async {
    library.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(filesChannel, null);
    await database.close();
  });

  LocalMusicLyricsAuthoring authoring() => LocalMusicLyricsAuthoring.forTrack(
        database: database,
        track: library.tracks.single,
        isCurrent: () => true,
      )!;

  Future<void> openEditor(WidgetTester tester,
      {LocalMusicLyricsAuthoring? lyrics}) async {
    final track = library.tracks.single;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => editLocalMusicTags(context, library, track,
                isCurrent: () => true, authoring: lyrics),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  final save = find.widgetWithText(FilledButton, 'Save');

  Future<void> tapCoverAction(WidgetTester tester, String label) async {
    final action = find.text(label);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  Future<void> enterNumber(
      WidgetTester tester, String label, String text) async {
    await tester.ensureVisible(field(label));
    await tester.enterText(field(label), text);
    await tester.pumpAndSettle();
  }

  testWidgets('edits genre and validates an ID3v2.4 release month',
      (tester) async {
    id3Version = 4;
    embeddedValues = {...values, 'genre': 'Jazz', 'releaseDate': '2001'};
    editableFields = embeddedValues.keys.toList();
    await openEditor(tester);

    await tester.ensureVisible(field('Genre'));
    await tester.enterText(field('Genre'), ' Fusion ');
    await tester.ensureVisible(field('Release date'));
    await tester.enterText(field('Release date'), '2023-02-29');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(writes, isEmpty);

    await tester.enterText(field('Release date'), ' 2023-02 ');
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect((writes.single as Map)['changes'], {
      'genre': 'Fusion',
      'releaseDate': '2023-02',
    });
  });

  testWidgets('prefills embedded values and cancel makes no write',
      (tester) async {
    await openEditor(tester);
    expect(tester.widget<TextField>(field('Title')).controller!.text,
        'Embedded title');
    expect(tester.widget<TextField>(field('Album artist')).controller!.text,
        isEmpty);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(field('Title'), 'Draft');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.text('Edit tags'), findsNothing);
  });

  testWidgets('saves only changed tags on the same song', (tester) async {
    final id = library.tracks.single.playbackId;
    await openEditor(tester);
    await tester.enterText(field('Title'), 'Corrected title');
    await tester.enterText(field('Artist'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'treeUri': tree,
        'selectionId': selection,
        'uri': file,
        'revision': revision,
        'changes': {'title': 'Corrected title', 'artist': null},
      },
    ]);
    expect(library.tracks.single.playbackId, id);
    expect(library.trackById(id)?.title, 'Corrected title');
    expect(find.text('Tags saved'), findsOneWidget);
  });

  testWidgets('declined permission keeps the draft and file metadata',
      (tester) async {
    final authorization = Completer<Object?>();
    writeResult = () => authorization.future;
    await openEditor(tester);
    await enterNumber(tester, 'Track number', '4');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull);
    expect(writes, hasLength(1));
    authorization.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Write access was not granted.').hitTestable(),
        findsOneWidget);
    expect(
        tester.widget<TextField>(field('Track number')).controller!.text, '4');
    expect(library.tracks.single.trackNumber, 3);
  });

  testWidgets('sets track and disc values and clears a total on the same song',
      (tester) async {
    final id = library.tracks.single.playbackId;
    writeResult = () => {...trackData, 'trackNumber': 4, 'discNumber': 2};
    await openEditor(tester);
    expect(
        tester.widget<TextField>(field('Track number')).controller!.text, '03');
    expect(
        tester.widget<TextField>(field('Track total')).controller!.text, '12');
    expect(
        tester.widget<TextField>(field('Disc number')).controller!.text, '1');
    expect(tester.widget<TextField>(field('Disc total')).controller!.text,
        isEmpty);
    await enterNumber(tester, 'Track number', '04');
    await enterNumber(tester, 'Track total', '');
    await enterNumber(tester, 'Disc number', '2');
    await enterNumber(tester, 'Disc total', '3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'treeUri': tree,
        'selectionId': selection,
        'uri': file,
        'revision': revision,
        'changes': {
          'trackNumber': '04',
          'trackTotal': null,
          'discNumber': '2',
          'discTotal': '3',
        },
      },
    ]);
    expect(library.trackById(id)?.trackNumber, 4);
    expect(library.trackById(id)?.discNumber, 2);
  });

  testWidgets('a total below the number blocks saving until it is fixed',
      (tester) async {
    await openEditor(tester);
    await enterNumber(tester, 'Track total', '2');
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextField>(field('Track total')).decoration!.errorText,
        isNotNull);
    expect(writes, isEmpty);
    await enterNumber(tester, 'Track total', '15');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  });

  test('batch callers can validate partial changes before requesting access',
      () async {
    editableFields
        .removeWhere((field) => ['discNumber', 'discTotal'].contains(field));
    final track = library.tracks.single;
    final tags = (await library.readTags(track))!;
    expect(tags.editableFields, isNot(contains('discTotal')));
    expect(tags.validateNumberChanges({'discTotal': '2'}), 'discTotal');
    expect(tags.validateNumberChanges({'trackNumber': null}), 'trackTotal');
    expect(tags.validateNumberChanges({'trackNumber': '3\n'}), 'trackNumber');
    expect(tags.validateNumberChanges({'trackNumber': '65536'}), 'trackNumber');
    expect(
      tags.validateNumberChanges({'trackNumber': null, 'trackTotal': null}),
      isNull,
    );
    await expectLater(
      library.editTags(track, tags, {'trackTotal': '2', 'title': 'Draft'}),
      throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'TAGS_INVALID_NUMBER')),
    );
    expect(writes, isEmpty);
  });

  testWidgets('canceling the cover picker leaves the file unchanged',
      (tester) async {
    artworkEditable = true;
    await openEditor(tester);

    await tapCoverAction(tester, 'Choose front cover');

    expect(pickerCalls, 1);
    expect(writes, isEmpty);
    expect(find.text('Front cover will be replaced.'), findsNothing);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  testWidgets('declined front cover removal keeps the draft until discarded',
      (tester) async {
    artworkEditable = true;
    hasArtwork = true;
    final authorization = Completer<Object?>();
    writeResult = () => authorization.future;
    await openEditor(tester);

    await tapCoverAction(tester, 'Remove front cover');
    expect(find.text('Front cover will be removed.'), findsOneWidget);
    expect(writes, isEmpty);
    expect(pickerCalls, 0);

    await tester.tap(save);
    await tester.pump();
    expect(writes, [
      {
        'treeUri': tree,
        'selectionId': selection,
        'uri': file,
        'revision': revision,
        'changes': <String, String?>{},
        'artwork': null,
      },
    ]);

    authorization.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Write access was not granted.'), findsOneWidget);
    expect(find.text('Front cover will be removed.'), findsOneWidget);

    await tapCoverAction(tester, 'Undo cover change');
    expect(find.text('Front cover will be removed.'), findsNothing);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(writes, hasLength(1));
  });

  testWidgets('only offers replacement when artwork cannot be removed',
      (tester) async {
    artworkEditable = true;
    hasArtwork = true;
    artworkRemovable = false;
    await openEditor(tester);

    expect(find.text('Replace front cover'), findsOneWidget);
    expect(find.text('Remove front cover'), findsNothing);
    expect(writes, isEmpty);
  });

  testWidgets('saves a chosen front cover with the confirmed text edit',
      (tester) async {
    artworkEditable = true;
    hasArtwork = true;
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUB'
      'AScY42YAAAAASUVORK5CYII=',
    );
    selectedArtwork = image;
    await openEditor(tester);
    await tester.enterText(field('Title'), 'Corrected title');

    await tapCoverAction(tester, 'Replace front cover');
    expect(find.text('Front cover will be replaced.'), findsOneWidget);
    expect(pickerCalls, 1);
    expect(writes, isEmpty);

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'treeUri': tree,
        'selectionId': selection,
        'uri': file,
        'revision': revision,
        'changes': {'title': 'Corrected title'},
        'artwork': image,
      },
    ]);
    expect(library.tracks.single.title, 'Corrected title');
    expect(find.text('Tags saved'), findsOneWidget);
  });

  Future<void> tapEmbed(WidgetTester tester) async {
    final action = find.text(locals.localMusicEmbedPlainLyrics);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  testWidgets('requires plain lyrics authored for the active profile',
      (tester) async {
    final otherProfile = authoring();
    await tester.runAsync(() async {
      expect(await otherProfile.savePlain(plain, previousDraft: null), isTrue);
      final profile = await database.createProfile('Other listener');
      await database.useProfile(profile.id);
      expect(await authoring().save(timed, previousDraft: null), isTrue);
    });

    await openEditor(tester, lyrics: authoring());
    await tapEmbed(tester);
    expect(find.text(locals.localMusicEmbedLyricsTimedOnly), findsOneWidget);
    expect(find.text(locals.localMusicEmbedLyricsConfirm), findsNothing);
    expect(find.text(plain, findRichText: true), findsNothing);
    expect(writes, isEmpty);
  });

  testWidgets('reports an absent authored draft without opening a file write',
      (tester) async {
    await openEditor(tester, lyrics: authoring());
    await tapEmbed(tester);
    expect(find.text(locals.localMusicEmbedLyricsMissing), findsOneWidget);
    expect(find.text(locals.localMusicEmbedLyricsConfirm), findsNothing);
    expect(writes, isEmpty);
  });

  for (final (code, message) in [
    (null, locals.localMusicTagsDeclined),
    ('TAGS_ACCESS', locals.localMusicTagsAccess),
    ('TAGS_NO_SPACE', locals.localMusicEmbedLyricsNoSpace),
  ]) {
    testWidgets('preserves the plain draft on ${code ?? 'declined consent'}',
        (tester) async {
      final draft = authoring();
      expect(
          await tester
              .runAsync(() => draft.savePlain(plain, previousDraft: null)),
          isTrue);
      writeResult = () {
        if (code != null) throw PlatformException(code: code);
        return null;
      };

      await openEditor(tester, lyrics: draft);
      await tapEmbed(tester);
      final confirm = find.text(locals.localMusicEmbedLyricsConfirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(writes, hasLength(1));
      expect(find.text(message), findsOneWidget);
      expect(find.text(locals.localMusicEmbedLyricsSaved), findsNothing);
      expect(draft.readPlainDraft(), plain);
      expect(library.tracks.single.title, 'Indexed title');
    });
  }
}
