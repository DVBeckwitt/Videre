import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../globals.dart';
import '../settings/models/db/settings.dart';
import '../utils/interfaces/db.dart';
import 'community_models.dart';
import 'flow_list_repository.dart';

export 'community_models.dart';

CommunityFilters communityFilters =
    CommunityFilters(database: () => db, repository: FlowListRepository());

String communityExceptionsSetting(CommunityList list) =>
    'community-exceptions-${list.name}';

const _maxExceptions = 250;
const _youtubeSetupSetting = 'community-youtube-setup-complete';

CommunityAction? _savedAction(IDbClient owner, CommunityRule rule) {
  final saved = owner.getSettings(rule.setting)?.value;
  return CommunityAction.values.where((mode) => mode.name == saved).firstOrNull;
}

Set<String>? parseCommunityExceptions(String text) {
  if (text.length > 32768) return null;
  try {
    final values = jsonDecode(text);
    if (values is! List || values.length > _maxExceptions) return null;
    final valid = <String>{};
    for (final value in values) {
      if (value is! String) return null;
      final identity = value.startsWith('@')
          ? normalizeChannelHandle(value)
          : normalizeChannelId(value);
      if (identity == null ||
          value != (value.startsWith('@') ? '@$identity' : identity)) {
        return null;
      }
      valid.add(value);
    }
    return valid;
  } on FormatException {
    return null;
  }
}

class CommunityListStatus {
  const CommunityListStatus({
    this.lastUpdated,
    this.version,
    this.refreshing = false,
    this.failed = false,
  });

  final DateTime? lastUpdated;
  final int? version;
  final bool refreshing;
  final bool failed;
}

class CommunityFilters {
  CommunityFilters({
    required IDbClient Function() database,
    required CommunityListStore repository,
    DateTime Function()? now,
  })  : _database = database,
        _repository = repository,
        _now = now ?? DateTime.now;

  final IDbClient Function() _database;
  final CommunityListStore _repository;
  final DateTime Function() _now;
  final _changes = ValueNotifier(0);
  final _actions = <CommunityRule, CommunityAction>{};
  final _exceptions = <CommunityList, Set<String>>{};
  final _snapshots = <CommunityList, CommunitySnapshot>{};
  final _checks = <CommunityList, DateTime>{};
  final _failures = <CommunityList>{};
  final _epochs = <CommunityList, int>{};
  final _refreshes = <CommunityList, Future<void>>{};
  final _handlesById = <String, String>{};
  final _idsByHandle = <String, String>{};
  final _refreshInterval = Duration(hours: 24, minutes: Random().nextInt(61));
  Future<void> _pendingWrites = Future.value();
  IDbClient? _activeDatabase;
  String? _profile;
  int _profileEpoch = 0;

  Listenable get changes => _changes;
  int get revision => _changes.value;
  int get profileSelection => _profileEpoch;

  CommunityAction action(CommunityRule rule) =>
      _actions[rule] ?? CommunityAction.off;

  bool get needsYoutubeSetup =>
      _isCurrentProfile &&
      _activeDatabase!.getSettings(_youtubeSetupSetting)?.value != 'true';

  CommunityAction youtubeSetupAction(CommunityRule rule) =>
      (_isCurrentProfile ? _savedAction(_activeDatabase!, rule) : null) ??
      rule.setupDefault;

  Set<String> exceptions(CommunityList list) =>
      Set.unmodifiable(_exceptions[list] ?? const <String>{});

  bool enabled(CommunityList list) => CommunityRule.values.any(
      (rule) => rule.source == list && action(rule) != CommunityAction.off);

  CommunityListStatus status(CommunityList list) {
    final snapshot = _snapshots[list];
    return CommunityListStatus(
      lastUpdated: snapshot?.checkedAt ?? snapshot?.generatedAt,
      version: snapshot?.version,
      refreshing: _refreshes.containsKey(list),
      failed: _failures.contains(list),
    );
  }

