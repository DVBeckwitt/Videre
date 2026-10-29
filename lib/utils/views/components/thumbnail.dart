import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/network/onion_image_client.dart';
import 'package:clipious/network/onion_verification.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/states/thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class Thumbnail extends StatelessWidget {
  // Keep the existing clearnet image cache unchanged. Onion images need a
  // transport that cannot forward verification headers through redirects.
  static final _onionCache = CacheManager(Config('videreOnionThumbnails',
      fileService: HttpFileService(httpClient: OnionImageClient())));

  final Widget? child;
  final double? height;
  final double? width;

  final List<String>? thumbnails;
  final BoxDecoration decoration;

  const Thumbnail(
      {super.key,
      this.child,
      this.thumbnails,
      required this.decoration,
      this.width,
      this.height});

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    return FutureBuilder<Server?>(
        future: db.getCurrentlySelectedServer(),
        builder: (context, server) {
          return !server.hasData || server.data == null
              ? Container(
                  decoration: decoration,
                  width: width,
                  height: height,
                  child: child)
              : BlocProvider(
                  create: (context) =>
                      ThumbnailCubit(ThumbnailState(urls: thumbnails ?? [])),
                  child: BlocBuilder<ThumbnailCubit, ThumbnailState>(
                      builder: (context, state) {
                    if (state.selected == null) {
                      return _ErrorWidget(
                          decoration: decoration, width: width, height: height);
                    } else {
                      final cubit = context.read<ThumbnailCubit>();

                      final url = state.selected!.startsWith('/')
                          ? server.data!.url + state.selected!
                          : state.selected!;

                      return CachedNetworkImage(
                        key: ValueKey(url),
                        cacheKey: url,
                        cacheManager:
                            OnionVerification.origin(Uri.parse(url)) != null
                                ? _onionCache
                                : null,
                        httpHeaders: server.data!.headersForUrl(url),
                        errorListener: (value) => cubit.onThumbnailFailed(),
                        imageBuilder: (context, imageProvider) =>
                            AnimatedContainer(
                          height: height,
                          width: width,
                          decoration: decoration.copyWith(
                              image: DecorationImage(
                                  image: imageProvider, fit: BoxFit.cover)),
                          // duration: animationDuration,
                          duration: animationDuration ~/ 2,
                          curve: Curves.easeInOutQuad,
                          child: child,
                        ),
                        imageUrl: url,
                        placeholderFadeInDuration: animationDuration,
                        fadeInDuration: animationDuration,
                        fadeOutDuration: animationDuration,
                        errorWidget: (context, url, error) => _ErrorWidget(
                          decoration: decoration,
                          width: width,
                          height: height,
                        ),
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
                              child: CircularProgressIndicator(
                                strokeWidth: 1,
                              )),
                        ),
                      );
                    }
                  }),
                );
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
