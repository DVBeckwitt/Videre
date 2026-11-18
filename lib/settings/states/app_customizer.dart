import 'package:bloc/bloc.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/states/settings.dart';

class AppCustomizerCubit extends Cubit<List<HomeDataSource>> {
  final SettingsCubit settings;
  final String _profile;
  final int _session;

  AppCustomizerCubit(super.initialState, this.settings)
      : _profile = db.profileId,
        _session = settings.appCubit.state.sessionRevision;

  bool get _current =>
      !isClosed &&
      !settings.isClosed &&
      db.profileId == _profile &&
      settings.appCubit.state.sessionRevision == _session;

  Future<void> updateSource(HomeDataSource source, bool value) async {
    if (!_current) return;
    final onStart = this.state.elementAtOrNull(settings.state.onOpen);
    var state = List.of(this.state);

    if (!value) {
      state.remove(source);
    } else if (!state.contains(source)) {
      state.add(source);
    }
    // Keep the selected destination when earlier sections disappear. If the
    // startup section itself was removed, use the first remaining section.
    final startupIndex = onStart == null ? -1 : state.indexOf(onStart);
    await settings.setAppLayoutAndStartup(
        state, startupIndex < 0 ? 0 : startupIndex);
    if (_current) emit(state);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (!_current) return;
    var onStart = this.state.elementAtOrNull(settings.state.onOpen);

    var state = List.of(this.state);
    var source = state.removeAt(oldIndex);
    if (newIndex >= state.length) {
      state.add(source);
    } else {
      state.insert(newIndex, source);
    }

    final startupIndex = onStart == null ? -1 : state.indexOf(onStart);
    await settings.setAppLayoutAndStartup(
        state, startupIndex < 0 ? 0 : startupIndex);
    if (_current) emit(state);
  }
}
