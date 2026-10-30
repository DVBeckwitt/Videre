import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/feedback/feedback_controller.dart';
import 'package:clipious/feedback/models/feedback_report.dart';
import 'package:clipious/feedback/services/feedback_store.dart';
import 'package:clipious/feedback/services/feedback_submission_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryStore implements FeedbackStore {
  FeedbackSavedState state = FeedbackSavedState();
  bool failWrites = false;
  int saves = 0;
  @override
  Future<FeedbackSavedState> load() async => FeedbackSavedState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
  @override
  Future<void> save(FeedbackSavedState value) async {
    saves++;
    if (failWrites) throw StateError('storage failed');
    state = FeedbackSavedState.fromJson(
        jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>);
  }
}

FeedbackController makeController(
        MemoryStore store, Future<http.Response> Function(http.Request) handler,
        {Future<Map<String, Object>> Function()? collect}) =>
    FeedbackController(
        store: store,
        collectDiagnostics: collect,
        client: FeedbackSubmissionClient(
            endpoint: Uri.parse('https://feedback.example'),
            client: MockClient(handler)));
http.Response success() => http.Response(
    '{"status":"created","issueNumber":22,"issueUrl":"https://github.com/DVBeckwitt/Videre/issues/22"}',
    201);
Future<void> fill(FeedbackController controller) async {
  await controller.initialize();
  controller.update(
      title: 'Video stalls',
      description: 'It stops after selecting another backend.');
}

