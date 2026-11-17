import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/community_browse.dart';
import 'package:clipious/videos/views/components/video_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _listedUploader = 'UC0000000000000000000000';
const _warnedUploader = 'UC1111111111111111111111';

class _ListStore implements CommunityListStore {
  final snapshot = CommunitySnapshot(
    version: 1,
    generatedAt: DateTime.now(),
    blockIds: const {_listedUploader},
    blockHandles: const {},
    warnIds: const {_warnedUploader},
    warnHandles: const {},
  );

  @override
  Future<CommunitySnapshot?> load(CommunityList list) async => snapshot;

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
          {required bool Function() isCurrent}) async =>
      snapshot;
}

void main() {
  setUp(() async {
    final previous = communityFilters;
    final database = await SembastSqfDb.createInMemory();
    addTearDown(() async {
      communityFilters = previous;
      await database.close();
    });
    await database.saveSetting(
      SettingsValue(
          CommunityRule.youtubeBlock.setting, CommunityAction.hide.name),
    );
    communityFilters =
        CommunityFilters(database: () => database, repository: _ListStore());
    await communityFilters.reloadForProfile();
  });

  testWidgets('label mode shows readable block and warning labels on cards',
      (tester) async {
    await tester.runAsync(() async {
      await communityFilters.setAction(
          CommunityRule.youtubeBlock, CommunityAction.label);
      await communityFilters.setAction(
          CommunityRule.youtubeWarn, CommunityAction.label);
    });
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(children: [
          labelVideoThumbnail(
            const Video(videoId: 'a1b2c3d4e5f', authorId: _listedUploader),
            const SizedBox(width: 154, height: 86),
          ),
          labelVideoThumbnail(
            const Video(videoId: 'a1b2c3d4e5g', authorId: _warnedUploader),
            const SizedBox(width: 154, height: 86),
            focusable: false,
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    final block = find.text('Listed by AiSList');
    final warning = find.text('Warning from AiSList');
    expect(block.hitTestable(), findsOneWidget);
    expect(warning, findsOneWidget);
    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(find.text('Allow this channel'), findsOneWidget);
  });

  testWidgets('retrying an all-hidden video page retains results and cursor',
      (tester) async {
    final requested = <int>[];
    final pages = PageBasedPaginatedList<Video>(
      maxResults: 1,
      getItemsFunc: (page, _) async {
        requested.add(page);
        if (page == 1) {
          return [
            const Video(videoId: 'a1b2c3d4e5f', authorId: _listedUploader)
          ];
        }
        if (requested.length == 2) throw StateError('offline');
        return [];
      },
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: VideoList(paginatedVideoList: pages, communityBrowse: true),
      ),
    ));
    await tester.pumpAndSettle();
    final locals = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    final reveal = find.textContaining(locals.communityShowHidden);
    expect(reveal, findsOneWidget);
    await tester.tap(find.text(locals.loadMore));
    await tester.pumpAndSettle();
    expect(requested, [1, 2]);
    expect(reveal, findsOneWidget);
    await tester.tap(find.text(locals.retry));
    await tester.pumpAndSettle();
    expect(requested, [1, 2, 2]);
    expect(reveal, findsOneWidget);
    expect(pages.getHasMore(), isFalse);
  });
}
