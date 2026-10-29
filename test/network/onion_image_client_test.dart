import 'package:clipious/network/onion_image_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _origin =
    'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';

void main() {
  test('onion thumbnails follow same-origin redirects with one header copy',
      () async {
    final requests = <http.Request>[];
    final client = OnionImageClient(client: MockClient((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      expect(request.headers['cookie'], 'gandalf=session');
      return requests.length == 1
          ? http.Response('', 302, headers: {'location': '/image.jpg'})
          : http.Response('image', 200);
    }));
    addTearDown(client.close);

    final response = await client.get(Uri.parse('$_origin/thumbnail'),
        headers: {'Cookie': 'gandalf=session'});
    expect(response.statusCode, 200);
    expect(requests.map((request) => request.url.toString()),
        ['$_origin/thumbnail', '$_origin/image.jpg']);
  });

  for (final location in [
    '${_origin.replaceFirst('http:', 'https:')}/image.jpg',
    '$_origin:81/image.jpg',
    '${_origin.replaceFirst('http://', 'http://images.')}/image.jpg',
    'http://elsewhere.example/image.jpg',
    '${_origin.replaceFirst('http://', 'http://user@')}/image.jpg',
  ]) {
    test('onion thumbnail never sends a redirected request to $location',
        () async {
      var requests = 0;
      final client = OnionImageClient(client: MockClient((request) async {
        requests++;
        expect(request.followRedirects, isFalse);
        return http.Response('', 302, headers: {'location': location});
      }));
      addTearDown(client.close);

      final response = await client.get(Uri.parse('$_origin/thumbnail'),
          headers: {'Cookie': 'gandalf=session'});
      expect(response.statusCode, 302);
      expect(requests, 1);
    });
  }

  test('onion thumbnail redirect loops are bounded', () async {
    var requests = 0;
    final client = OnionImageClient(client: MockClient((request) async {
      requests++;
      return http.Response('', 302, headers: {'location': '/loop'});
    }));
    addTearDown(client.close);

    final response = await client.get(Uri.parse('$_origin/thumbnail'));
    expect(response.statusCode, 302);
    expect(requests, 4);
  });

  test('a caller can disable onion thumbnail redirects', () async {
    var requests = 0;
    final client = OnionImageClient(client: MockClient((request) async {
      requests++;
      return http.Response('', 302, headers: {'location': '/same-origin'});
    }));
    addTearDown(client.close);
    final request = http.Request('GET', Uri.parse('$_origin/thumbnail'))
      ..followRedirects = false;
    final response = await http.Response.fromStream(await client.send(request));
    expect(response.statusCode, 302);
    expect(requests, 1);
  });

  test('clearnet thumbnails retain the normal HTTP redirect policy', () async {
    final client = OnionImageClient(client: MockClient((request) async {
      expect(request.followRedirects, isTrue);
      return http.Response('image', 200);
    }));
    addTearDown(client.close);
    expect(
        (await client.get(Uri.parse('https://example.org/image'))).statusCode,
        200);
  });
}