  Future<void> reloadForProfile() async {
    final database = _database();
    _activeDatabase = database;
    _profile = database.profileId;
    _profileEpoch++;
    for (final list in CommunityList.values) {
      _cancelRefresh(list);
    }
    _handlesById.clear();
    _idsByHandle.clear();
    final owner = database.forProfile(database.profileId);
    for (final rule in CommunityRule.values) {
      _actions[rule] = _savedAction(owner, rule) ?? CommunityAction.off;
    }
    for (final list in CommunityList.values) {
      _exceptions[list] = parseCommunityExceptions(
              owner.getSettings(communityExceptionsSetting(list))?.value ??
                  '[]') ??
          {};
    }
    _changes.value++;
    await refreshIfStale();
  }

  bool get _isCurrentProfile {
    final active = _activeDatabase;
    return active != null &&
        identical(_database(), active) &&
        active.profileId == _profile;
  }

  Future<void> setAction(CommunityRule rule, CommunityAction value) =>
      _write((owner) async {
        if (value == action(rule)) return;
        final epoch = _profileEpoch;
        await owner.saveSetting(SettingsValue(rule.setting, value.name));
        if (!_isCurrentProfile || epoch != _profileEpoch) return;
        _actions[rule] = value;
        _actionsChanged(rule.source);
      });

  Future<void> completeYoutubeSetup({
    required CommunityAction block,
    required CommunityAction warning,
  }) =>
      _write((owner) async {
        if (owner.getSettings(_youtubeSetupSetting)?.value == 'true') return;
        final epoch = _profileEpoch;
        await owner.saveSettings([
          SettingsValue(CommunityRule.youtubeBlock.setting, block.name),
          SettingsValue(CommunityRule.youtubeWarn.setting, warning.name),
          SettingsValue(_youtubeSetupSetting, 'true'),
        ]);
        if (!_isCurrentProfile || epoch != _profileEpoch) return;
        _actions[CommunityRule.youtubeBlock] = block;
        _actions[CommunityRule.youtubeWarn] = warning;
        _actionsChanged(CommunityList.aislist);
      });

  void _actionsChanged(CommunityList list) {
    if (!enabled(list)) _cancelRefresh(list);
    _changes.value++;
    if (enabled(list)) unawaited(refreshIfStale());
  }

  Future<void> allow(CommunityMatch match) =>
      _changeException(match.source, match.identity, add: true);

  Future<void> removeException(CommunityList list, String identity) =>
      _changeException(list, identity, add: false);

  Future<void> _changeException(CommunityList list, String identity,
          {required bool add}) =>
      _write((owner) async {
        final epoch = _profileEpoch;
        final next = {...?_exceptions[list]};
        final changed = add ? next.add(identity) : next.remove(identity);
        if (!changed) return;
        final encoded = jsonEncode(next.toList()..sort());
        if (parseCommunityExceptions(encoded) == null) {
          throw const FormatException('Invalid community filter exceptions');
        }
        await owner.saveSetting(
            SettingsValue(communityExceptionsSetting(list), encoded));
        if (!_isCurrentProfile || epoch != _profileEpoch) return;
        _exceptions[list] = next;
        _changes.value++;
      });

