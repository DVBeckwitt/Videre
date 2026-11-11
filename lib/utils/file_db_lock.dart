import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

const _lockWait = Duration(seconds: 30);
const _lockPoll = Duration(milliseconds: 10);

/// Serializes file commits across Flutter engines, isolates and processes.
///
/// Dart's POSIX RandomAccessFile locks belong to the process, so two isolates
/// can both acquire them. flock instead belongs to each separately opened file
/// description. Keep lock files in place: unlinking one would split the lock.
Future<T> withFileDbLock<T>(File file, Future<T> Function() action) async {
  if (Platform.isWindows) {
    final handle = await file.open(mode: FileMode.append);
    try {
      final elapsed = Stopwatch()..start();
      while (true) {
        try {
          await handle.lock(FileLock.exclusive, 0, 1);
          break;
        } on FileSystemException catch (error) {
          // ERROR_LOCK_VIOLATION, rather than a permission or storage failure.
          if (error.osError?.errorCode != 33) rethrow;
          if (elapsed.elapsed >= _lockWait) {
            throw TimeoutException('Timed out waiting for FileDB storage');
          }
          await Future<void>.delayed(_lockPoll);
        }
      }
      return await action();
    } finally {
      await handle.close();
    }
  }
  if (!(Platform.isAndroid || Platform.isLinux || Platform.isMacOS)) {
    throw UnsupportedError('FileDB locking is unavailable on this platform');
  }
  final handle = _PosixLock.open(file.path);
  try {
    await handle.acquire();
    return await action();
  } finally {
    handle.close();
  }
}

final class _PosixLock implements Finalizable {
  static final _lib = DynamicLibrary.open(Platform.isAndroid
      ? 'libc.so'
      : Platform.isLinux
          ? 'libc.so.6'
          : '/usr/lib/libSystem.B.dylib');
  static final _malloc = _lib.lookupFunction<Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)>('malloc');
  static final _free = _lib.lookupFunction<Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)>('free');
  static final _fopen = _lib.lookupFunction<
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>),
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>)>('fopen');
  static final _fileno = _lib.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('fileno');
  static final _flock =
      _lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'flock');
  static final _fclose = _lib.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('fclose');
  static final _errno =
      _lib.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          Platform.isAndroid
              ? '__errno'
              : Platform.isLinux
                  ? '__errno_location'
                  : '__error');
  // fclose accepts the finalizer's pointer; its integer return is discarded.
  // This also closes abandoned handles when their isolate group shuts down.
  static final _finalizer = NativeFinalizer(
      _lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('fclose'));

  final Pointer<Void> _file;
  final String _path;
  final Object _detach = Object();

  _PosixLock._(this._file, this._path) {
    _finalizer.attach(this, _file, detach: _detach);
  }

  factory _PosixLock.open(String path) {
    final bytes = [...utf8.encode(path), 0, 97, 43, 0]; // path and "a+"
    final buffer = _malloc(bytes.length);
    if (buffer == nullptr) throw StateError('Cannot allocate FileDB lock path');
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final file = _fopen(buffer, buffer + bytes.length - 3);
      if (file == nullptr) {
        throw FileSystemException('Cannot open FileDB lock', path,
            OSError('Native file open failed', _errno().value));
      }
      try {
        return _PosixLock._(file, path);
      } catch (_) {
        _fclose(file);
        rethrow;
      }
    } finally {
      _free(buffer);
    }
  }

  Future<void> acquire() async {
    final descriptor = _fileno(_file);
    if (descriptor < 0) {
      throw FileSystemException('Cannot access FileDB lock', _path);
    }
    final elapsed = Stopwatch()..start();
    while (_flock(descriptor, 2 | 4) != 0) {
      // LOCK_EX | LOCK_NB
      final error = _errno().value;
      final wouldBlock = Platform.isMacOS ? 35 : 11;
      if (error != wouldBlock && error != 4) {
        // EWOULDBLOCK, EINTR
        throw FileSystemException('Cannot acquire FileDB lock', _path,
            OSError('Native file lock failed', error));
      }
      if (elapsed.elapsed >= _lockWait) {
        throw TimeoutException('Timed out waiting for FileDB storage');
      }
      await Future<void>.delayed(_lockPoll);
    }
  }

  void close() {
    _finalizer.detach(_detach);
    _fclose(_file);
  }
}
