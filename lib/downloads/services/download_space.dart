import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'download_storage.dart';

class DownloadInsufficientSpace implements Exception {
  const DownloadInsufficientSpace();
}

bool isDownloadOutOfSpace(Object error) => switch (error) {
      DownloadInsufficientSpace() => true,
      PlatformException(code: 'download_no_space') => true,
      FileSystemException(:final osError) =>
        osError?.errorCode == (Platform.isWindows ? 112 : 28) ||
            (Platform.isWindows && osError?.errorCode == 39),
      DioException(error: final Object cause) => isDownloadOutOfSpace(cause),
      _ => false,
    };

int remainingDownloadGrowth(int size, int reusable) =>
    reusable >= size ? 0 : size - reusable;

Future<int> downloadFileBytes(String path) async {
  final stat = await File(path).stat();
  return stat.type == FileSystemEntityType.file ? stat.size : 0;
}

/// A staged output and its published copy can occupy the same volume at once.
Future<void> checkDownloadSpace(
    DownloadStorage storage, Map<String, int> additionalBytes) async {
  final volumes = <String, ({int requiredBytes, int availableBytes})>{};
  for (final entry in additionalBytes.entries) {
    if (entry.value == 0) continue;
    final capacity = await storage.capacityFor(entry.key);
    if (capacity == null) continue;
    final previous = volumes[capacity.volume];
    final available =
        previous != null && previous.availableBytes < capacity.availableBytes
            ? previous.availableBytes
            : capacity.availableBytes;
    final required = (previous?.requiredBytes ?? 0) + entry.value;
    if (required > available) throw const DownloadInsufficientSpace();
    volumes[capacity.volume] =
        (requiredBytes: required, availableBytes: available);
  }
}
