import 'package:clipious/utils/motion.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/states/edit_layout.dart';
import 'package:clipious/utils/views/components/placeholders.dart';

import '../../../utils.dart';
import '../../../settings/views/components/phone_navigation_editor.dart';
import '../../../settings/views/components/home_experience_setting.dart';

@RoutePage()
class EditHomeLayoutScreen extends StatelessWidget {
  const EditHomeLayoutScreen({super.key});

  List<SmallSource> buildSmallSources(
      BuildContext context, HomeLayout layout, EditLayoutCubit editLayout) {
    var widgets = <SmallSource>[];
    for (int i = 0; i < layout.smallSources.length; i++) {
      HomeDataSource source = layout.smallSources[i];

      widgets.add(SmallSource(
        source: source,
        onSourceChange: (newSource) => editLayout.editSmallSource(i, newSource),
        onDelete: () => editLayout.deleteSmallSource(i),
      ));
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    var colors = Theme.of(context).colorScheme;
    var textStyle = Theme.of(context).textTheme;

    final content = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
        child: ListView(
          children: [
            const HomeExperienceSetting(),
            Text(
              locals.layoutEditorExplanation,
              style: textStyle.bodySmall,
              textAlign: TextAlign.justify,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.secondaryContainer, width: 2),
              ),
              child: BlocProvider(
                create: (context) => EditLayoutCubit(db.getHomeLayout()),
                child: BlocBuilder<EditLayoutCubit, HomeLayout>(
                    builder: (context, layout) {
                  var editLayout = context.read<EditLayoutCubit>();

                  return Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...buildSmallSources(context, layout, editLayout),
                      if (layout.smallSources.length < maxSmallSources)
                        SizedBox(
                            height: 20,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FilledButton.tonal(
                                    onPressed: editLayout.addSmallSource,
                                    child: Text(
                                      locals.layoutEditorAddVideoSource,
                                      style: textStyle.bodySmall,
                                    )),
                              ],
                            )),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                              child: SourceSwitcher(
                            onChange: editLayout.editBigSource,
                            source: layout.bigSource,
                            textStyle: textStyle.bodyLarge,
                          )),
                          IconButton(
                              onPressed: editLayout.toggleShowBigSource,
                              icon: Icon(
                                layout.showBigSource
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ))
                        ],
                      ),
                      AnimatedOpacity(
                        opacity: layout.showBigSource ? 1 : 0.1,
                        duration: AppMotion.fadeDuration(context),
                        child: GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: getGridCount(context),
                          crossAxisSpacing: 5,
                          mainAxisSpacing: 5,
                          childAspectRatio: getGridAspectRatio(context),
                          children: repeatWidget(
                              () => const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 8.0),
                                    child: VideoListItemPlaceHolder(
                                      animate: false,
                                    ),
                                  ),
                              count: 10),
                        ),
                      )
                    ],
                  );
                }),
              ),
            )
          ],
        ),
      ),
    );
    final phone = getDeviceType() == DeviceType.phone;
    final screen = Scaffold(
      appBar: AppBar(
          title: Text(locals.homeLayoutEditor),
          bottom: phone
              ? TabBar(tabs: [
                  Tab(text: locals.phoneNavigationContent),
                  Tab(text: locals.phoneNavigationTitle),
                ])
              : null),
      body: phone
          ? TabBarView(children: [content, const PhoneNavigationEditor()])
          : content,
    );
    return phone ? DefaultTabController(length: 2, child: screen) : screen;
  }
}

class SmallSource extends StatelessWidget {
  final HomeDataSource source;
  final void Function(HomeDataSource? newSource) onSourceChange;
  final Function() onDelete;

  const SmallSource(
      {super.key,
      required this.source,
      required this.onSourceChange,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
                child: SourceSwitcher(
              onChange: onSourceChange,
              source: source,
              big: false,
            )),
            IconButton(
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.clear,
                  size: 15,
                ))
          ],
        ),
        SizedBox(
          height: 80,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: repeatWidget(
                () => const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 75,
                        child: VideoListItemPlaceHolder(
                          small: true,
                          animate: false,
                        ),
                      ),
                    ),
                count: 10),
          ),
        )
      ],
    );
  }
}

class SourceSwitcher extends StatelessWidget {
  final bool big;
  final Function(HomeDataSource? newSource) onChange;
  final HomeDataSource source;
  final TextStyle? textStyle;

  const SourceSwitcher(
      {super.key,
      required this.onChange,
      required this.source,
      this.textStyle,
      this.big = true});

  @override
  Widget build(BuildContext context) {
    var textTheme = Theme.of(context).textTheme;
    var layout = context.select((EditLayoutCubit cubit) => cubit.state);
    var locals = AppLocalizations.of(context)!;
    var colors = Theme.of(context).colorScheme;

    return DropdownButton<HomeDataSource>(
      isExpanded: true,
      style: textStyle ?? textTheme.labelSmall,
      value: source,
      items: HomeDataSource.values
          .where((element) => big ? element.big : element.small)
          // .where((e) => e == source || layout.bigSource != e && !layout.smallSources.contains(e))
          .map((e) {
        bool enabled = e == source ||
            layout.bigSource != e && !layout.smallSources.contains(e);
        return DropdownMenuItem<HomeDataSource>(
            enabled: enabled,
            value: e,
            child: Text(
              e.getLabel(locals),
              overflow: TextOverflow.ellipsis,
              style: !enabled
                  ? TextStyle(color: colors.secondary.withValues(alpha: 0.5))
                  : null,
            ));
      }).toList(),
      onChanged: onChange,
    );
  }
}
