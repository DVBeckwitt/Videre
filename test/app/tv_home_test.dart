import 'package:clipious/app/states/tv_home.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('closing the home menu cancels its pending collapse',
      (tester) async {
    final home = TvHomeCubit(true);
    home.menuItemFocusChanged(false);

    await home.close();
    await tester.pump(const Duration(milliseconds: 50));

    expect(home.isClosed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement home menu cannot cancel the old menu timer',
      (tester) async {
    final first = TvHomeCubit(true);
    final second = TvHomeCubit(false);
    addTearDown(first.close);
    addTearDown(second.close);

    first.menuItemFocusChanged(false);
    second.menuItemFocusChanged(true);
    await tester.pump(const Duration(milliseconds: 50));

    expect(first.state, isFalse);
    expect(second.state, isTrue);
  });

  testWidgets('moving between menu items keeps the menu expanded',
      (tester) async {
    final home = TvHomeCubit(true);
    addTearDown(home.close);

    home.menuItemFocusChanged(false);
    await tester.pump(const Duration(milliseconds: 25));
    home.menuItemFocusChanged(true);
    await tester.pump(const Duration(milliseconds: 50));

    expect(home.state, isTrue);
  });
}
