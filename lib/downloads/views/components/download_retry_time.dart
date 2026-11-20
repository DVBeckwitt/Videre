import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String downloadRetryTime(BuildContext context, DateTime retryAt) {
  final locale = Localizations.localeOf(context).toString();
  final date = DateFormat.yMd(locale);
  final format = MediaQuery.alwaysUse24HourFormatOf(context)
      ? date.add_Hms()
      : date.add_jms();
  return format.format(retryAt.toLocal());
}

/// Re-enable an explicit retry at its deadline without polling the server.
class DownloadRetryAvailability extends StatefulWidget {
  const DownloadRetryAvailability(
      {super.key, required this.retryAt, required this.builder});

  final DateTime? retryAt;
  final Widget Function(BuildContext context, String? waitUntil) builder;

  @override
  State<DownloadRetryAvailability> createState() =>
      _DownloadRetryAvailabilityState();
}

class _DownloadRetryAvailabilityState extends State<DownloadRetryAvailability> {
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    final remaining = widget.retryAt?.difference(DateTime.now());
    _timer = remaining != null && remaining > Duration.zero
        ? Timer(remaining, () => setState(() => _timer = null))
        : null;
  }

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(DownloadRetryAvailability oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.retryAt != oldWidget.retryAt) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context,
      _timer == null ? null : downloadRetryTime(context, widget.retryAt!));
}
