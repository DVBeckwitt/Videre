import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// Recovery feedback stays visible independently of the fading player controls.
class BackendRetryNotice extends StatelessWidget {
  final String? backendName;
  final int alternativeIndex;
  final bool compact;

  const BackendRetryNotice(
      {super.key,
      this.backendName,
      this.alternativeIndex = 0,
      this.compact = false});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final style = Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Colors.white);
          final detailStyle = Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.white70);
          final scaler = MediaQuery.textScalerOf(context);
          final lineHeight =
              scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.43);
          final detailHeight = scaler.scale(detailStyle?.fontSize ?? 12) *
              (detailStyle?.height ?? 1.33);
          final showCount = alternativeIndex > 0 && !compact;
          final twoLineHeight =
              lineHeight * 2 + (showCount ? detailHeight + 4 : 0) + 32;
          final lines =
              compact || constraints.maxHeight < twoLineHeight ? 1 : 2;
          final locals = AppLocalizations.of(context)!;
          return IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(compact ? 4 : 8),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 400),
                    padding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: compact ? 4 : 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                backendName?.trim().isNotEmpty == true
                                    ? locals
                                        .backendTryingNamed(backendName!.trim())
                                    : locals.backendTrying,
                                textAlign: TextAlign.center,
                                maxLines: lines,
                                overflow: TextOverflow.ellipsis,
                                style: style,
                              ),
                            ),
                          ],
                        ),
                        if (showCount) ...[
                          const SizedBox(height: 4),
                          Text(
                            locals.backendAlternativeProgress(alternativeIndex),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: detailStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
