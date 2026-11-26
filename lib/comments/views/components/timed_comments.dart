import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/timed_comment.dart';
import 'package:clipious/comments/states/comments.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/models/invidious_linkifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'comment.dart';
import 'comments.dart';

class TimedCommentsView extends StatelessWidget {
  const TimedCommentsView({super.key});

  @override
  Widget build(BuildContext context) {
    final server = InvidiousLinkifier.of(context).server;
    return BlocBuilder<CommentsCubit, CommentsState>(
      builder: (context, state) => _TimedComments(state: state, server: server),
    );
  }
}

class _TimedComments extends StatefulWidget {
  final CommentsState state;
  final Server? server;

  const _TimedComments({required this.state, this.server});

  @override
  State<_TimedComments> createState() => _TimedCommentsState();
}

class _TimedCommentsState extends State<_TimedComments> {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _rows = Map<Comment, GlobalKey>.identity();
  late List<TimedComment> _entries;
  bool _following = false;
  int? _lastAnchor;

  @override
  void initState() {
    super.initState();
    _indexComments();
  }

  @override
  void didUpdateWidget(_TimedComments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.comments != widget.state.comments ||
        oldWidget.server?.url != widget.server?.url) {
      _indexComments();
    }
  }

  void _indexComments() {
    final video = widget.state.video;
    _entries = TimedComment.index(
      widget.state.comments.comments,
      duration: Duration(seconds: video.lengthSeconds ?? 0),
      videoId: video.videoId,
      server: widget.server,
    );
    _lastAnchor = null;
    final comments = _entries.map((entry) => entry.comment).toSet();
    _rows.removeWhere((comment, _) => !comments.contains(comment));
  }

  bool _matchesPlayback(PlayerState state) =>
      state.currentlyPlaying?.videoId == widget.state.video.videoId &&
      state.currentlyPlaying?.liveNow != true &&
      state.currentlyPlaying?.isUpcoming != true &&
      !state.isAudio &&
      !state.isHidden &&
      !state.isClosing;

  void _setFollowing(bool value) {
    if (_following == value) return;
    setState(() {
      _following = value;
      _lastAnchor = null;
    });
  }

  void _showAnchor(int active) {
    if (_lastAnchor == active) return;
    _lastAnchor = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_following ||
          _lastAnchor != active ||
          !_scroll.hasClients ||
          !_matchesPlayback(context.read<PlayerCubit>().state)) {
        return;
      }
      if (active < 0) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      } else if (_rows[_entries[active].comment]
              ?.currentContext
              ?.findRenderObject()
          case final target?) {
        // Scroll this list without moving the Watch panel or player.
        _scroll.position.ensureVisible(target);
      }
    });
  }

  bool _pauseOnScroll(ScrollNotification notification) {
    if (notification.depth == 0 &&
        (notification is ScrollStartNotification &&
                notification.dragDetails != null ||
            notification is UserScrollNotification &&
                notification.direction != ScrollDirection.idle)) {
      _setFollowing(false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final video = widget.state.video;
    final (canSeek, active) = context.select((PlayerCubit player) {
      final canSeek =
          _matchesPlayback(player.state) && player.canSeekCurrentMedia;
      return (
        canSeek,
        canSeek && _following
            ? TimedComment.activeIndexAt(_entries, player.state.position)
            : -1,
      );
    });
    final state = widget.state;
    final loaded = state.continuation != null ||
        state.comments.comments.isNotEmpty ||
        (!state.loadingComments && state.error.isEmpty);

    if (canSeek && _following) _showAnchor(active);

    return BlocListener<PlayerCubit, PlayerState>(
      listenWhen: (previous, current) =>
          _matchesPlayback(previous) && !_matchesPlayback(current),
      listener: (_, __) => _setFollowing(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_entries.isNotEmpty)
            TextButton.icon(
              onPressed: canSeek ? () => _setFollowing(!_following) : null,
              icon: Icon(_following ? Icons.pause : Icons.sync),
              label: Text(_following
                  ? locals.pauseTimedCommentsFollow
                  : locals.followTimedComments),
            ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _pauseOnScroll,
              child: SingleChildScrollView(
                key: const ValueKey('timed-comments-list'),
                controller: _scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (loaded)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          state.continuation != null
                              ? locals.timedCommentsPartialCoverage
                              : locals.timedCommentsCoverage,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (loaded && _entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(locals.noTimedComments),
                      ),
                    for (final (index, entry) in _entries.indexed)
                      Material(
                        key: _rows.putIfAbsent(entry.comment, GlobalKey.new),
                        color: active == index
                            ? colors.secondaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: Semantics(
                          selected: active == index,
                          child: SingleCommentView(
                            video: video,
                            comment: entry.comment,
                            timestampButton: TextButton(
                              onPressed: !canSeek
                                  ? null
                                  : () {
                                      if (!mounted) return;
                                      final player =
                                          context.read<PlayerCubit>();
                                      if (_matchesPlayback(player.state)) {
                                        player.seek(entry.timestamp);
                                      }
                                    },
                              child:
                                  Text(prettyDurationCustom(entry.timestamp)),
                            ),
                            onOpenReplies: () => _setFollowing(false),
                          ),
                        ),
                      ),
                    CommentsPagination(state: state),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
