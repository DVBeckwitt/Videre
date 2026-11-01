import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

class ChannelLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const ChannelLoadError({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(locals.itemlistErrorGeneric),
          const SizedBox(height: 8),
          FilledButton.icon(
            autofocus: true,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(locals.retry),
          ),
        ],
      ),
    );
  }
}
