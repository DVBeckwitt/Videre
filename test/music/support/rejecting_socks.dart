import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<(String, int)> rejectSocksConnect(Socket socket) async {
  final bytes = StreamIterator<int>(socket.expand((chunk) => chunk));
  Future<List<int>> read(int length) async {
    final result = <int>[];
    while (result.length < length) {
      if (!await bytes.moveNext()) throw StateError('Incomplete SOCKS frame');
      result.add(bytes.current);
    }
    return result;
  }

  try {
    expect(await read(3), [5, 1, 0]);
    socket.add([5, 0]);
    await socket.flush();
    expect(await read(4), [5, 1, 0, 3]); // CONNECT, unresolved domain.
    final nameLength = (await read(1)).single;
    final host = ascii.decode(await read(nameLength));
    final port = await read(2);
    socket.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]); // Connection refused.
    await socket.flush();
    return (host, port.first * 256 + port.last);
  } finally {
    socket.destroy();
    await bytes.cancel();
  }
}
