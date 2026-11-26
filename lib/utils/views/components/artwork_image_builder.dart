import 'package:flutter/widgets.dart';

/// Presents decoded artwork using its existing provider and rendered image.
typedef ArtworkImageBuilder = Widget Function(
    BuildContext context, ImageProvider<Object> provider, Widget child);
