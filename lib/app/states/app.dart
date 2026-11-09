import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/router.dart';
import 'package:logging/logging.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/widgets.dart';

import '../../globals.dart';
import '../../home/models/db/home_layout.dart';
import '../../main.dart' show isTv;
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/no_server_selected.dart';
import '../../utils/file_db.dart';
import '../../utils/interfaces/db.dart';

part 'app.freezed.dart';

final log = Logger('HomeState');

class AppCubit extends Cubit<AppState> with WidgetsBindingObserver {
  late final StreamSubscription intentDataStreamSubscription;
  Future<void>? _pendingServerSwitch;
  final FileDB _backgroundDatabase;
  _SessionSelection? _recoverySelection;
  int _sessionGeneration = 0;
  Future<void> Function()? beforeAccountSwitch;
  Future<void> Function()? afterAccountSwitch;
  Future<void> Function()? clearSessionNotifications;
  Future<void> Function(bool hasServer)? resetNavigation;

  AppCubit(super.initialState, {FileDB? backgroundDatabase})
      : _backgroundDatabase = backgroundDatabase ?? fileDb {
    WidgetsBinding.instance.addObserver(this);
    onReady();
    initState();
  }

  initState() async {
    final owner = db.forProfile(db.profileId);
    final generation = _sessionGeneration;
    Server? server;
    try {
      server = await owner.getCurrentlySelectedServer();
    } catch (e) {
      server = null;
    }
    if (isClosed ||
        state.globalLoading ||
        state.sessionRecoveryRequired ||
        generation != _sessionGeneration ||
        owner.profileId != db.profileId) {
      return;
    }
    HomeLayout homeLayout = owner.getHomeLayout();
    var firstIndex =
        int.parse(owner.getSettings(onOpenSettingName)?.value ?? '0');
    if (firstIndex < 0) {
      firstIndex = 0;
    }
    emit(state.copyWith(
        firstIndex: firstIndex,
        homeLayout: homeLayout,
        server: server,
        profileId: owner.profileId));
  }

  onReady() async {
    intentDataStreamSubscription =
        ReceiveSharingIntent.instance.getMediaStream().listen((shared) {
      final String? value = shared
          .where((element) => element.type == SharedMediaType.url)
          .map((e) => e.path)
          .firstOrNull;
      if (value != null) {
        unawaited(openAppLink(value, false));
      }
    }, onError: (err) {
      log.warning("getLinkStream error: $err");
    });

    // For sharing or opening urls/text coming from outside the app while the app is closed
    ReceiveSharingIntent.instance.getInitialMedia().then((shared) {
      final String? value = shared
          .where((element) => element.type == SharedMediaType.url)
          .map((e) => e.path)
          .firstOrNull;
      if (value != null) {
        unawaited(openAppLink(value, true));
      }
      ReceiveSharingIntent.instance.reset();
    });

    service.syncHistory();
  }

