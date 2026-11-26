/// A local group of subscribed channels owned by one profile.
class SubscriptionGroup {
  final String id;
  final String name;
  final Set<String> channelIds;

  SubscriptionGroup({
    required this.id,
    required String name,
    required Set<String> channelIds,
  })  : name = name.trim(),
        channelIds = Set.unmodifiable(channelIds) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must be nonempty');
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must be nonempty');
    }
  }

  factory SubscriptionGroup.fromJson(String id, Map<String, Object?> json) =>
      SubscriptionGroup(
        id: id,
        name: json['name'] as String,
        channelIds: (json['channelIds'] as List).cast<String>().toSet(),
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'channelIds': channelIds.toList(),
      };
}
