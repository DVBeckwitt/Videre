import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/states/select_list.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';

import '../../../../settings/views/tv/screens/settings.dart';

class SearchableSelectFromListScreen<T> extends StatefulWidget {
  final String title;
  final Future<List<T>> Function(String query) fetchItems;
  final Function(T selected) onSelect;
  final String Function(T item) titleBuilder;
  final String? Function(T item) descriptionBuilder;

  const SearchableSelectFromListScreen(
      {super.key,
      required this.title,
      required this.fetchItems,
      required this.onSelect,
      required this.titleBuilder,
      required this.descriptionBuilder});

  @override
  State<SearchableSelectFromListScreen<T>> createState() =>
      _SearchableSelectFromListScreenState<T>();
}

class _SearchableSelectFromListScreenState<T>
    extends State<SearchableSelectFromListScreen<T>> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: TvOverscan(
      child: BlocProvider(
        create: (context) => SelectListCubit<T>(SelectListState<T>()),
        child: BlocBuilder<SelectListCubit<T>, SelectListState<T>>(
            builder: (context, state) {
          final cubit = context.read<SelectListCubit<T>>();
          return Column(
            children: [
              SettingsTitle(title: widget.title),
              TvTextField(
                decoration: InputDecoration(label: Text(widget.title)),
                controller: _controller,
                onSubmitted: (value) =>
                    cubit.filterItems(widget.fetchItems, null, null, value),
              ),
              if (state.loading) const LinearProgressIndicator(),
              if (state.hasError)
                Text(AppLocalizations.of(context)!.error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              Expanded(
                  child: ListView(
                children: state.filteredItems
                    .map((e) => SettingsTile(
                          title: widget.titleBuilder(e),
                          description: widget.descriptionBuilder(e),
                          onSelected: (context) {
                            widget.onSelect(e);
                            Navigator.of(context).pop();
                          },
                        ))
                    .toList(),
              ))
            ],
          );
        }),
      ),
    ));
  }
}
