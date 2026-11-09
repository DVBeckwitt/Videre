import 'dart:convert';

import 'package:clipious/service.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
      'decodes the SponsorBlock music_offtopic response without losing precision',
      () {
    // Public Thriller response shape captured on 2026-11-08.
    final segment = SponsorSegment.fromJson({
      'actionType': 'skip',
      'category': 'music_offtopic',
      'segment': [0, 253.179],
      'videoDuration': 821.901,
    });

    expect(segment.actionType, 'skip');
    expect(segment.category, SponsorSegmentType.musicOffTopic);
    expect(segment.segment, [0.0, 253.179]);
    expect(segment.toJson()['category'], 'music_offtopic');
  });

  for (final category in SponsorSegmentType.values) {
    test('${category.segmentName} round trips through the API category name',
        () {
      final json = {
        'actionType': 'skip',
        'category': category.segmentName,
        'segment': [1.25, 2.75],
      };

      final segment = SponsorSegment.fromJson(json);

      expect(segment.category, category);
      expect(segment.toJson(), json);
    });
  }

  test('wire names do not change existing category preferences', () {
    expect(SponsorSegmentType.musicOffTopic.settingsName(),
        'sponsor-block-musicOffTopic');
    expect(SponsorSegmentType.musicOffTopic.isEnabled(null), isTrue);
    expect(SponsorSegmentType.sponsor.isEnabled(null), isTrue);
    expect(SponsorSegmentType.musicOffTopic.isEnabled('false'), isFalse);
    expect(SponsorSegmentType.sponsor.isEnabled('false'), isFalse);
    expect(SponsorSegmentType.values.where((type) => type.isEnabled(null)),
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
  });

  test('requests Music categories using the playing video ID and API names',
      () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'sponsor.ajay.app');
      expect(request.url.path, '/api/skipSegments');
      expect(request.url.queryParameters['videoID'], 'sOnqjkJTMaA');
      expect(jsonDecode(request.url.queryParameters['categories']!),
          ['sponsor', 'music_offtopic']);
      return http.Response(
          '[{"actionType":"skip","category":"music_offtopic",'
          '"segment":[0,253.179]}]',
          200,
          headers: {'content-type': 'application/json'});
    });
    addTearDown(client.close);

    final segments = await Service(httpClient: client).getSponsorSegments(
        'sOnqjkJTMaA',
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);

    expect(segments, hasLength(1));
    expect(segments.single.category, SponsorSegmentType.musicOffTopic);
    expect(segments.single.segment, [0.0, 253.179]);
  });

  test('malformed and unsupported entries preserve valid sibling segments',
      () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode([
          {
            'actionType': 'skip',
            'category': 'sponsor',
            'segment': [1, 2]
          },
          {
            'actionType': 'skip',
            'category': 'future_category',
            'segment': [2, 3]
          },
          null,
          'malformed entry',
          {
            'actionType': 'skip',
            'category': 'sponsor',
            'segment': ['bad', 4]
          },
          {
            'category': 'sponsor',
            'segment': [4, 5]
          },
          {
            'actionType': 'skip',
            'category': 'intro',
            'segment': [5, 6]
          },
        ]),
        200,
        headers: {'content-type': 'application/json'}));
    addTearDown(client.close);

    final segments = await Service(httpClient: client).getSponsorSegments(
        'example', [SponsorSegmentType.sponsor, SponsorSegmentType.intro]);

    expect(segments.map((segment) => segment.category),
        [SponsorSegmentType.sponsor, SponsorSegmentType.intro]);
    expect(segments.map((segment) => segment.segment), [
      [1.0, 2.0],
      [5.0, 6.0]
    ]);
  });

  for (final status in [404, 503]) {
    test('SponsorBlock HTTP $status leaves playback without segments',
        () async {
      final client = MockClient((_) async => http.Response('', status));
      addTearDown(client.close);

      expect(
          await Service(httpClient: client)
              .getSponsorSegments('example', [SponsorSegmentType.sponsor]),
          isEmpty);
    });
  }

  test('SponsorBlock transport failure leaves playback without segments',
      () async {
    final client =
        MockClient((_) async => throw http.ClientException('offline'));
    addTearDown(client.close);

    expect(
        await Service(httpClient: client)
            .getSponsorSegments('example', [SponsorSegmentType.sponsor]),
        isEmpty);
  });
}