  Future<void> _write(Future<void> Function(IDbClient) update) {
    if (!_isCurrentProfile) {
      return Future.error(StateError('The selected profile changed'));
    }
    final owner = _activeDatabase!.forProfile(_profile!);
    final epoch = _profileEpoch;
    final write = _pendingWrites.then((_) {
      if (!_isCurrentProfile || epoch != _profileEpoch) {
        throw StateError('The selected profile changed');
      }
      return update(owner);
    });
    _pendingWrites = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  List<CommunityMatch> match({
    String? authorId,
    String? authorUrl,
    bool music = false,
  }) {
    if ((!enabled(CommunityList.aislist) &&
            (!music || !enabled(CommunityList.aimusic))) ||
        !_isCurrentProfile) {
      return const [];
    }
    final id =
        normalizeChannelId(authorId) ?? channelIdFromAuthorUrl(authorUrl);
    final directHandle = channelHandleFromAuthorUrl(authorUrl);
    if (id != null && directHandle != null) _remember(id, directHandle);
    final handle = directHandle ?? _handlesById[id];
    final resolvedId = id ?? _idsByHandle[handle];
    final identity = resolvedId ?? (handle == null ? null : '@$handle');
    if (identity == null) return const [];
    final matches = <CommunityMatch>[];
    for (final list in CommunityList.values) {
      if (!enabled(list) || (list == CommunityList.aimusic && !music)) continue;
      final snapshot = _snapshots[list];
      if (snapshot == null) continue;
      final allowed = _exceptions[list];
      if (allowed != null &&
          (allowed.contains(identity) || allowed.contains('@$handle'))) {
        continue;
      }
      final block = snapshot.blockIds.contains(resolvedId) ||
          (list == CommunityList.aislist &&
              snapshot.blockHandles.contains(handle));
      final warn = !block &&
          list == CommunityList.aislist &&
          (snapshot.warnIds.contains(resolvedId) ||
              snapshot.warnHandles.contains(handle));
      if (!block && !warn) continue;
      final rule = list == CommunityList.aimusic
          ? CommunityRule.music
          : warn
              ? CommunityRule.youtubeWarn
              : CommunityRule.youtubeBlock;
      final mode = action(rule);
      if (mode != CommunityAction.off) {
        matches.add(CommunityMatch(
            source: list, action: mode, warning: warn, identity: identity));
      }
    }
    return matches;
  }

  void _remember(String id, String handle) {
    if (_handlesById[id] == handle) return;
    final previousHandle = _handlesById.remove(id);
    if (previousHandle != null) _idsByHandle.remove(previousHandle);
    final previousId = _idsByHandle.remove(handle);
    if (previousId != null) _handlesById.remove(previousId);
    if (_handlesById.length >= 4096) {
      final oldest = _handlesById.keys.first;
      _idsByHandle.remove(_handlesById.remove(oldest));
    }
    _handlesById[id] = handle;
    _idsByHandle[handle] = id;
  }

  void _cancelRefresh(CommunityList list) {
    _epochs[list] = (_epochs[list] ?? 0) + 1;
    _refreshes.remove(list);
    if (_failures.remove(list)) _checks.remove(list);
  }

  Future<void> refreshIfStale() => Future.wait([
        for (final list in CommunityList.values)
          if (enabled(list)) _startRefresh(list, force: false),
      ]);

  Future<void> refresh(CommunityList list) => _startRefresh(list, force: true);

  Future<void> _startRefresh(CommunityList list, {required bool force}) {
    if (!_isCurrentProfile || !enabled(list)) return Future.value();
    final running = _refreshes[list];
    if (running != null) return running;
    final lastCheck = _checks[list];
    final age = lastCheck == null ? null : _now().difference(lastCheck);
    if (!force &&
        age != null &&
        !age.isNegative &&
        age <
            (_failures.contains(list)
                ? const Duration(minutes: 30)
                : _refreshInterval)) {
      return Future.value();
    }
    final epoch = _epochs[list];
    final pending = Future.microtask(() => _update(list, epoch, force));
    _refreshes[list] = pending;
    _changes.value++;
    return pending;
  }

  Future<void> _update(CommunityList list, int? epoch, bool force) async {
    bool current() =>
        _isCurrentProfile && _epochs[list] == epoch && enabled(list);
    if (!current()) return;
    try {
      final cached = _snapshots[list] ?? await _repository.load(list);
      if (!current()) return;
      if (cached != null && !identical(cached, _snapshots[list])) {
        _snapshots[list] = cached;
        _changes.value++;
      }
      final checked = cached?.checkedAt;
      if (!force &&
          !_failures.contains(list) &&
          checked != null &&
          _now().difference(checked) < _refreshInterval &&
          !checked.isAfter(_now())) {
        _checks[list] = checked;
        return;
      }
      final fresh = await _repository.refresh(list, isCurrent: current);
      if (!current()) return;
      _snapshots[list] = fresh;
      _checks[list] = _now();
      _failures.remove(list);
    } catch (_) {
      if (current()) {
        _checks[list] = _now();
        _failures.add(list);
      }
    } finally {
      if (current()) {
        _refreshes.remove(list);
        _changes.value++;
      }
    }
  }
}