  @override
  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    final closed = super.close();
    await intentDataStreamSubscription.cancel();
    // Active work observes isClosed and restores its original selection;
    // queued work exits before mutating any database or invoking UI hooks.
    final switching = _pendingServerSwitch;
    if (switching != null) await switching;
    await closed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !isClosed &&
        !this.state.globalLoading &&
        !this.state.sessionRecoveryRequired) {
      service.syncHistory();
    }
  }

  Future<void> openAppLink(String url, bool fullStack) async {
    if (isClosed || state.globalLoading || state.sessionRecoveryRequired) {
      return;
    }
    try {
      Uri uri = Uri.parse(url);
      String? videoId;
      if (const {'http', 'https'}.contains(uri.scheme) &&
          youtubeHosts.contains(uri.host)) {
        if (uri.host == youtubeMusicHost) {
          final route = _musicLinkRoute(uri);
          if (route == null) return;
          if (isTv && fullStack) {
            await appRouter.replaceAll([const TvHomeRoute(), route]);
          } else if (fullStack) {
            await appRouter.replaceAll([
              MainRoute(children: [const MainContentRoute(), route])
            ]);
          } else {
            await appRouter.push(route);
          }
          return;
        }
        if (uri.pathSegments.length == 1 &&
            uri.pathSegments.contains("watch") &&
            uri.queryParameters.containsKey('v')) {
          videoId = uri.queryParameters['v']!;
        }
        if (uri.host == 'youtu.be' && uri.pathSegments.length == 1) {
          videoId = uri.pathSegments[0];
        }

        if (videoId != null &&
            videoId.length == 11 &&
            RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
          log.fine('Opening video $videoId, full stack: $fullStack');
          if (isTv) {
            if (fullStack) {
              await appRouter.replaceAll([
                const TvHomeRoute(),
                TvVideoRoute(videoId: videoId),
              ]);
            } else {
              await appRouter.push(TvVideoRoute(videoId: videoId));
            }
          } else if (fullStack) {
            await appRouter.replaceAll([
              MainRoute(children: [
                const MainContentRoute(),
                VideoRoute(videoId: videoId)
              ])
            ]);
          } else {
            await appRouter.push(VideoRoute(videoId: videoId));
          }
        }
      }
    } catch (err, stacktrace) {
      // not a url;
      log.severe('Couldn\'t open external video link (${err.runtimeType})',
          null, stacktrace);
    }
  }

  MusicRoute? _musicLinkRoute(Uri uri) {
    if (uri.pathSegments.length == 1 && uri.pathSegments.single == 'watch') {
      final videoId = uri.queryParameters['v'];
      if (videoId != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
        return MusicRoute(videoId: videoId);
      }
    } else if (uri.pathSegments.length == 2 &&
        (uri.pathSegments.first == 'browse' ||
            uri.pathSegments.first == 'channel')) {
      final id = uri.pathSegments.last;
      if (RegExp(r'^UC[A-Za-z0-9_-]{22}$').hasMatch(id)) {
        return MusicRoute(artistId: id);
      }
      if (uri.pathSegments.first == 'browse' &&
          id.length <= 200 &&
          RegExp(r'^MPRE[A-Za-z0-9_-]+$').hasMatch(id)) {
        return MusicRoute(albumId: id);
      }
    } else if (uri.pathSegments.length == 1 &&
        uri.pathSegments.single == 'playlist') {
      final playlistId = uri.queryParameters['list'];
      if (playlistId != null &&
          playlistId.length <= 200 &&
          RegExp(r'^(?:VL)?(?:PL|OLAK5uy_|RD)[A-Za-z0-9_-]+$')
              .hasMatch(playlistId)) {
        return MusicRoute(playlistId: playlistId);
      }
    }
    return null;
  }

  rebuildApp() {
    emit(state.copyWith());
  }

  Future<Server?> switchServer(Server server) async {
    return _switchAccount(profileId: server.profileId, server: server);
  }

  Future<void> switchProfile(String profileId) async {
    await _switchAccount(profileId: profileId);
  }

  Future<Server?> _switchAccount(
      {required String profileId, Server? server}) async {
    if (isClosed) return null;
    final previous = _pendingServerSwitch;
    final done = Completer<void>();
    _pendingServerSwitch = done.future;
    try {
      // Settings can be reopened while the previous session check is pending.
      if (previous != null) await previous;
      if (isClosed) return null;
      if (state.sessionRecoveryRequired) {
        throw StateError(
            'Recover the previous session before switching accounts');
      }
      // Capture the owner before asynchronous work. Restore by identity, not
      // this credential snapshot: login refreshes can finish during a switch.
      final oldOwner = db.forProfile(db.profileId);
      final owner = db.forProfile(profileId);
      final saved = server == null ? null : owner.getAccount(server.accountId);
      if (server != null && saved == null) return null;
      final oldServer = await _selectedServer(oldOwner);
      if (isClosed) return null;
      final oldSelection =
          _SessionSelection(oldOwner.profileId, oldServer?.accountId);
      final before = beforeAccountSwitch;
      final after = afterAccountSwitch;
      final navigate = resetNavigation;
      var reloadStarted = false;
      _sessionGeneration++;
      setGlobalLoading(true);
      try {
        await before?.call();
        _requireOpen();
        await db.useProfile(profileId);
        _requireOpen();
        if (saved != null) {
          final latest = owner.getAccount(saved.accountId);
          if (latest == null) throw StateError('Account no longer exists');
          await owner.useServer(latest);
          _requireOpen();
        }
        service.clearSessionCaches();
        var selected = await _selectedServer(owner);
        _requireOpen();
        if (selected != null) {
          await service.validateCurrentSessionSafely();
          _requireOpen();
          selected = await _selectedServer(owner);
          _requireOpen();
        }
        await _mirrorSession(profileId, selected);
        _requireOpen();
        reloadStarted = true;
        await after?.call();
        _requireOpen();
        selected = await _mirrorCurrentSession(owner);
        _requireOpen();
        _publishSession(owner, selected);
        await navigate?.call(selected != null);
        _requireOpen();
        selected = await _mirrorCurrentSession(owner);
        _requireOpen();
        if (selected != state.server) _publishSession(owner, selected);
        _recoverySelection = null;
        service.syncHistory();
        return selected;
      } catch (error, stackTrace) {
        _recoverySelection = oldSelection;
        try {
          await _restoreSession(oldSelection,
              before: before,
              after: after,
              navigate: navigate,
              stopRuntime: reloadStarted);
          _recoverySelection = null;
        } catch (recoveryError, recoveryStack) {
          // The old screen must never become interactive against a different
          // selected library when persistence, reload or navigation recovery fails.
          log.severe('Session recovery failed (${recoveryError.runtimeType})',
              null, recoveryStack);
          if (!isClosed) {
            emit(state.copyWith(
                sessionRecoveryRequired: true, globalLoading: false));
          }
          throw const SessionRecoveryRequired();
        }
        if (error is _SessionSwitchCancelled) return null;
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      if (!isClosed) setGlobalLoading(false);
      if (identical(_pendingServerSwitch, done.future)) {
        _pendingServerSwitch = null;
      }
      done.complete();
    }
  }

  Future<Server?> _selectedServer(IDbClient owner) async {
    try {
      return await owner.getCurrentlySelectedServer();
    } on NoServerSelected {
      return null;
    }
  }

  void _requireOpen() {
    if (isClosed) throw const _SessionSwitchCancelled();
  }

  Future<void> _mirrorSession(String profileId, Server? selected) async {
    try {
      await _backgroundDatabase.useProfile(profileId);
      if (selected != null) await _backgroundDatabase.useServer(selected);
      // Reconcile an empty/deleted account as well as locale and the active
      // person, instead of retaining a previously mirrored credential snapshot.
      await _backgroundDatabase.syncWithDb();
    } finally {
      // A worker can finish against the previous mirror after the early
      // dismissal. Retire those notifications after publication, including a
      // partially failed publication or rollback, before the UI is unblocked.
      await clearSessionNotifications?.call();
    }
  }

  Future<Server?> _mirrorCurrentSession(IDbClient owner) async {
    var selected = await _selectedServer(owner);
    // Login/logout may finish during an awaited reload or disk write. Only
    // publish a snapshot after the account and background mirror agree.
    for (var attempt = 0; attempt < 3; attempt++) {
      await _mirrorSession(owner.profileId, selected);
      final latest = await _selectedServer(owner);
      if (latest == selected) return latest;
      selected = latest;
    }
    throw StateError('Account credentials changed repeatedly during switching');
  }

  void _publishSession(IDbClient owner, Server? selected) {
    if (isClosed) return;
    emit(state.copyWith(
        server: selected,
        firstIndex: 0,
        profileId: owner.profileId,
        homeLayout: owner.getHomeLayout(),
        sessionRevision: state.sessionRevision + 1,
        sessionRecoveryRequired: false));
  }

  Future<void> _restoreSession(_SessionSelection selection,
      {Future<void> Function()? before,
      Future<void> Function()? after,
      Future<void> Function(bool)? navigate,
      bool stopRuntime = false}) async {
    if (stopRuntime && !isClosed) await before?.call();
    await db.useProfile(selection.profileId);
    final owner = db.forProfile(selection.profileId);
    final latest = selection.accountId == null
        ? null
        : owner.getAccount(selection.accountId!);
    // Never resurrect a deleted account or overwrite refreshed credentials with
    // the snapshot that was captured before the failed transition.
    if (latest != null) await owner.useServer(latest);
    var selected = await _selectedServer(owner);
    service.clearSessionCaches();
    await _mirrorSession(selection.profileId, selected);
    if (isClosed) return;
    await after?.call();
    if (isClosed) return;
    selected = await _mirrorCurrentSession(owner);
    if (isClosed) return;
    _publishSession(owner, selected);
    await navigate?.call(selected != null);
    if (isClosed) return;
    selected = await _mirrorCurrentSession(owner);
    if (isClosed) return;
    if (selected != state.server) _publishSession(owner, selected);
  }

  Future<void> retrySessionRecovery() async {
    if (isClosed) return;
    final previous = _pendingServerSwitch;
    final done = Completer<void>();
    _pendingServerSwitch = done.future;
    try {
      if (previous != null) await previous;
      if (isClosed || !state.sessionRecoveryRequired) return;
      final selection = _recoverySelection;
      if (selection == null) throw const SessionRecoveryRequired();
      setGlobalLoading(true);
      try {
        await _restoreSession(selection,
            before: beforeAccountSwitch,
            after: afterAccountSwitch,
            navigate: resetNavigation,
            stopRuntime: true);
        _recoverySelection = null;
      } catch (error, stackTrace) {
        log.severe('Session recovery retry failed (${error.runtimeType})', null,
            stackTrace);
        if (!isClosed) emit(state.copyWith(sessionRecoveryRequired: true));
        throw const SessionRecoveryRequired();
      }
    } finally {
      if (!isClosed) setGlobalLoading(false);
      if (identical(_pendingServerSwitch, done.future)) {
        _pendingServerSwitch = null;
      }
      done.complete();
    }
  }

  setServer(Server s) {
    if (isClosed ||
        state.globalLoading ||
        state.sessionRecoveryRequired ||
        s.profileId != db.profileId) {
      return;
    }
    emit(state.copyWith(server: s, firstIndex: 0, profileId: s.profileId));
  }

  updateLayout() {
    emit(state.copyWith(homeLayout: db.getHomeLayout()));
  }

  bool get isLoggedIn =>
      (state.server?.authToken?.isNotEmpty ?? false) ||
      (state.server?.sidCookie?.isNotEmpty ?? false);

  // Set the whole app in a loading state.
  setGlobalLoading(bool loading) {
    emit(state.copyWith(globalLoading: loading));
  }
}

@freezed
sealed class AppState with _$AppState {
  const factory AppState(int firstIndex, Server? server, HomeLayout homeLayout,
      {@Default(false) bool globalLoading,
      @Default('default') String profileId,
      @Default(0) int sessionRevision,
      @Default(false) bool sessionRecoveryRequired}) = _AppState;
}

class _SessionSelection {
  final String profileId;
  final String? accountId;
  const _SessionSelection(this.profileId, this.accountId);
}

class _SessionSwitchCancelled implements Exception {
  const _SessionSwitchCancelled();
}

class SessionRecoveryRequired implements Exception {
  const SessionRecoveryRequired();

  @override
  String toString() =>
      'The account switch could not be recovered. Retry or restart Videre.';
}
