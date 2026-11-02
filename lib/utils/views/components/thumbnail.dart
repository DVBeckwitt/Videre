import 'package:clipious/utils/motion.dart';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/states/thumbnail.dart';
import 'package:clipious/utils/views/components/selected_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class Thumbnail extends StatelessWidget {
  final Widget? child;
  final double? height;
  final double? width;

  final List<String>? thumbnails;
  final List<ImageObject>? images;
  final BoxDecoration decoration;

  const Thumbnail(
      {super.key,
      this.child,
      this.thumbnails,
      this.images,
      required this.decoration,
      this.width,
      this.height});

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    return SelectedServerBuilder(builder: (context, server) {
      return server == null
          ? Container(
              decoration: decoration,
              width: width,
              height: height,
              child: child)
          : LayoutBuilder(builder: (context, constraints) {
              final ratio = MediaQuery.devicePixelRatioOf(context);
              final physicalWidth =
                  (width?.isFinite == true ? width! : constraints.maxWidth) *
                      ratio;
              final physicalHeight =
                  (height?.isFinite == true ? height! : constraints.maxHeight) *
                      ratio;
              final candidates = images == null
                  ? thumbnails ?? <String>[]
                  : ImageObject.getThumbnailUrlsForSize(images,
                      width: physicalWidth, height: physicalHeight);
              // Google host aliases can resolve to the same cached image.
              // Retrying that key keeps its failed Image stream alive and
              // prevents later sizes from being tried.
              final seen = <String>{};
              final urls = candidates.where((url) {
                return seen.add(invidiousImageUrl(url, server));
              }).toList();
              return BlocProvider(
                key: ValueKey(Object.hash(server, Object.hashAll(urls))),
                create: (context) => ThumbnailCubit(ThumbnailState(urls: urls)),
                child: BlocBuilder<ThumbnailCubit, ThumbnailState>(
                    builder: (context, state) {
                  if (state.selected == null) {
                    return _ErrorWidget(
                        decoration: decoration, width: width, height: height);
                  } else {
                    final cubit = context.read<ThumbnailCubit>();

                    final url = invidiousImageUrl(state.selected!, server);
                    final source = images
                        ?.where((image) => image.url == state.selected)
                        .firstOrNull;
                    int? decodeWidth;
                    int? decodeHeight;
                    if (source != null &&
                        source.width > 0 &&
                        source.height > 0 &&
                        physicalWidth.isFinite &&
                        physicalHeight.isFinite &&
                        physicalWidth > 0 &&
                        physicalHeight > 0) {
                      // Specify one axis so decoding preserves the source
                      // aspect ratio while retaining enough pixels for cover.
                      if (physicalWidth / source.width >=
                          physicalHeight / source.height) {
                        decodeWidth =
                            math.min(source.width, physicalWidth).ceil();
                      } else {
                        decodeHeight =
                            math.min(source.height, physicalHeight).ceil();
                      }
                    }

                    return CachedNetworkImage(
                      key: ValueKey(url),
                      cacheKey: url,
                      httpHeaders: server.headersForUrl(url),
                      memCacheWidth: decodeWidth,
                      memCacheHeight: decodeHeight,
                      imageBuilder: (context, imageProvider) =>
                          AnimatedContainer(
                        height: height,
                        width: width,
                        decoration: decoration.copyWith(
                            image: DecorationImage(
                                image: ResizeImage.resizeIfNeeded(
                                    decodeWidth, decodeHeight, imageProvider),
                                fit: BoxFit.cover)),
                        // duration: animationDuration,
                        duration:
                            AppMotion.duration(context, animationDuration ~/ 2),
                        curve: Curves.easeInOutQuad,
                        child: child,
                      ),
                      imageUrl: url,
                      placeholderFadeInDuration:
                          AppMotion.fadeDuration(context),
                      fadeInDuration: AppMotion.fadeDuration(context),
                      fadeOutDuration: AppMotion.fadeDuration(context),
                      errorWidget: (context, url, error) {
                        // Each mounted widget must advance, even when its
                        // failed image stream is shared with another widget.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!cubit.isClosed &&
                              cubit.state.selected == state.selected) {
                            cubit.onThumbnailFailed();
                          }
                        });
                        return _ErrorWidget(
                          decoration: decoration,
                          width: width,
                          height: height,
                        );
                      },
                      progressIndicatorBuilder: (context, url, progress) =>
                          Container(
                        height: height,
                        width: width,
                        alignment: Alignment.center,
                        decoration: decoration.copyWith(
                            color: colors.secondaryContainer),
                        // duration: animationDuration,
                        child: const SizedBox(
                            height: 20,
                            width: 20,
                            child: MotionLoadingIndicator(
                                child: CircularProgressIndicator(
                              strokeWidth: 1,
                            ))),
                      ),
                    );
                  }
                }),
              );
            });
    });
  }
}

class _ErrorWidget extends StatelessWidget {
  final double? height;
  final double? width;
  final BoxDecoration decoration;

  const _ErrorWidget({this.height, this.width, required this.decoration});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: height,
      width: width,
      alignment: Alignment.center,
      decoration: decoration.copyWith(color: colors.secondaryContainer),
      // duration: animationDuration,
      child: SizedBox(
          height: 20,
          width: 20,
          child: Icon(
            Icons.error_outline,
            color: colors.onSecondaryContainer.withValues(alpha: 0.5),
          )),
    );
  }
}
