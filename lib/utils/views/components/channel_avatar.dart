import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:flutter/material.dart';

/// Optional channel artwork never needs an error icon or a separate loading
/// spinner. Keep the channel recognizable while the finite private candidates
/// load, or when its instance cannot supply any of them.
class ChannelAvatar extends StatelessWidget {
  final String name;
  final List<ImageObject>? images;
  final double? size;

  const ChannelAvatar({super.key, required this.name, this.images, this.size});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final initial =
        trimmed.isEmpty ? null : trimmed.characters.first.toUpperCase();
    return ExcludeSemantics(
      child: Thumbnail(
        images: images ?? const [],
        // Empty optional artwork needs only the local initial, even before an
        // account is available. Every actual image still uses private routing.
        useInvidiousProxy:
            images?.any((image) => image.url.trim().isNotEmpty) ?? false,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.secondaryContainer,
        ),
        fallback: Center(
          child: FractionallySizedBox(
            widthFactor: 0.55,
            heightFactor: 0.55,
            child: FittedBox(
              fit: BoxFit.contain,
              child: initial == null
                  ? Icon(Icons.person_outline_rounded,
                      color: colors.onSecondaryContainer)
                  : Text(initial,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w500,
                          color: colors.onSecondaryContainer)),
            ),
          ),
        ),
      ),
    );
  }
}
