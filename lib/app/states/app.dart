import 'dart:async';
import 'package:videre_proxy/videre_proxy.dart';
import 'package:clipious/recommendations/recommendation_service.dart';

import 'package:auto_route/auto_route.dart';
import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/router.dart';
import 'package:logging/logging.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/widgets.dart';

import '../../globals.dart';
import '../../home/models/db/home_layout.dart';
import '../../main.dart' show isTv;
import '../../network/content_link.dart';
import '../../network/network_proxy.dart';
import '../../playlists/models/playlist.dart';
import '../../playlists/models/playlist_reference.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/no_server_selected.dart';
import '../../utils/file_db.dart';
import '../../utils/interfaces/db.dart';
import '../services/android_incoming_links.dart';

part 'app.freezed.dart';

final log = Logger('HomeState');

class AppCubit extends Cubit<AppState> with WidgetsBindingObserver {
  late final StreamSubscription intentDataStreamSubscription;
  Future<void>? _pendingServerSwitch;
  final FileDB _backgroundDatabase;
  final VoidCallback? _onResume;
  _SessionSelection? _recoverySelection;
  ({
    List<({String text, bool share})> candidates,
    ContentLink? fallback,
    bool fullStack,
    String profileId
  })? _pendingExternalLink;
  int _sessionGeneration = 0;
  int _linkNavigationGeneration = 0;
  Future<void> Function()? beforeAccountSwitch;
  Future<void> Function()? afterAccountSwitch;
  Future<void> Function()? clearSessionNotifications;
  Future<void> Function(bool hasServer)? resetNavigation;

  AppCubit(super.initialState,
      {FileDB? backgroundDatabase, VoidCallback? onResume})
      : _backgroundDatabase = backgroundDatabase ?? fileDb,
        _onResume = onResume {
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
    _openPendingExternalLink();
  }

