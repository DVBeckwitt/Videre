import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/views/components/external_link.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pub_semver/pub_semver.dart';

const _releaseDirectory = 'docs/releases/';
final _noteLink = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');

List<String> releaseVersionsFromAssets(Iterable<String> assets) {
  final versions = <Version>[];
  for (final path in assets) {
    if (!path.startsWith('${_releaseDirectory}v') || !path.endsWith('.md')) {
      continue;
    }
    final tag = path.substring(_releaseDirectory.length + 1, path.length - 3);
    try {
      versions.add(Version.parse(tag));
    } on FormatException {
      // Only versioned release notes belong in the picker.
    }
  }
  versions.sort((a, b) => b.compareTo(a));
  return versions.map((version) => version.toString()).toList();
}

void openReleaseNotes(BuildContext context, String installedVersion,
    {bool television = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ReleaseNotesScreen(
        installedVersion: installedVersion, television: television),
  ));
}

class ReleaseNotesScreen extends StatefulWidget {
  const ReleaseNotesScreen(
      {super.key, required this.installedVersion, this.television = false});

  final String installedVersion;
  final bool television;

  @override
  State<ReleaseNotesScreen> createState() => _ReleaseNotesScreenState();
}

class _ReleaseNotesScreenState extends State<ReleaseNotesScreen> {
  late final _installed = widget.installedVersion.split('+').first;
  late String _selected = _installed;
  AssetBundle? _bundle;
  late Future<List<String>> _versions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (_bundle == bundle) return;
    _bundle = bundle;
    _versions = AssetManifest.loadFromAssetBundle(bundle)
        .then((manifest) => releaseVersionsFromAssets(manifest.listAssets()));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final reader = FutureBuilder<List<String>>(
      future: _versions,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final versions = snapshot.data ?? const <String>[];
        final hasNotes = versions.contains(_selected);
        final picker = DropdownButton<String>(
          autofocus: widget.television,
          isExpanded: true,
          value: _selected,
          items: [
            if (!versions.contains(_installed)) _installed,
            ...versions,
          ].map((version) {
            return DropdownMenuItem(
              value: version,
              child: Text(version == _installed
                  ? locals.releaseNotesInstalledVersion(version)
                  : version),
            );
          }).toList(),
          onChanged: (value) {
            if (value != null) setState(() => _selected = value);
          },
        );
        final source = Uri.https('github.com',
            '/DVBeckwitt/Videre/blob/v$_selected/docs/releases/v$_selected.md');
        return FutureBuilder<String>(
          key: ValueKey(_selected),
          future: hasNotes
              ? _bundle!.loadString('${_releaseDirectory}v$_selected.md')
              : null,
          builder: (context, note) => Column(children: [
            Row(children: [
              Expanded(child: picker),
              if (hasNotes)
                PopupMenuButton<Uri>(
                  tooltip: locals.releaseNotesLinks,
                  icon: const Icon(Icons.link),
                  onSelected: (url) => openExternalLink(context, url),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: Uri.https('github.com',
                          '/DVBeckwitt/Videre/releases/tag/v$_selected'),
                      child: Text(locals.releaseNotesGithub),
                    ),
                    for (final link in _noteLink.allMatches(note.data ?? ''))
                      PopupMenuItem(
                        value: source.resolve(link[2]!),
                        child: Text(link[1]!.replaceAll(RegExp(r'\s+'), ' ')),
                      ),
                  ],
                ),
            ]),
            Expanded(
              child: note.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : note.hasData
                      ? _NoteBody(markdown: note.requireData, source: source)
                      : Center(child: Text(locals.releaseNotesUnavailable)),
            ),
          ]),
        );
      },
    );
    return Scaffold(
      appBar: AppBar(title: Text(locals.releaseNotes)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: widget.television
                ? TvOverscan(child: reader)
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: reader),
          ),
        ),
      ),
    );
  }
}

class _NoteBody extends StatefulWidget {
  const _NoteBody({required this.markdown, required this.source});
  final String markdown;
  final Uri source;

  @override
  State<_NoteBody> createState() => _NoteBodyState();
}

class _NoteBodyState extends State<_NoteBody> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _scrollWithRemote(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final position = _scroll.position;
    final step = position.viewportDimension / 2;
    final target = (position.pixels + (down ? step : -step))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (target == position.pixels) return KeyEventResult.ignored;
    _scroll.jumpTo(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paragraphs = widget.markdown
        .trim()
        .replaceAll('\r', '')
        .split(RegExp(r'\n\s*\n|\n(?=- )'));
    return Focus(
      onKeyEvent: _scrollWithRemote,
      child: Builder(builder: (context) {
        return DecoratedBox(
          decoration: BoxDecoration(
              border: Border.all(
                  color: Focus.of(context).hasPrimaryFocus
                      ? theme.colorScheme.primary
                      : Colors.transparent)),
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            children: [
              for (final paragraph in paragraphs)
                _noteParagraph(paragraph, theme.textTheme),
            ],
          ),
        );
      }),
    );
  }

  Widget _noteParagraph(String paragraph, TextTheme theme) {
    final heading = paragraph.startsWith('#');
    final text = paragraph
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'^#+ '), '')
        .replaceFirst(RegExp(r'^- '), '• ')
        .replaceAll('**', '')
        .replaceAll('`', '');
    final style = heading ? theme.titleLarge : theme.bodyLarge;
    final spans = <InlineSpan>[];
    var start = 0;
    for (final link in _noteLink.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(start, link.start)));
      final url = widget.source.resolve(link[2]!);
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Semantics(
          link: true,
          child: InkWell(
            onTap: () => openExternalLink(context, url),
            child: Text(link[1]!,
                style: style?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline)),
          ),
        ),
      ));
      start = link.end;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        header: heading,
        child: spans.isEmpty
            ? Text(text, style: style)
            : Text.rich(
                TextSpan(children: [
                  ...spans,
                  TextSpan(text: text.substring(start)),
                ]),
                style: style),
      ),
    );
  }
}
