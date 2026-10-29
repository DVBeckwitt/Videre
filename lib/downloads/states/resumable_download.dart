import 'dart:io';

import 'package:dio/dio.dart';

/// Keeps a partial file only while it still belongs to the same media stream.
Future<void> downloadResumable(Dio dio, String url, String path,
    {required CancelToken cancelToken,
    required String identity,
    int? expectedSize,
    Map<String, dynamic>? headers,
    void Function(int received, int total)? onProgress}) async {
  final file = File(path);
  final marker = File('$path.identity');
  if (!await marker.exists() || await marker.readAsString() != identity) {
    if (await file.exists()) await file.delete();
    await marker.writeAsString(identity, flush: true);
  }
  var offset = await file.exists() ? await file.length() : 0;
  if (expectedSize != null && expectedSize > 0) {
    if (offset == expectedSize) {
      onProgress?.call(offset, expectedSize);
      return;
    }
    if (offset > expectedSize) {
      await file.writeAsBytes([]);
      offset = 0;
    }
  }

  // A server may ignore Range, or reject a stale partial. Neither is a reason
  // to append a whole new file to the old one.
  var rejectedRanges = 0;
  var knownSize = expectedSize;
  while (true) {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final response = await dio.get<ResponseBody>(url,
        cancelToken: cancelToken,
        options: Options(
            responseType: ResponseType.stream,
            validateStatus: (status) =>
                status == 200 || status == 206 || status == 416,
            headers: {
              ...?headers,
              HttpHeaders.acceptEncodingHeader: 'identity',
              if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-',
            }));
    final body = response.data!;
    final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    if (response.statusCode == 416) {
      await body.stream.listen(null).cancel();
      final total = int.tryParse(range.replaceFirst('bytes */', ''));
      if (total != null &&
          total > 0 &&
          offset == total &&
          (knownSize == null || knownSize == total)) {
        onProgress?.call(offset, total);
        return;
      }
      await file.writeAsBytes([]);
      offset = 0;
      if (++rejectedRanges >= 2) {
        throw const HttpException('Server rejected the download range');
      }
      continue;
    }

    var total = knownSize ?? -1;
    int? responseEnd;
    if (response.statusCode == 206) {
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(range);
      final start = match == null ? null : int.parse(match[1]!);
      final end = match == null ? null : int.parse(match[2]!);
      final size = match == null ? null : int.tryParse(match[3]!);
      if (start != offset ||
          end == null ||
          end < offset ||
          (size != null && end >= size) ||
          (knownSize != null && end >= knownSize) ||
          (knownSize != null && size != null && knownSize != size)) {
        await body.stream.listen(null).cancel();
        await file.writeAsBytes([]);
        throw const FormatException('Invalid download byte range');
      }
      knownSize ??= size;
      total = knownSize ?? -1;
      responseEnd = end + 1;
    } else {
      offset = 0;
      total = knownSize ??
          int.tryParse(
              response.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
          -1;
    }

    final output =
        await file.open(mode: offset > 0 ? FileMode.append : FileMode.write);
    var count = offset;
    try {
      await for (final chunk
          in body.stream.timeout(const Duration(seconds: 30))) {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        if ((responseEnd != null && count + chunk.length > responseEnd) ||
            (total > 0 && count + chunk.length > total)) {
          // Do not let a malformed response become a reusable "complete" file.
          await output.truncate(offset);
          throw const FormatException('Download exceeded its byte range');
        }
        await output.writeFrom(chunk);
        count += chunk.length;
        onProgress?.call(count, total);
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (count == 0 ||
          (responseEnd != null
              ? count != responseEnd
              : total > 0 && count != total)) {
        throw const HttpException('Incomplete download');
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (responseEnd == null || count == total) return;
    // A valid partial response can cover less than the requested suffix.
    // Continue from its end without spending a retry on a successful transfer.
    offset = count;
  }
}
