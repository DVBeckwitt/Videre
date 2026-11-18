import 'dart:convert';

/// The phone/tablet Home chips are separate from the app's main navigation.
/// A missing order follows the defaults; an explicit empty order hides all.
class HomeTabsLayout {
  static const forYou = 'forYou';
  static const yourFeeds = 'yourFeeds';
  static const discover = 'discover';
  static const fixedIds = [forYou, yourFeeds, discover];

  static String topicId(String id) => 'topic:$id';

  final List<String>? enabledOrder;
  final bool continueWatching;

  HomeTabsLayout(
      {Iterable<String>? enabledOrder, this.continueWatching = false})
      : enabledOrder = enabledOrder == null
            ? null
            : List.unmodifiable(enabledOrder.where(_validId).toSet());

  const HomeTabsLayout.defaults()
      : enabledOrder = null,
        continueWatching = false;

  static bool _validId(String id) =>
      fixedIds.contains(id) ||
      (id.startsWith('topic:') && id.length > 6 && id.length <= 518);

  static HomeTabsLayout decode(String? raw) =>
      tryDecode(raw) ?? const HomeTabsLayout.defaults();

  static HomeTabsLayout? tryDecode(String? raw) {
    if (raw == null || raw.length > 65536) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) {
        return null;
      }
      final order = value['enabledOrder'];
      if (order != null &&
          (order is! List ||
              order.length > 100 ||
              order.any((item) => item is! String || !_validId(item)))) {
        return null;
      }
      if (value['continueWatching'] is! bool) return null;
      return HomeTabsLayout(
        enabledOrder: order == null ? null : (order as List).cast<String>(),
        continueWatching: value['continueWatching'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  List<String> orderedIds(Iterable<String> availableIds) {
    final available = availableIds.where(_validId).toSet();
    return List.unmodifiable(
        (enabledOrder ?? available).where(available.contains));
  }

  HomeTabsLayout copyWith(
          {List<String>? enabledOrder, bool? continueWatching}) =>
      HomeTabsLayout(
        enabledOrder: enabledOrder ?? this.enabledOrder,
        continueWatching: continueWatching ?? this.continueWatching,
      );

  String encode() => jsonEncode({
        'version': 1,
        'enabledOrder': enabledOrder,
        'continueWatching': continueWatching,
      });
}
