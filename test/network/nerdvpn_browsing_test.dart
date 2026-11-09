import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_list.dart';
import 'package:clipious/videos/views/tv/screens/video_grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() async => db = await SembastSqfDb.createInMemory());
  tearDown(() async => db.close());

  for (final surface in ['phone', 'TV grid', 'TV shelf']) {
    testWidgets('$surface explains pending approval when browsing fails',
        (tester) async {
      final pages = SingleEndpointList<Video>(
          () async => throw const NerdVpnAccessRequired('waiting'));
      final Widget content = switch (surface) {
        'phone' => VideoList(paginatedVideoList: pages),
        'TV grid' => TvGridScreen(paginatedVideoList: pages, title: 'Videos'),
        _ => TvHorizontalItemList<Video>(
            paginatedList: pages,
            getPlaceholder: () => const SizedBox.shrink(),
            buildItem: (_, __, ___) => const SizedBox.shrink()),
      };
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: content),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('NerdVPN approval pending'), findsOneWidget);
      expect(find.textContaining('Check eligibility'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
