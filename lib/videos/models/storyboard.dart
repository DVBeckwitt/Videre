/// Invidious's storyboard interval is in milliseconds; dimensions describe a
/// single frame, while storyboardWidth/Height count columns and rows.
class Storyboard {
  final String templateUrl;
  final int width, height, count, interval, columns, rows, sheets;

  const Storyboard({
    required this.templateUrl,
    required this.width,
    required this.height,
    required this.count,
    required this.interval,
    required this.columns,
    required this.rows,
    required this.sheets,
  });

  factory Storyboard.fromJson(Map<String, dynamic> json) {
    final board = Storyboard(
      templateUrl: json['templateUrl'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      count: json['count'] as int,
      interval: json['interval'] as int,
      columns: json['storyboardWidth'] as int,
      rows: json['storyboardHeight'] as int,
      sheets: json['storyboardCount'] as int,
    );
    final uri = Uri.tryParse(board.templateUrl);
    if (uri == null ||
        board.templateUrl.isEmpty ||
        (uri.hasScheme && uri.scheme != 'https' && uri.scheme != 'http') ||
        board.width <= 0 ||
        board.height <= 0 ||
        board.columns <= 0 ||
        board.rows <= 0 ||
        board.count <= 0 ||
        board.sheets <= 0 ||
        board.interval < 0 ||
        board.columns > 8192 ~/ board.width ||
        board.rows > 8192 ~/ board.height ||
        board.width * board.height * board.columns * board.rows > 16777216) {
      throw const FormatException('Invalid storyboard');
    }
    return board;
  }

  static List<Storyboard> parseList(Object? value) {
    if (value is! List) return const [];
    final result = <Storyboard>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      try {
        result.add(Storyboard.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {
        // Optional preview metadata must never prevent video playback.
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'templateUrl': templateUrl,
        'width': width,
        'height': height,
        'count': count,
        'interval': interval,
        'storyboardWidth': columns,
        'storyboardHeight': rows,
        'storyboardCount': sheets,
      };

  static Storyboard? select(List<Storyboard> boards, double targetWidth) {
    final sorted = List<Storyboard>.of(boards)
      ..sort((a, b) => a.width.compareTo(b.width));
    return sorted.where((board) => board.width >= targetWidth).firstOrNull ??
        sorted.lastOrNull;
  }

  StoryboardFrame? frameAt(Duration position, Duration duration) {
    // Older instances can leave the evenly spaced overview interval at zero.
    final step = interval > 0 ? interval : duration.inMilliseconds ~/ count;
    if (step <= 0) return null;
    final perSheet = columns * rows;
    // Cap before multiplying: malformed counts must not overflow the limit.
    final frames = sheets > count ~/ perSheet ? count : perSheet * sheets;
    final index = (position.inMilliseconds ~/ step).clamp(0, frames - 1);
    final sheet = index ~/ perSheet;
    final url = templateUrl.replaceAll(
        RegExp(r'\$M|%24M', caseSensitive: false), '$sheet');
    if (sheet > 0 && url == templateUrl) return null;
    return StoryboardFrame(
        this, url, index % columns, (index % perSheet) ~/ columns);
  }
}

class StoryboardFrame {
  final Storyboard storyboard;
  final String url;
  final int column, row;

  const StoryboardFrame(this.storyboard, this.url, this.column, this.row);
}