void main() {
  test(
      'draft preparation and optional diagnostics never make a network request',
      () async {
    final store = MemoryStore();
    var collected = 0, requests = 0;
    final controller = makeController(store, (_) async {
      requests++;
      return success();
    }, collect: () async {
      collected++;
      return {'appVersion': '1.22.30', 'authorization': 'secret'};
    });
    addTearDown(controller.dispose);
    await fill(controller);
    expect(collected, 0);
    expect(controller.draft.includeDiagnostics, isFalse);
    await controller.setIncludeDiagnostics(true);
    expect(controller.draft.diagnostics, {'appVersion': '1.22.30'});
    await controller.setIncludeDiagnostics(false);
    await controller.save();
    expect(controller.draft.diagnostics, isNull);
    expect(requests, 0);
    expect(collected, 1);
  });

  test('durable nonce and locked payload survive pending response and restart',
      () async {
    final store = MemoryStore();
    final bodies = <String>[];
    final first = makeController(store, (request) async {
      bodies.add(request.body);
      return http.Response('{"status":"pending"}', 202);
    });
    await fill(first);
    final id = first.draft.submissionId;
    expect(await first.submit(), isNull);
    expect(first.locked, isTrue);
    first.update(title: 'Unexpected edit');
    expect(first.draft.title, 'Video stalls');
    first.dispose();
    final second = makeController(store, (request) async {
      bodies.add(request.body);
      return success();
    });
    addTearDown(second.dispose);
    await second.initialize();
    expect(second.locked, isTrue);
    expect(second.draft.submissionId, id);
    expect((await second.submit())?.issueNumber, 22);
    expect(bodies[1], bodies[0]);
    expect(second.receipts.single.submissionId, id);
    expect(second.draft.submissionId, isNot(id));
    expect(second.draft.isEmpty, isTrue);
  });

  test(
      'the outbound snapshot is saved before HTTP and overlapping submit is ignored',
      () async {
    final store = MemoryStore();
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    var requests = 0;
    final controller = makeController(store, (request) {
      requests++;
      expect(store.state.draft?.attempted, isTrue);
      expect(store.state.draft?.submissionId,
          (jsonDecode(request.body) as Map)['submissionId']);
      entered.complete();
      return response.future;
    });
    addTearDown(controller.dispose);
    await fill(controller);
    final first = controller.submit();
    await entered.future;
    expect(await controller.submit(), isNull);
    expect(requests, 1);
    var idle = false;
    final settled = controller.waitUntilIdle().then((_) {
      idle = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    response.complete(success());
    expect((await first)?.issueNumber, 22);
    await settled;
    expect(idle, isTrue);
    expect(store.state.receipts.single.issueNumber, 22);
  });

  test('failed draft persistence blocks posting and keeps user text', () async {
    final store = MemoryStore()..failWrites = true;
    var requests = 0;
    final controller = makeController(store, (_) async {
      requests++;
      return success();
    });
    addTearDown(controller.dispose);
    await fill(controller);
    expect(await controller.submit(), isNull);
    expect(requests, 0);
    expect(controller.error?.code, 'storage');
    expect(controller.draft.title, 'Video stalls');
    expect(controller.locked, isFalse);
  });

  test('unavailable response retains the submitted snapshot conservatively',
      () async {
    final store = MemoryStore();
    final controller =
        makeController(store, (_) async => http.Response('unavailable', 503));
    addTearDown(controller.dispose);
    await fill(controller);
    expect(await controller.submit(), isNull);
    expect(controller.error?.code, 'unavailable');
    expect(controller.locked, isTrue);
    controller.update(description: 'Additional reproduction details.');
    expect(controller.draft.description,
        'It stops after selecting another backend.');
  });

  test('a later rejection cannot unlock an earlier uncertain submission',
      () async {
    for (final status in [429, 503, 400, 413]) {
      final store = MemoryStore();
      var requests = 0;
      final bodies = <String>[];
      final controller = makeController(store, (request) async {
        bodies.add(request.body);
        requests++;
        return requests == 1
            ? http.Response('{"status":"pending"}', 202)
            : http.Response('retry later', status);
      });
      await fill(controller);
      await controller.submit();
      await controller.submit();
      expect(controller.locked, isTrue, reason: 'retry HTTP$status');
      controller.update(title: 'changed');
      expect(controller.draft.title, 'Video stalls');
      expect(bodies[0], bodies[1]);
      expect(store.state.draft?.attempted, isTrue);
      controller.dispose();
    }
  });

  test('dispose does not launch a late retry after an awaited save failed',
      () async {
    final store = MemoryStore();
    final controller = makeController(store, (_) async => success());
    await fill(controller);
    store.failWrites = true;
    await controller.save();
    expect(controller.error?.code, 'storage');
    final writes = store.saves;
    controller.dispose();
    store.failWrites = false;
    await Future<void>.delayed(Duration.zero);
    expect(store.saves, writes);
  });
  test('uncertain network outcome retains ID until explicit discard', () async {
    final store = MemoryStore();
    final controller = makeController(
        store, (_) async => throw const SocketException('sensitive detail'));
    addTearDown(controller.dispose);
    await fill(controller);
    final id = controller.draft.submissionId;
    expect(await controller.submit(), isNull);
    expect(controller.error?.code, 'network');
    expect(controller.locked, isTrue);
    await controller.discardDraft();
    expect(controller.draft.submissionId, isNot(id));
    expect(controller.locked, isFalse);
    expect(store.state.draft?.submissionId, controller.draft.submissionId);
  });

  test('private file storage retains optional attachment and receipt safely',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('videre-feedback-store-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileFeedbackStore(directory: () async => directory);
    final draft = FeedbackDraft.empty().copyWith(
        title: 'Report',
        description: 'Details',
        attempted: true,
        screenshot: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII='));
    await store.save(FeedbackSavedState(draft: draft));
    final reopened = FileFeedbackStore(directory: () async => directory);
    final loaded = (await reopened.load()).draft!;
    expect(loaded.toJson(), draft.toJson());
    await reopened.save(FeedbackSavedState(draft: FeedbackDraft.empty()));
    expect((await store.load()).draft!.screenshot, isNull);
  });

  test('corrupt storage is not overwritten by submitting a replacement nonce',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('videre-feedback-corrupt-');
    addTearDown(() => directory.delete(recursive: true));
    await Directory('${directory.path}/feedback').create();
    final file = File('${directory.path}/feedback/state.json');
    await file.writeAsString('corrupt');
    var requests = 0;
    final controller = FeedbackController(
        store: FileFeedbackStore(directory: () async => directory),
        client: FeedbackSubmissionClient(
            endpoint: Uri.parse('https://feedback.example'),
            client: MockClient((_) async {
              requests++;
              return success();
            })));
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.update(
        title: 'New report',
        description: 'Must not silently replace pending report');
    expect(await controller.submit(), isNull);
    expect(controller.error?.code, 'storage');
    expect(requests, 0);
    expect(await file.readAsString(), 'corrupt');
  });
}
