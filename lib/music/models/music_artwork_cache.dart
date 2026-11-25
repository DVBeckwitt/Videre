const musicArtworkCacheLimitSettingName = 'music-artwork-cache-limit-mib';
const musicArtworkCacheDefaultLimitMiB = 128;
const musicArtworkCacheLimitsMiB = [16, 32, 64, 128, 256, 512];

typedef MusicArtworkCacheStatus = ({
  int usedBytes,
  int limitMiB,
  bool hasTransfers,
});
typedef MusicArtworkCacheEntry = ({
  int bytes,
  DateTime touched,
  Future<void> Function() remove,
});

int? parseMusicArtworkCacheLimit(String? value) {
  final limit = int.tryParse(value ?? '');
  return musicArtworkCacheLimitsMiB.contains(limit) && '$limit' == value
      ? limit
      : null;
}

/// Bounds temporary disk writes across both artwork stores of one profile.
class MusicArtworkStagingBudget {
  MusicArtworkStagingBudget(this.limitBytes, {this.onPressure});

  final int Function() limitBytes;
  final void Function()? onPressure;
  int _reserved = 0;
  int _indexedBytes = 0;
  int get excess => _reserved - limitBytes();

  bool reserve(int bytes) {
    if (bytes > limitBytes() - _reserved) return false;
    _reserved += bytes;
    return true;
  }

  void measureIndexed(int bytes) {
    if (bytes == _indexedBytes) return;
    _indexedBytes = bytes;
    wroteBytes();
  }

  void wroteBytes() {
    if (_reserved > 0 && _indexedBytes + _reserved > limitBytes()) {
      onPressure?.call();
    }
  }

  void release(int bytes) => _reserved -= bytes;
}
