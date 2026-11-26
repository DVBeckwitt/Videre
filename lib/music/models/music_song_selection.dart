/// Selection by displayed occurrence, independent of recording identity.
///
/// The screen supplies the current row order and resets selection when the
/// source identity changes.
class MusicSongSelection<K> {
  final _selected = <K>{};
  bool _active = false;

  bool get active => _active;
  bool contains(K id) => _selected.contains(id);

  void begin() => _active = true;

  void start(K id) {
    begin();
    _selected.add(id);
  }

  void toggle(K id) {
    begin();
    if (!_selected.remove(id)) _selected.add(id);
  }

  void clear() {
    _selected.clear();
    _active = false;
  }

  void retain(Iterable<K> ids) => _selected.retainAll(ids);

  bool allSelected(Iterable<K> ids) =>
      ids.isNotEmpty && ids.every(_selected.contains);

  void toggleAll(Iterable<K> ids) {
    final matching = ids.toSet();
    if (matching.isEmpty) return;
    final select = !allSelected(matching);
    _selected.clear();
    if (select) _selected.addAll(matching);
  }

  List<T> selectedRows<T>(Iterable<T> rows, K Function(T) id) =>
      rows.where((row) => contains(id(row))).toList();
}
