import 'package:clipious/music/models/music_fast_scroll_sections.dart';
import 'package:flutter_test/flutter_test.dart';

String _rangeLabel(int first, int last) => '$first-$last';

void main() {
  test('short lists have no jump targets', () {
    expect(
      musicFastScrollSections(
        List.filled(29, 'a'),
        rangeLabel: _rangeLabel,
        sectionLabel: musicFastScrollInitial,
        unknownLabel: 'Unknown',
      ),
      isEmpty,
    );
  });

  test('categories follow the displayed order and start at their first row',
      () {
    final rows = <String?>[
      ...List.filled(12, 'zeta'),
      ...List.filled(10, 'beta'),
      ...List.filled(9, 'apple'),
      ...List.filled(3, null),
    ];
    expect(
      musicFastScrollSections(
        rows,
        rangeLabel: _rangeLabel,
        sectionLabel: musicFastScrollInitial,
        unknownLabel: 'Unknown',
      ),
      [
        (index: 0, label: 'Z'),
        (index: 12, label: 'B'),
        (index: 22, label: 'A'),
        (index: 31, label: 'Unknown'),
      ],
    );
  });

  test('one category and disjoint categories fall back to position ranges', () {
    final single = List.filled(30, 'apple');
    final disjoint = [...List.filled(5, 'apple'), 'beta', ...single.skip(6)];
    final expected = musicFastScrollSections(
      single,
      rangeLabel: _rangeLabel,
      unknownLabel: 'Unknown',
    );
    for (final rows in [single, disjoint]) {
      expect(
        musicFastScrollSections(
          rows,
          rangeLabel: _rangeLabel,
          sectionLabel: musicFastScrollInitial,
          unknownLabel: 'Unknown',
        ),
        expected,
      );
    }
    expect(expected.first, (index: 0, label: '1-5'));
    expect(expected.last, (index: 25, label: '26-30'));
  });

  test('position ranges cover every row once and are bounded on long lists',
      () {
    final numbered = <int>[];
    final rows = List.generate(1003, (index) => index + 1);
    final sections = musicFastScrollSections(
      rows,
      rangeLabel: (first, last) {
        numbered.addAll(List.generate(last - first + 1, (i) => first + i));
        return _rangeLabel(first, last);
      },
      unknownLabel: 'Unknown',
    );
    expect(sections.length, lessThanOrEqualTo(20));
    expect(sections.first.index, 0);
    expect(sections.last.label, endsWith('-1003'));
    expect(numbered, rows);
  });

  test('initials retain whole Unicode graphemes', () {
    expect(musicFastScrollInitial(null), isNull);
    expect(musicFastScrollInitial(''), isNull);
    expect(musicFastScrollInitial('2 songs'), '0–9');
    expect(musicFastScrollInitial('10 songs'), '0–9');
    expect(musicFastScrollInitial(' '), isNull);
    expect(musicFastScrollInitial('écho'), 'É');
    expect(musicFastScrollInitial('e\u0301cho'), 'E\u0301');
    expect(musicFastScrollInitial('👩‍🎤 Music'), '👩‍🎤');
  });
}
