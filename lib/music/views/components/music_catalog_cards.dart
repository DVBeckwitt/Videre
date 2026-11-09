import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:flutter/material.dart';

/// A focusable catalog item. Artwork never substitutes a video's thumbnail.
class MusicCatalogCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<ImageObject> thumbnails;
  final VoidCallback onOpen;
  final bool artist;

  const MusicCatalogCard({
    super.key,
    required this.title,
    required this.thumbnails,
    required this.onOpen,
    this.subtitle,
    this.artist = false,
  });

  @override
  State<MusicCatalogCard> createState() => _MusicCatalogCardState();
}

class _MusicCatalogCardState extends State<MusicCatalogCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(widget.artist ? 1000 : 12);
    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: widget.onOpen,
          onFocusChange: (focused) {
            setState(() => _focused = focused);
            if (focused) {
              Scrollable.ensureVisible(context, alignment: 0.5);
            }
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ExcludeSemantics(
                    child: widget.thumbnails.isEmpty
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: radius,
                            ),
                            child: Icon(
                              widget.artist
                                  ? Icons.person_outline_rounded
                                  : Icons.album_outlined,
                              size: 40,
                              color: colors.onSurfaceVariant,
                            ),
                          )
                        : Thumbnail(
                            images: widget.thumbnails,
                            decoration: BoxDecoration(borderRadius: radius),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.title,
                  style: theme.textTheme.titleSmall?.copyWith(height: 1.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.subtitle?.isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant, height: 1.3),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MusicCatalogShelf extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const MusicCatalogShelf(
      {super.key, required this.itemCount, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth < 500 ? 154.0 : 184.0;
      final scaler = MediaQuery.textScalerOf(context);
      final height =
          width + 30 + scaler.scale(14) * 1.3 * 2 + scaler.scale(12) * 1.3 * 2;
      // A real nested horizontal scrollable owns shelf drags, including at its
      // ends, so a gesture on artwork cannot switch the enclosing app page.
      return SizedBox(
        height: height,
        child: ListView.separated(
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: itemCount,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, index) => SizedBox(
            width: width,
            child: itemBuilder(context, index),
          ),
        ),
      );
    });
  }
}

class MusicCatalogGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const MusicCatalogGrid(
      {super.key, required this.itemCount, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 14.0;
      final columns = (constraints.maxWidth / 170).floor().clamp(2, 6);
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: 20,
        children: [
          for (var index = 0; index < itemCount; index++)
            SizedBox(width: width, child: itemBuilder(context, index)),
        ],
      );
    });
  }
}
