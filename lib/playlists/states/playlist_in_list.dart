import 'package:bloc/bloc.dart';

import '../../globals.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';

class PlaylistInListCubit extends Cubit<Playlist> {
  final PlaylistReference? reference;

  PlaylistInListCubit(super.initialState, {this.reference}) {
    getThumbnailsFromYoutube();
  }

  Future<void> getThumbnailsFromYoutube() async {
    // Saved cards already carry bounded artwork metadata and must stay visible
    // offline. Fetch their full, owner-bound contents only when they are opened.
    if (reference != null) return;
    if (state.videoCount > 0 && state.videos.isEmpty) {
      // something is not right, let's get the full playlist
      try {
        Playlist playlist = await service.getPublicPlaylists(state.playlistId);
        if (!isClosed) emit(playlist);
      } catch (_) {
        // Metadata failure must not remove the playlist or escape the widget.
      }
    }
  }
}
