import 'dart:io';

import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

import '../support/media_companion_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'setup remembers each profile’s instance decision after a database reopen',
      () async {
    mockMediaCompanionTransport();
    const media = 'https://media.example';
    const instance =
        Server(url: 'https://watch.example/invidious', id: 'first');
    final directory =
        await Directory.systemTemp.createTemp('videre-companions-');
    final path = '${directory.path}/library.db';
    var database = SembastSqfDb(await databaseFactoryIo.openDatabase(path));
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });
    await database.getProfiles();
    final second = await database.createProfile('Second person');
    final secondAccount = instance.copyWith(profileId: second.id);
    await database.addAccountWithMediaCompanions(
        instance.copyWith(mediaCompanionOrigins: [media]),
        isCurrent: () => true,
        setupDecision: {media});
    await database.forProfile(second.id).addAccountWithMediaCompanions(
        secondAccount,
        isCurrent: () => true,
        setupDecision: {});

    await database.close();
    database = SembastSqfDb(await databaseFactoryIo.openDatabase(path));
    final otherProfile = database.forProfile(second.id);
    final newAccount = instance.copyWith(
        id: 'another', url: 'https://watch.example:443/invidious/');
    expect(database.mediaCompanionDecision(newAccount), {media});
    final added = await database.addAccountWithMediaCompanions(newAccount,
        isCurrent: () => true);
    expect(added!.mediaCompanionOrigins, [media]);
    expect(database.getAccount(instance.accountId)!.mediaCompanionOrigins,
        [media]);
    expect(otherProfile.mediaCompanionDecision(secondAccount), isEmpty);
    expect(
        otherProfile.getAccount(secondAccount.accountId)!.mediaCompanionOrigins,
        isEmpty);
    for (final url in [
      'https://watch.example/elsewhere',
      'https://watch.example:8443/invidious'
    ]) {
      expect(
          database.mediaCompanionDecision(instance.copyWith(url: url)), isNull);
    }

    final backup = await database.exportBackup();
    expect(backup.encode(), isNot(contains(media)));
    await otherProfile.restoreBackup(backup, replace: true);
    expect(otherProfile.mediaCompanionDecision(secondAccount), isEmpty);
    expect(
        otherProfile.getAccount(secondAccount.accountId)!.mediaCompanionOrigins,
        isEmpty);
  });
}
