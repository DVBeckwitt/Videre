import 'dart:io';

// Shared by CI and local development. Keep live-service tests out of this list.
const offlineTestTargets = [
  'test/widget_test.dart',
  'test/service_test.dart',
  'test/service_local_library_test.dart',
  'test/downloads',
  'test/player',
  'test/network',
  'test/utils',
  'test/videos/models',
  'test/videos/view',
  'test/videos/state/video_test.dart',
  'test/comments',
  'test/search',
  'test/subscription_management/state/subscription_retry_test.dart',
  'test/settings/state/add_server_test.dart',
  'test/settings/state/app_log_test.dart',
  'test/settings/state/server_list_settings_test.dart',
  'test/settings/state/settings_test.dart',
  'test/settings/public_instances_test.dart',
  'test/settings/connection_help_test.dart',
  'test/settings/network_proxy_test.dart',
];

const usage = 'Usage: dart tools/validate.dart [all|format|analyze|test]';

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.single == '--help' || args.single == '-h')) {
    stdout.writeln(usage);
    return;
  }
  if (args.length > 1 ||
      (args.isNotEmpty &&
          !['all', 'format', 'analyze', 'test'].contains(args.single))) {
    stderr.writeln(usage);
    exitCode = 64;
    return;
  }

  final stage = args.isEmpty ? 'all' : args.single;
  final root = File.fromUri(Platform.script).absolute.parent.parent;
  final commands = <(String, List<String>)>[
    if (stage == 'all' || stage == 'format')
      (
        'dart',
        [
          'format',
          '--output=none',
          '--set-exit-if-changed',
          './lib',
          './test/videos/state/video_test.dart',
          './test/utils/file_db_test.dart',
          './test/network',
          './test/settings/network_proxy_test.dart',
          './test/player/proxy_playback_test.dart',
          './test/player/proxy_startup_test.dart',
        ],
      ),
    if (stage == 'all' || stage == 'analyze') ...[
      ('dart', ['analyze', '--no-fatal-warnings', './lib']),
      (
        'dart',
        [
          'analyze',
          '--fatal-infos',
          './test/videos/state/video_test.dart',
          './test/utils/file_db_test.dart',
          './test/network',
          './test/settings/network_proxy_test.dart',
          './test/player/proxy_playback_test.dart',
          './test/player/proxy_startup_test.dart',
        ],
      ),
    ],
    if (stage == 'all' || stage == 'test')
      ('flutter', ['test', ...offlineTestTargets]),
  ];

  for (final (tool, arguments) in commands) {
    final executable = File.fromUri(
      root.uri.resolve(
        'submodules/flutter/bin/$tool${Platform.isWindows ? '.bat' : ''}',
      ),
    );
    if (!executable.existsSync()) {
      stderr.writeln('Pinned SDK tool missing: ${executable.path}');
      stderr.writeln('Run git submodule update --init and flutter pub get.');
      exitCode = 1;
      return;
    }
    stdout.writeln('> $tool ${arguments.join(' ')}');
    try {
      final process = await Process.start(
        executable.path,
        arguments,
        workingDirectory: root.path,
        runInShell: Platform.isWindows,
        mode: ProcessStartMode.inheritStdio,
      );
      final result = await process.exitCode;
      if (result != 0) {
        exitCode = result;
        return;
      }
    } on ProcessException catch (error) {
      stderr.writeln('Could not start $tool: $error');
      exitCode = 1;
      return;
    }
  }
}
