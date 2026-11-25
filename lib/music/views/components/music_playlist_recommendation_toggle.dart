import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../recommendations/music_playlist_recommendation_exclusions.dart';
import 'music_library_actions.dart';

class MusicPlaylistRecommendationToggle extends StatefulWidget {
  final PlaylistReference reference;

  const MusicPlaylistRecommendationToggle({super.key, required this.reference});

  @override
  State<MusicPlaylistRecommendationToggle> createState() =>
      _MusicPlaylistRecommendationToggleState();
}

class _MusicPlaylistRecommendationToggleState
    extends State<MusicPlaylistRecommendationToggle> {
  bool _saving = false;

  Future<void> _setExcluded(
      MusicPlaylistRecommendationExclusions exclusions, bool excluded) async {
    final reference = widget.reference;
    final session = MusicLibrarySession(context.read<AppCubit>());
    bool isCurrent() =>
        mounted &&
        widget.reference == reference &&
        session.isCurrent &&
        session.app.state.profileId == reference.profileId;

    if (_saving || !isCurrent()) return;
    setState(() => _saving = true);
    try {
      await exclusions.setExcluded(reference,
          excluded: excluded, isCurrent: isCurrent);
    } catch (_) {
      if (!mounted || !isCurrent()) return;
      final locals = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(locals.recommendationError)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reference = widget.reference;
    final app = context.watch<AppCubit>().state;
    if (app.profileId != reference.profileId || !reference.matchesOwner(db)) {
      return const SizedBox.shrink();
    }
    final exclusions = MusicPlaylistRecommendationExclusions.forDatabase(db);
    final owner = db.forProfile(reference.profileId);
    final key = musicPlaylistRecommendationKey(reference);
    final locals = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: exclusions,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('music-playlist-recommendation-toggle'),
        contentPadding: EdgeInsets.zero,
        value: isMusicPlaylistRecommendationExcluded(owner, key),
        onChanged: _saving || app.globalLoading || app.sessionRecoveryRequired
            ? null
            : (value) => _setExcluded(exclusions, value),
        title: Text(locals.musicExcludePlaylistFromRecommendations),
        subtitle: Text(locals.musicExcludePlaylistFromRecommendationsHint),
      ),
    );
  }
}