  onReady() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // A replacement Activity can attach to a retained engine. The live
      // router determines whether the Home stack needs to be installed.
      intentDataStreamSubscription = AndroidIncomingLinks.events().listen(
        (batch) => _receiveExternalLinks(
          [for (final media in batch) (text: media.text, share: media.share)],
          fullStack: false,
        ),
        onError: _logIntakeError,
      );
    } else {
      final sharing = ReceiveSharingIntent.instance;
      intentDataStreamSubscription = sharing.getMediaStream().listen(
          (shared) => _openSharedContent(shared, fullStack: false),
          onError: _logIntakeError);
      unawaited(_receiveInitialShare(sharing));
    }
    service.syncHistory();
  }

  void _logIntakeError(Object error, StackTrace trace) {
    log.warning(
        'Could not receive shared content (${error.runtimeType})', null, trace);
  }

  Future<void> _receiveInitialShare(ReceiveSharingIntent sharing) async {
    try {
      final shared = await sharing.getInitialMedia();
      _openSharedContent(shared, fullStack: true);
      await sharing.reset();
    } catch (error, trace) {
      _logIntakeError(error, trace);
    }
  }

  void _openSharedContent(List<SharedMediaFile> shared,
      {required bool fullStack}) {
    _receiveExternalLinks([
      for (final media in shared)
        if (media.type == SharedMediaType.url ||
            media.type == SharedMediaType.text)
          (text: media.path, share: media.type == SharedMediaType.text)
    ], fullStack: fullStack);
  }

  void _receiveExternalLinks(List<({String text, bool share})> candidates,
      {required bool fullStack}) {
    if (candidates.isEmpty ||
        isClosed ||
        state.globalLoading ||
        state.sessionRecoveryRequired) {
      return;
    }
    final profileId = db.profileId;
    final previous = _pendingExternalLink;
    final selected = state.profileId == profileId ? state.server : null;
    final recognized = _parseExternalCandidates(candidates, server: selected);
    if (recognized == null && selected != null) return;
    _pendingExternalLink = (
      // The selected instance may not be restored yet, so preserve a bounded
      // newest-first set for its existing parser instead of dropping an older
      // instance address when a newer, unrelated share arrives during startup.
      candidates: [
        ...candidates,
        if (previous?.profileId == profileId) ...previous!.candidates,
      ].take(16).toList(),
      // Preserve the latest already-recognized open when unrelated text arrives
      // during startup. Only one fallback is retained, within the same profile.
      fallback: _preferActionableLink(recognized,
          previous?.profileId == profileId ? previous?.fallback : null),
      fullStack: fullStack ||
          (previous != null &&
              previous.profileId == profileId &&
              previous.fullStack),
      profileId: profileId,
    );
    _openPendingExternalLink();
  }

  ContentLink? _parseExternalCandidates(
      List<({String text, bool share})> candidates,
      {Server? server}) {
    ContentLink? landing;
    for (final candidate in candidates) {
      final link = candidate.share
          ? ContentLink.firstInText(candidate.text,
              server: server, allowLandingFallback: true)
          : ContentLink.parseAddress(candidate.text,
              server: server, allowLandingFallback: true);
      if (link?.kind == ContentLinkKind.home) {
        landing ??= link;
      } else if (link != null) {
        return link;
      }
    }
    return landing;
  }

  ContentLink? _preferActionableLink(
      ContentLink? parsed, ContentLink? fallback) {
    if (parsed == null) return fallback;
    if (parsed.kind == ContentLinkKind.home &&
        fallback != null &&
        fallback.kind != ContentLinkKind.home) {
      return fallback;
    }
    return parsed;
  }

  void _openPendingExternalLink() {
    final pending = _pendingExternalLink;
    if (pending == null ||
        isClosed ||
        state.globalLoading ||
        state.sessionRecoveryRequired ||
        state.server == null ||
        state.profileId != db.profileId) {
      return;
    }
    _pendingExternalLink = null;
    if (pending.profileId != state.profileId) return;
    // Cold shares may name the selected Invidious instance before it has been
    // restored. Parse only after session admission, without adopting its host.
    final link = _preferActionableLink(
        _parseExternalCandidates(pending.candidates, server: state.server),
        pending.fallback);
    if (link == null) return;
    // An intent can arrive before the phone's nested AutoRouter mounts.
    // Install Home with the content in that case so Back has a destination.
    final fullStack = pending.fullStack ||
        !appRouter.hasEntries ||
        (isTv
            ? appRouter.current.name == TvWelcomeWizardRoute.name
            : appRouter.innerRouterOf<StackRouter>(MainRoute.name) == null);
    unawaited(_openContentLink(link, fullStack));
  }

  @override
  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    _pendingExternalLink = null;
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
      _onResume?.call();
    }
  }

  Future<void> openAppLink(String url, bool fullStack) async {
    final link = ContentLink.parseAddress(url,
        server: state.server, allowLandingFallback: true);
    if (link != null) await _openContentLink(link, fullStack);
  }

  /// Recognize an address pasted into a search field as local navigation.
  bool tryOpenPastedAppLink(String text) {
    final link = ContentLink.parseAddress(text, server: state.server);
    if (link == null) return false;
    unawaited(_openContentLink(link, false));
    return true;
  }

  Future<void> _openContentLink(ContentLink link, bool fullStack) async {
    if (isClosed || state.globalLoading || state.sessionRecoveryRequired) {
      return;
    }
    final navigation = ++_linkNavigationGeneration;
    final owner = db;
    final profileId = owner.profileId;
    final session = state.sessionRevision;
    final selected = state.server;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        !isClosed &&
        !state.globalLoading &&
        !state.sessionRecoveryRequired &&
        navigation == _linkNavigationGeneration &&
        identical(db, owner) &&
        db.profileId == profileId &&
        state.sessionRevision == session &&
        identical(state.server, selected) &&
        !NetworkProxy.instance.isChanging &&
        identical(NetworkProxy.instance.config, proxy);
    try {
      if (link.kind == ContentLinkKind.unresolved) {
        try {
          final server = selected ?? await owner.getCurrentlySelectedServer();
          if (!current()) return;
          link = await service.resolveContentLink(link,
                  server: server, isCurrent: current) ??
              link.landing;
        } on NoServerSelected {
          link = link.landing;
        }
        if (!current()) return;
      }
      final route = _appLinkRoute(link);
      log.fine('Opening ${route.routeName}, full stack: $fullStack');
      if (link.kind == ContentLinkKind.home && !link.music) {
        if (fullStack) {
          await appRouter.replaceAll([route]);
        } else {
          await appRouter.navigate(route);
        }
      } else if (isTv && fullStack) {
        await appRouter.replaceAll([const TvHomeRoute(), route]);
      } else if (fullStack) {
        await appRouter.replaceAll([
          MainRoute(children: [const MainContentRoute(), route])
        ]);
      } else {
        await appRouter.push(route);
      }
    } catch (err, stacktrace) {
      log.severe('Couldn\'t open external video link (${err.runtimeType})',
          null, stacktrace);
    }
  }

  bool canOpenAppLink(Uri uri) =>
      ContentLink.parse(uri, server: state.server) != null;

  PageRouteInfo _appLinkRoute(ContentLink link) {
    if (link.music) {
      return switch (link.kind) {
        ContentLinkKind.video =>
          MusicRoute(videoId: link.id, startAt: link.startAt ?? Duration.zero),
        ContentLinkKind.channel => MusicRoute(artistId: link.id),
        ContentLinkKind.playlist => MusicRoute(playlistId: link.id),
        ContentLinkKind.search => MusicRoute(initialQuery: link.id),
        ContentLinkKind.home || ContentLinkKind.unresolved => MusicRoute(),
      };
    }
    if (link.kind == ContentLinkKind.home ||
        link.kind == ContentLinkKind.unresolved) {
      return isTv
          ? const TvHomeRoute()
          : MainRoute(children: [const MainContentRoute()]);
    }
    if (link.kind == ContentLinkKind.search) {
      if (isTv) return TvSearchRoute(query: link.id, searchNow: true);
      return SearchRoute(query: link.id, searchNow: true);
    }
    if (link.kind == ContentLinkKind.playlist) {
      final playlist =
          Playlist(title: '', playlistId: link.id, author: '', videoCount: 0);
      final reference = PlaylistReference.forPlaylist(playlist, db);
      if (isTv) {
        return TvPlaylistRoute(
            playlist: playlist, canDeleteVideos: false, reference: reference);
      }
      return PlaylistViewRoute(
          playlist: playlist, canDeleteVideos: false, reference: reference);
    }

    if (link.kind == ContentLinkKind.channel) {
      if (isTv) return TvChannelRoute(channelId: link.id);
      return ChannelRoute(channelId: link.id);
    }
    if (isTv) return TvVideoRoute(videoId: link.id, startAt: link.startAt);
    return VideoRoute(videoId: link.id, startAt: link.startAt);
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

  /// Remove one person's local data after leaving its runtime and revoking its
  /// saved sign-ins. Sharing the switch queue prevents a concurrent selection
  /// from reopening the person between the final checks and deletion.
  Future<void> deleteProfile(String profileId) async {
    if (isClosed) return;
    final previous = _pendingServerSwitch;
    final done = Completer<void>();
    _pendingServerSwitch = done.future;
    try {
      if (previous != null) await previous;
      _requireOpen();
      if (state.sessionRecoveryRequired) {
        throw StateError(
            'Recover the current session before deleting a profile');
      }
      final profiles = await db.getProfiles();
      _requireOpen();
      if (!profiles.any((profile) => profile.id == profileId)) {
        throw StateError('Profile no longer exists');
      }
      if (profiles.length < 2) {
        throw StateError('At least one profile is required');
      }
      final owner = db.forProfile(profileId);
      final accounts = await owner.getServers();
      _requireOpen();
      if (db.profileId == profileId) {
        final replacement =
            profiles.firstWhere((profile) => profile.id != profileId);
        await _switchAccount(
            profileId: replacement.id, withinSessionOperation: true);
        _requireOpen();
      }
      if (db.profileId == profileId) {
        throw StateError('Leave this profile before deleting it');
      }
      setGlobalLoading(true);
      for (final account in accounts) {
        await service.logOutProtected(account);
        _requireOpen();
      }
      // Retire background readers before removing the registry. If cleanup
      // fails, the profile remains listed so deletion can be retried safely.
      await _backgroundDatabase.deleteProfile(profileId);
      _requireOpen();
      await PlaybackCache.removeProfile(profileId);
      _requireOpen();
      RecommendationService.forgetProfile(db, profileId);
      await db.deleteProfile(profileId);
    } finally {
      if (!isClosed) setGlobalLoading(false);
      if (identical(_pendingServerSwitch, done.future)) {
        _pendingServerSwitch = null;
      }
      done.complete();
    }
  }

  Future<Server?> _switchAccount(
      {required String profileId,
      Server? server,
      bool withinSessionOperation = false}) async {
    if (isClosed) return null;
    final previous = withinSessionOperation ? null : _pendingServerSwitch;
    final done = Completer<void>();
    if (!withinSessionOperation) _pendingServerSwitch = done.future;
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
      if (profileId != oldOwner.profileId || state.server != null) {
        _pendingExternalLink = null;
      }
      _sessionGeneration++;
      setGlobalLoading(true);
      try {
        await before?.call();
        _requireOpen();
        await RecommendationService.flushPending();
        RecommendationService.invalidateSession();
        await PlaybackCache.invalidate();
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
      if (!withinSessionOperation && !isClosed) setGlobalLoading(false);
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
    _openPendingExternalLink();
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
    if (!loading) _openPendingExternalLink();
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
