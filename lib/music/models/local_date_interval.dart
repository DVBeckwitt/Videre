/// The local-time interval covering a pair of inclusive calendar dates.
class LocalDateInterval {
  LocalDateInterval.inclusive(DateTime firstDay, DateTime lastDay)
      : start = DateTime(firstDay.year, firstDay.month, firstDay.day),
        // Advance the calendar date so short and long days end at midnight.
        endExclusive = DateTime(lastDay.year, lastDay.month, lastDay.day + 1) {
    if (!endExclusive.isAfter(start)) {
      throw ArgumentError('The end date must be on or after the start date.');
    }
  }

  final DateTime start;
  final DateTime endExclusive;

  bool contains(DateTime instant) =>
      !instant.isBefore(start) && instant.isBefore(endExclusive);
}
