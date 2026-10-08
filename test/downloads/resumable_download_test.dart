import 'dart:io';

import 'package:clipious/downloads/states/resumable_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late Dio dio;
  late String path, url;
  late Future<void> Function(HttpRequest) respond;
  final content = List<int>.generate(12, (index) => index);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('videre-download-test');
    path = '${directory.path}/media.part';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.address}:${server.port}/media';
    dio = Dio();
    server.listen((request) async => await respond(request));
  });

  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> partial(int count, {String identity = 'stream-1'}) async {
    await File(path).writeAsBytes(content.take(count).toList());
    await File('$path.identity').writeAsString(identity);
  }

  Future<void> download(
          {int? size = 12,
          String identity = 'stream-1',
          CancelToken? cancelToken,
          void Function(int, int)? onProgress}) =>
      downloadResumable(dio, url, path,
          identity: identity,
          cancelToken: cancelToken ?? CancelToken(),
          expectedSize: size,
          onProgress: onProgress);

  test('resumes a partial from the exact byte offset', () async {
    await partial(4);
    respond = (request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 4-11/12');
      request.response.add(content.sublist(4));
      await request.response.close();
    };
    await download();
    expect(await File(path).readAsBytes(), content);
  });

  test('replaces the partial when the server ignores Range', () async {
    await partial(4);
    respond = (request) async {
      request.response.add(content);
      await request.response.close();
    };
    await download();
    expect(await File(path).readAsBytes(), content);
  });

  test('continues valid bounded ranges until the entire file is received',
      () async {
    await partial(4);
    final offsets = <int>[];
    respond = (request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      final offset = int.parse(range.substring(6, range.length - 1));
      offsets.add(offset);
      final end = offset + 4;
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $offset-${end - 1}/12');
      request.response.add(content.sublist(offset, end));
      await request.response.close();
    };
    await download();
    expect(offsets, [4, 8]);
    expect(await File(path).readAsBytes(), content);
  });

  test('uses the expected size when a range omits its total', () async {
    await partial(4);
    respond = (request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 4-11/*');
      request.response.add(content.sublist(4));
      await request.response.close();
    };
    await download();
    expect(await File(path).readAsBytes(), content);
  });

  test('requests the remaining suffix when neither source knows the total',
      () async {
    await partial(4);
    var requests = 0;
    respond = (request) async {
      if (requests++ == 0) {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
        request.response.statusCode = 206;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes 4-11/*');
        request.response.add(content.sublist(4));
      } else {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=12-');
        request.response.statusCode = 416;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */12');
      }
      await request.response.close();
    };
    await download(size: null);
    expect(requests, 2);
    expect(await File(path).readAsBytes(), content);
  });

  test('rejects an interrupted bounded range while keeping received bytes',
      () async {
    await partial(4);
    respond = (request) async {
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 4-7/12');
      request.response.add(content.sublist(4, 6));
      await request.response.close();
    };
    await expectLater(download(), throwsA(isA<HttpException>()));
    expect(await File(path).readAsBytes(), content.take(6).toList());
  });

  test('fresh media identity never appends to the previous stream', () async {
    await partial(4, identity: 'old-stream');
    respond = (request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
      request.response.add(content);
      await request.response.close();
    };
    await download();
    expect(await File(path).readAsBytes(), content);
  });

  test('416 only counts as complete when its length matches the file',
      () async {
    await partial(12);
    respond = (request) async {
      request.response.statusCode = 416;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes */12');
      await request.response.close();
    };
    await download(size: null);
    expect(await File(path).readAsBytes(), content);
  });

  test('416 for a stale partial retries once without Range', () async {
    await partial(4);
    var requests = 0;
    respond = (request) async {
      if (requests++ == 0) {
        request.response.statusCode = 416;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */2');
      } else {
        expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
        request.response.add(content);
      }
      await request.response.close();
    };
    await download();
    expect(requests, 2);
    expect(await File(path).readAsBytes(), content);
  });

  test('rejects a server range that starts at the wrong offset', () async {
    await partial(4);
    respond = (request) async {
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 0-11/12');
      request.response.add(content);
      await request.response.close();
    };
    await expectLater(download(), throwsFormatException);
    expect(await File(path).length(), 0);
  });

  test('rejects bytes beyond the advertised range without keeping them',
      () async {
    await partial(4);
    respond = (request) async {
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 4-7/12');
      request.response.add(content.sublist(4));
      await request.response.close();
    };
    await expectLater(download(), throwsFormatException);
    expect(await File(path).readAsBytes(), content.take(4).toList());
  });

  test('keeps bytes after a truncated transfer and resumes them next time',
      () async {
    respond = (request) async {
      request.response.add(content.take(4).toList());
      await request.response.close();
    };
    await expectLater(download(), throwsA(isA<HttpException>()));
    expect(await File(path).length(), 4);
    respond = (request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
      request.response.statusCode = 206;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 4-11/12');
      request.response.add(content.sublist(4));
      await request.response.close();
    };
    await download();
    expect(await File(path).readAsBytes(), content);
  });

  test('cancellation preserves the partial and never reports completion',
      () async {
    final token = CancelToken();
    respond = (request) async {
      request.response.add(content.take(4).toList());
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await request.response.close();
    };
    await expectLater(
        download(
            cancelToken: token,
            onProgress: (count, total) {
              token.cancel();
            }),
        throwsA(isA<DioException>()));
    expect(await File(path).length(), 4);
  });

  test('a forbidden expired URL leaves partial bytes ready for a fresh URL',
      () async {
    await partial(4);
    respond = (request) async {
      request.response.statusCode = 403;
      await request.response.close();
    };
    await expectLater(download(), throwsA(isA<DioException>()));
    expect(await File(path).length(), 4);
  });
}
