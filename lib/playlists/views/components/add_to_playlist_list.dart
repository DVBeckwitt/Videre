import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/playlists/states/playlist_list.dart';

import '../../../utils.dart';

class AddPlayListButton extends StatelessWidget {
  const AddPlayListButton({super.key});

  addPlaylistDialog(BuildContext context) {
    var cubit = context.read<PlaylistListCubit>();
    showDialog<String>(
        useRootNavigator: false,
        context: context,
        builder: (BuildContext context) => Dialog(
              child: AddPlayListForm(
                afterAdd: (playlistId) => cubit.refreshPlaylists(),
              ),
            ));
  }

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => addPlaylistDialog(context),
      child: const Icon(Icons.add),
    );
  }
}

class AddPlayListForm extends StatefulWidget {
  final Future<void> Function(String playlistId)? afterAdd;

  const AddPlayListForm({super.key, this.afterAdd});

  @override
  State<AddPlayListForm> createState() => _AddPlayListFormState();
}

class _AddPlayListFormState extends State<AddPlayListForm> {
  final TextEditingController nameController = TextEditingController(text: '');
  String privacyValue = 'local';
  bool isLoggedIn = false;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    service.isLoggedIn().then((value) {
      if (mounted) setState(() => isLoggedIn = value);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  addPlaylist(BuildContext context) async {
    if (saving || nameController.text.trim().isEmpty) return;
    setState(() => saving = true);
    var locals = AppLocalizations.of(context)!;
    try {
      var id =
          await service.createPlayList(nameController.value.text, privacyValue);

      final afterAdd = widget.afterAdd;
      if (context.mounted) Navigator.pop(context);
      if (id != null) await afterAdd?.call(id);
    } catch (err) {
      if (context.mounted) {
        showAlertDialog(context, locals.error, [Text(err.toString())]);
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    return SizedBox(
      width: 400,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(locals.addPlayList),
            TextField(
              decoration: InputDecoration(hintText: locals.playListName),
              controller: nameController,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text('${locals.playlistVisibility}:'),
                  ),
                  DropdownButton(
                    value: privacyValue,
                    items: [
                      DropdownMenuItem(
                          value: 'local', child: Text(locals.onDevice)),
                      if (isLoggedIn) ...[
                        DropdownMenuItem(
                            value: 'public',
                            child: Text(locals.publicPlaylist)),
                        DropdownMenuItem(
                            value: 'unlisted',
                            child: Text(locals.unlistedPlaylist)),
                        DropdownMenuItem(
                            value: 'private',
                            child: Text(locals.privatePlaylist)),
                      ],
                    ],
                    onChanged: (value) {
                      setState(() {
                        privacyValue = value ?? '';
                      });
                    },
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(locals.cancel),
                ),
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          addPlaylist(context);
                        },
                  child: Text(locals.add),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
