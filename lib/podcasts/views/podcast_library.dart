import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';
import 'package:clipious/podcasts/services/podcast_library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Local subscriptions and cached episodes. Opening this page never refreshes
/// a feed; only Add and Refresh contact a publisher.
class PodcastLibraryPage extends StatefulWidget {
  final PodcastLibraryService? library;
  final PodcastDownloads? downloads;

  const PodcastLibraryPage({super.key, this.library, this.downloads});

  @override
  State<PodcastLibraryPage> createState() => _PodcastLibraryPageState();
}

class _PodcastLibraryPageState extends State<PodcastLibraryPage> {
  late final AppCubit _app = context.read<AppCubit>();
  late final AppState _session = _app.state;
  late final String _profileId = db.profileId;
  late final _library =
      widget.library ?? PodcastLibraryService.forProfile(db, _profileId);
  late final _downloads =
      widget.downloads ?? PodcastDownloads.forProfile(db, _profileId);
  late final _changes = Listenable.merge([_library.changes, _downloads]);
  final _refreshing = <String>{};
  String? _feedId;
  bool _downloaded = false;

  bool get _current =>
      mounted &&
      !_app.isClosed &&
      !_app.state.globalLoading &&
      !_app.state.sessionRecoveryRequired &&
      db.profileId == _profileId &&
      _app.state.profileId == _session.profileId &&
      _app.state.sessionRevision == _session.sessionRevision;

  void _message(String text) {
    if (_current) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _add() async {
    if (!_current) return;
    final added = await showDialog<PodcastFeed>(
        context: context,
        builder: (_) =>
            _AddPodcastDialog(library: _library, isCurrent: () => _current));
    if (_current && added != null) {
      setState(() {
        _feedId = added.id;
        _downloaded = false;
      });
    }
  }

  Future<void> _refresh(PodcastFeed feed) async {
    if (!_current || !_refreshing.add(feed.id)) return;
    final locals = AppLocalizations.of(context)!;
    setState(() {});
    try {
      await _library.refresh(feed.id, isCurrent: () => _current);
    } catch (_) {
      if (_current) {
        _message(locals.podcastRefreshFailed);
      }
    } finally {
      if (mounted) setState(() => _refreshing.remove(feed.id));
    }
  }

  Future<void> _unsubscribe(PodcastFeed feed) async {
    if (!_current) return;
    final locals = AppLocalizations.of(context)!;
    try {
      await _library.remove(feed.id);
      if (_current) setState(() => _feedId = null);
    } catch (_) {
      if (_current) _message(locals.podcastActionFailed);
    }
  }

  Future<void> _play(PodcastEpisode episode, String feedTitle,
      {bool requireOffline = false}) async {
    if (!_current) return;
    final locals = AppLocalizations.of(context)!;
    final player = context.read<PlayerCubit>();
    try {
      final path = await _downloads.localPath(episode.id);
      if (!_current) return;
      if (requireOffline && path == null) {
        _message(locals.podcastDownloadMissing);
        return;
      }
      await player.podcasts.playEpisode(
          episode: episode,
          feedTitle: feedTitle,
          profileId: _profileId,
          localPath: path);
    } catch (_) {
      if (_current) _message(locals.podcastPlaybackError);
    }
  }

  Future<void> _download(PodcastFeed feed, PodcastEpisode episode) async {
    if (!_current) return;
    final locals = AppLocalizations.of(context)!;
    try {
      await _downloads.download(feed, episode);
    } catch (_) {
      if (_current) {
        _message(_downloads.errors[episode.id] ?? locals.podcastDownloadFailed);
      }
    }
  }

  Future<void> _removeDownload(String id) async {
    if (!_current) return;
    final locals = AppLocalizations.of(context)!;
    try {
      final player = context.read<PlayerCubit>().podcasts;
      if (player.active && player.offline && player.episode?.id == id) {
        await player.stop();
      }
      if (!_current) return;
      await _downloads.remove(id);
    } catch (_) {
      if (_current) _message(locals.podcastActionFailed);
    }
  }

  Widget _episode(PodcastEpisode episode, String feedTitle,
      {PodcastFeed? feed, bool requireOffline = false}) {
    final locals = AppLocalizations.of(context)!;
    final saved =
        _downloads.entries.any((item) => item.episode.id == episode.id);
    final busy = _downloads.activeId == episode.id;
    final progress = _downloads.progress[episode.id];
    final details = <String>[
      if (requireOffline) feedTitle,
      if (episode.publishedAt != null)
        DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
            .format(episode.publishedAt!.toLocal()),
      if (episode.durationSeconds != null)
        locals.podcastMinutes(
            Duration(seconds: episode.durationSeconds!).inMinutes),
      if (saved) locals.onDevice,
    ];
    return Column(children: [
      ListTile(
        key: ValueKey('podcast-episode-${episode.id}'),
        leading: const Icon(Icons.play_circle_outline),
        title:
            Text(episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: details.isEmpty
            ? null
            : Text(details.join(' · '),
                maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: () => _play(episode, feedTitle, requireOffline: requireOffline),
        trailing: IconButton(
          tooltip: busy
              ? locals.podcastCancelDownload
              : saved
                  ? locals.podcastRemoveDownload
                  : locals.download,
          icon: Icon(busy
              ? Icons.cancel_outlined
              : saved
                  ? Icons.delete_outline
                  : Icons.download_outlined),
          onPressed: busy
              ? () => _downloads.cancel(episode.id)
              : saved
                  ? () => _removeDownload(episode.id)
                  : feed == null || _downloads.activeId != null
                      ? null
                      : () => _download(feed, episode),
        ),
      ),
      if (busy)
        LinearProgressIndicator(
            value: progress == null || progress.total <= 0
                ? null
                : (progress.received / progress.total).clamp(0.0, 1.0)),
      if (_downloads.errors.containsKey(episode.id))
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_downloads.errors[episode.id]!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ]);
  }

  Widget _empty(String message) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center)));

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
        listenable: _changes,
        builder: (context, _) {
          final feed =
              _library.feeds.where((item) => item.id == _feedId).firstOrNull;
          final downloads = _downloads.entries;
          return PopScope(
            canPop: feed == null || !TickerMode.of(context),
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && mounted) setState(() => _feedId = null);
            },
            child: Column(children: [
              if (feed != null)
                ListTile(
                  leading: IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: () => setState(() => _feedId = null),
                      icon: const Icon(Icons.arrow_back)),
                  title: Text(feed.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: feed.author.isEmpty
                      ? null
                      : Text(feed.author,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                      tooltip: locals.refresh,
                      onPressed: _refreshing.contains(feed.id)
                          ? null
                          : () => _refresh(feed),
                      icon: const Icon(Icons.refresh)),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                            onPressed: _add,
                            icon: const Icon(Icons.add),
                            label: Text(locals.podcastAdd)),
                        FilterChip(
                            label: Text(locals.podcastDownloadedEpisodes),
                            selected: _downloaded,
                            onSelected: (value) =>
                                setState(() => _downloaded = value)),
                      ]),
                ),
              if (feed != null && _refreshing.contains(feed.id))
                const LinearProgressIndicator(),
              Expanded(
                  child: feed != null
                      ? feed.episodes.isEmpty
                          ? _empty(locals.podcastNoEpisodes)
                          : ListView.builder(
                              itemCount: feed.episodes.length,
                              itemBuilder: (_, index) => _episode(
                                  feed.episodes[index], feed.title, feed: feed))
                      : _downloaded
                          ? downloads.isEmpty
                              ? _empty(locals.podcastNoDownloads)
                              : ListView.builder(
                                  itemCount: downloads.length,
                                  itemBuilder: (_, index) => _episode(
                                      downloads[index].episode,
                                      downloads[index].feedTitle,
                                      requireOffline: true))
                          : _library.feeds.isEmpty
                              ? _empty(locals.podcastEmpty)
                              : ListView.builder(
                                  itemCount: _library.feeds.length,
                                  itemBuilder: (_, index) {
                                    final item = _library.feeds[index];
                                    return ListTile(
                                      key: ValueKey('podcast-feed-${item.id}'),
                                      leading: const Icon(Icons.podcasts),
                                      title: Text(item.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: item.author.isEmpty
                                          ? null
                                          : Text(item.author,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                      onTap: () =>
                                          setState(() => _feedId = item.id),
                                      trailing: PopupMenuButton<String>(
                                          tooltip: locals.podcastActions,
                                          onSelected: (action) =>
                                              action == 'refresh'
                                                  ? _refresh(item)
                                                  : _unsubscribe(item),
                                          itemBuilder: (_) => [
                                                PopupMenuItem(
                                                    value: 'refresh',
                                                    child:
                                                        Text(locals.refresh)),
                                                PopupMenuItem(
                                                    value: 'remove',
                                                    child: Text(locals
                                                        .podcastUnsubscribe)),
                                              ]),
                                    );
                                  })),
            ]),
          );
        });
  }
}

