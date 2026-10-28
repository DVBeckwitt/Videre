import 'dart:convert';
import 'dart:io';

// Exercise the CLI using a fake pinned SDK; no Flutter or network is needed.
Future<void> main() async {
  final source = File.fromUri(Platform.script.resolve('validate.dart'));
  final fixture = Directory.systemTemp.createTempSync('videre validation ');
  try {
    final bin =
        Directory.fromUri(fixture.uri.resolve('submodules/flutter/bin/'))
          ..createSync(recursive: true);
    final script = File.fromUri(fixture.uri.resolve('tools/validate.dart'));
    script.parent.createSync();
    script.writeAsStringSync(source.readAsStringSync());
    final log = File.fromUri(fixture.uri.resolve('commands.jsonl'));
    final fakeTool = File.fromUri(fixture.uri.resolve('fake_tool.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  final log = File(Platform.environment['VALIDATE_TEST_LOG']!);
  log.writeAsStringSync(jsonEncode({'args': args, 'cwd': Directory.current.path}) + '\\n', mode: FileMode.append);
  if (log.readAsLinesSync().length.toString() == Platform.environment['VALIDATE_TEST_FAIL_AT']) {
    exitCode = 29;
  }
}
''');

    String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
    for (final tool in ['dart', 'flutter']) {
      final launcher = File.fromUri(
        bin.uri.resolve('$tool${Platform.isWindows ? '.bat' : ''}'),
      );
      launcher.writeAsStringSync(
        Platform.isWindows
            ? '@echo off\r\n"${Platform.resolvedExecutable}" "${fakeTool.path}" $tool %*\r\nexit /b %errorlevel%\r\n'
            : '#!/bin/sh\nexec ${shellQuote(Platform.resolvedExecutable)} ${shellQuote(fakeTool.path)} $tool "\$@"\n',
      );
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['+x', launcher.path]);
        if (result.exitCode != 0) {
          throw StateError('Could not prepare fake SDK');
        }
      }
    }

    void check(bool condition, String message) {
      if (!condition) throw StateError(message);
    }

    List<Map<String, dynamic>> commands() => log.existsSync()
        ? log
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList()
        : [];

    Future<ProcessResult> run(List<String> arguments, {int? failAt}) async {
      if (log.existsSync()) log.deleteSync();
      return Process.run(
        Platform.resolvedExecutable,
        [script.path, ...arguments],
        // Deliberately run outside the fixture repository, under a path with spaces.
        workingDirectory: fixture.parent.path,
        environment: {
          'VALIDATE_TEST_LOG': log.path,
          'VALIDATE_TEST_FAIL_AT': failAt?.toString() ?? '',
        },
      );
    }

    final all = await run([]);
    check(all.exitCode == 0, 'Default stages failed: ${all.stderr}');
    final actual = commands();
    check(actual.length == 4, 'Default must run all four validation commands');
    check(
      actual.every((command) => command['cwd'] == fixture.path),
      'Every command must run at the repository root, independent of caller cwd',
    );
    check(
      actual
              .map((command) => (command['args'] as List).take(2).join(' '))
              .join(',') ==
          'dart format,dart analyze,dart analyze,flutter test',
      'Validation commands ran out of order',
    );
    stdout.writeln(
        'PASS: default stages, pinned SDK, paths with spaces, repository root');

    for (final stage
        in {'all': 4, 'format': 1, 'analyze': 2, 'test': 1}.entries) {
      final result = await run([stage.key]);
      check(result.exitCode == 0, '${stage.key} failed: ${result.stderr}');
      check(commands().length == stage.value,
          '${stage.key} selected wrong commands');
    }
    stdout.writeln('PASS: individual stage selection');

    final failure = await run(['all'], failAt: 2);
    check(failure.exitCode == 29, 'Child exit code was not propagated');
    check(commands().length == 2, 'Validation continued after a failed check');
    stdout.writeln('PASS: child failure propagation and fail-fast behavior');

    for (final args in [
      ['unknown'],
      ['test', 'unexpected'],
    ]) {
      final invalid = await run(args);
      check(invalid.exitCode == 64, 'Invalid arguments must fail');
      check(commands().isEmpty, 'Invalid arguments executed a command');
    }
    final help = await run(['--help']);
    check(help.exitCode == 0 && commands().isEmpty, 'Help executed a command');
    stdout.writeln('PASS: invalid arguments and help do not execute tools');

    File.fromUri(bin.uri.resolve('flutter${Platform.isWindows ? '.bat' : ''}'))
        .deleteSync();
    final missing = await run(['test']);
    check(missing.exitCode != 0, 'Missing SDK must fail');
    check(commands().isEmpty, 'Missing SDK fell back to another Flutter');
    check('${missing.stderr}'.contains('Pinned SDK tool missing'),
        'Missing SDK diagnostic absent');
    stdout.writeln('PASS: missing SDK fails without a global fallback');
  } finally {
    // This directory was created by this test, never supplied by the caller.
    fixture.deleteSync(recursive: true);
  }
}
