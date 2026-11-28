import 'package:clipious/downloads/services/download_transfer_rate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resumed bytes are excluded from the transfer rate', () {
    final rate = DownloadTransferRate();
    expect(rate.observe(6000000, const Duration(seconds: 4)), isNull);
    expect(rate.observe(6150000, const Duration(milliseconds: 4250)), isNull);
    expect(rate.observe(6300000, const Duration(milliseconds: 4500)), 600000);
    expect(rate.observe(6400000, const Duration(milliseconds: 4600)), 600000);
    expect(rate.observe(6400000, const Duration(seconds: 5)), 200000);
    expect(rate.observe(6400000, const Duration(milliseconds: 5500)), 0);
  });

  test('a restarted transfer discards its rate and starts a new sample', () {
    final rate = DownloadTransferRate();
    expect(rate.observe(5000, Duration.zero), isNull);
    expect(rate.observe(9000, const Duration(seconds: 1)), 4000);
    expect(rate.observe(9500, const Duration(milliseconds: 1100)), 4000);
    expect(rate.observe(9200, const Duration(seconds: 2)), isNull);
    expect(rate.observe(10200, const Duration(milliseconds: 2500)), 2000);
  });
}
