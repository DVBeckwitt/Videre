import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:clipious/utils.dart';

class TvButton extends StatelessWidget {
  final Widget? child;
  final Function(BuildContext context)? onPressed;
  final Color? focusedColor;
  final Color? unfocusedColor;
  final double? borderRadius;
  final bool? autofocus;
  final Function(bool focus)? onFocusChanged;
  final Widget Function(BuildContext context, bool hasFocus)? builder;

  const TvButton(
      {super.key,
      this.child,
      this.onPressed,
      this.focusedColor,
      this.unfocusedColor,
      this.borderRadius,
      this.autofocus,
      this.onFocusChanged,
      this.builder});

  Color? _focusedForeground(Color background, ColorScheme colors) {
    if (background.a == 0) return null;
    if (background == colors.primary) return colors.onPrimary;
    if (background == colors.primaryContainer) return colors.onPrimaryContainer;
    if (background == colors.secondaryContainer) {
      return colors.onSecondaryContainer;
    }

    final luminance =
        Color.alphaBlend(background, colors.surface).computeLuminance();
    final contrastWithBlack = (luminance + 0.05) / 0.05;
    final contrastWithWhite = 1.05 / (luminance + 0.05);
    return contrastWithBlack >= contrastWithWhite ? Colors.black : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final defaultFocusColor = colors.brightness == Brightness.dark
        ? colors.primaryContainer
        : colors.primary;
    return Focus(
      autofocus: autofocus ?? false,
      onFocusChange: onFocusChanged,
      onKeyEvent: (node, event) => onPressed != null
          ? onTvSelect(event, context, onPressed!)
          : KeyEventResult.ignored,
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasFocus;
          final background = hasFocus
              ? focusedColor ?? defaultFocusColor
              : unfocusedColor ?? colors.secondaryContainer;
          final foreground =
              hasFocus ? _focusedForeground(background, colors) : null;
          final buildChild = builder;
          final content = buildChild == null
              ? child
              : Builder(builder: (context) => buildChild(context, hasFocus));

          return Align(
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              duration: AppMotion.duration(context),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(borderRadius ?? 2000),
              ),
              child: content == null
                  ? null
                  : DefaultTextStyle.merge(
                      style: TextStyle(color: foreground),
                      child: IconTheme.merge(
                        data: IconThemeData(color: foreground),
                        child: content,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}