class _AddPodcastDialog extends StatefulWidget {
  final PodcastLibraryService library;
  final bool Function() isCurrent;
  const _AddPodcastDialog({required this.library, required this.isCurrent});

  @override
  State<_AddPodcastDialog> createState() => _AddPodcastDialogState();
}

class _AddPodcastDialogState extends State<_AddPodcastDialog> {
  final _url = TextEditingController();
  bool _loading = false;
  bool _cancelled = false;
  String? _error;

  bool get _active =>
      mounted && !_cancelled && ModalRoute.of(context)?.isActive == true;

  bool get _current => _active && widget.isCurrent();

  void _close([PodcastFeed? feed]) {
    if (!_active) return;
    final route = ModalRoute.of<PodcastFeed>(context)!;
    final navigator = Navigator.of(context);
    _cancelled = true;
    if (route.isCurrent) {
      navigator.pop(feed);
    } else {
      navigator.removeRoute(route, feed);
    }
  }

  void _cancel() {
    _close();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading || !_current) return;
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await widget.library
          .subscribe(_url.text.trim(), isCurrent: () => _current);
      if (_current) _close(feed);
    } catch (_) {
      if (_active) {
        setState(() {
          _loading = false;
          _error = widget.isCurrent()
              ? locals.podcastAddFailed
              : locals.podcastProfileChanged;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopScope<PodcastFeed>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true;
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.podcastAdd),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.podcastPrivacy),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_loading,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              maxLength: 4096,
              decoration: InputDecoration(
                  labelText: locals.podcastFeedUrl,
                  hintText: 'https://example.com/feed.xml',
                  counterText: '',
                  errorText: _error,
                  errorMaxLines: 4),
              onSubmitted: (_) => _submit(),
            ),
            if (_loading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: _cancel, child: Text(locals.cancel)),
          FilledButton(
              onPressed: _loading ? null : _submit, child: Text(locals.add)),
        ],
      ),
    );
  }
}
