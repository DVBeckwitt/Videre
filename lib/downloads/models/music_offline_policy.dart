enum MusicOfflineQuality {
  highest(null),
  balanced(128000),
  dataSaver(64000);

  /// Target for both the source rendition and the encoded offline file.
  final int? targetBitrate;

  const MusicOfflineQuality(this.targetBitrate);
}

/// A Music download keeps these choices for every attempt. Wi-Fi-only adds a
/// restriction to the profile's download settings.
class MusicOfflinePolicy {
  final MusicOfflineQuality quality;
  final bool wifiOnly;

  const MusicOfflinePolicy({
    this.quality = MusicOfflineQuality.highest,
    this.wifiOnly = false,
  });

  factory MusicOfflinePolicy.fromJson(Object? json) {
    if (json is! Map) return const MusicOfflinePolicy();
    return MusicOfflinePolicy(
      quality: MusicOfflineQuality.values.asNameMap()[json['quality']] ??
          MusicOfflineQuality.highest,
      wifiOnly: json['wifiOnly'] == true,
    );
  }

  Map<String, Object> toJson() =>
      {'quality': quality.name, 'wifiOnly': wifiOnly};

  @override
  bool operator ==(Object other) =>
      other is MusicOfflinePolicy &&
      other.quality == quality &&
      other.wifiOnly == wifiOnly;

  @override
  int get hashCode => Object.hash(quality, wifiOnly);
}
