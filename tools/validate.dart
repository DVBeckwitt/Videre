import 'dart:io';

// Shared by CI and local development. Keep live-service tests out of this list.
const offlineTestTargets = [
  'test/widget_test.dart',
  'test/app',
  'test/service_test.dart',
  'test/service_local_library_test.dart',
  'test/downloads',
  'test/player',
  'test/music',
  'test/network',
  'test/feedback',
  'test/utils',
  'test/videos/models',
  'test/videos/watch_history_test.dart',
  'test/videos/view',
  'test/videos/state/video_test.dart',
  'test/comments',
  'test/channels/state/channel_state_test.dart',
  'test/notifications',
  'test/search',
  'test/playlists',
  'test/subscription_management/state/subscription_retry_test.dart',
  'test/settings/state/add_server_test.dart',
  'test/settings/state/app_log_test.dart',
  'test/settings/state/server_list_settings_test.dart',
  'test/settings/state/settings_test.dart',
  'test/settings/public_instances_test.dart',
  'test/settings/profile_picker_test.dart',
  'test/settings/connection_help_test.dart',
  'test/settings/network_proxy_test.dart',
  'test/settings/backend_selector_model_test.dart',
  'test/settings/backend_settings_state_test.dart',
  'test/settings/backend_settings_test.dart',
  'test/settings/backend_browser_ui_test.dart',
  'packages/river_player/test/backend_retryability_test.dart',
  'packages/river_player/test/pitch_test.dart',
  'packages/river_player/test/initial_seek_test.dart',
  'packages/river_player/test/playback_lifecycle_test.dart',
  'packages/river_player/test/subtitle_loading_test.dart',
  'packages/just_audio/test/backend_retryability_test.dart',
];

// Keep formatting and strict analysis coverage aligned.
const strictValidationTargets = [
  './test/music',
  './test/widget_test.dart',
  './test/service_test.dart',
  './test/service_local_library_test.dart',
  './test/videos/state/video_test.dart',
  './test/utils/file_db_test.dart',
  './test/utils/person_profiles_test.dart',
  './test/videos/watch_history_test.dart',
  './test/videos/models/history_video_cache_profile_test.dart',
  './test/videos/view/watch_status_button_test.dart',
  './test/videos/view/video_duration_test.dart',
  './test/videos/view/video_dislikes_test.dart',
  './test/settings/profile_picker_test.dart',
  './test/settings/state/add_server_test.dart',
  './test/settings/connection_help_test.dart',
  './test/utils/invidious_image_test.dart',
  './test/utils/selected_server_test.dart',
  './test/utils/image_object_test.dart',
  './test/utils/selected_server_test.dart',
  './test/videos/view/tv_animation_test.dart',
  './test/videos/view/tv_history_test.dart',
  './test/downloads/download_manager_test.dart',
  './test/downloads/download_modal_sheet_test.dart',
  './test/player/adaptive_dash_manifest_test.dart',
  './test/player/playback_session_test.dart',
  './test/player/media_item_artwork_test.dart',
  './test/player/player_queue_lifecycle_test.dart',
  './test/player/queue_navigation_test.dart',
  './test/player/video_quality_test.dart',
  './test/player/seek_preview_test.dart',
  './test/player/player_controls_test.dart',
  './test/player/mini_player_position_test.dart',
  './test/videos/models/storyboard_test.dart',
  './test/videos/models/progress_test.dart',
  './test/utils/backup_test.dart',
  './test/utils/item_list_test.dart',
  './test/utils/select_list_test.dart',
  './test/utils/motion_test.dart',
  './test/playlists',
  './test/player/playlist_playback_test.dart',
  './test/videos/view/video_autoplay_test.dart',
  './test/subscription_management/state/subscription_retry_test.dart',
  './test/utils/pagination_cubits_test.dart',
  './test/utils/subscription_video_list_test.dart',
  './test/utils/sembast_database_test.dart',
  './test/channels/state/channel_state_test.dart',
  './test/notifications',
  './test/search/tv_search_test.dart',
  './test/settings/state/settings_test.dart',
  './test/network',
  './test/app',
  './test/feedback',
  './test/settings/network_proxy_test.dart',
  './test/settings/backend_selector_model_test.dart',
  './test/settings/backend_settings_state_test.dart',
  './test/settings/backend_settings_test.dart',
  './test/settings/backend_browser_ui_test.dart',
  './test/player/backend_playback_recovery_test.dart',
  './test/player/backend_playback_admission_test.dart',
  './test/player/audio_backend_playback_recovery_test.dart',
  './test/player/backend_retry_notice_test.dart',
  './test/player/backend_recovery_state_test.dart',
  './test/player/backend_manual_selection_test.dart',
  './test/player/player_backend_picker_test.dart',
  './test/player/transcript_shortcut_test.dart',
  './test/player/subtitle_failure_test.dart',
  './test/player/playback_speed_reset_test.dart',
  './packages/river_player/test/backend_retryability_test.dart',
  './packages/river_player/test/pitch_test.dart',
  './packages/river_player/test/initial_seek_test.dart',
  './packages/river_player/test/playback_lifecycle_test.dart',
  './packages/river_player/test/subtitle_loading_test.dart',
  './packages/just_audio/test/backend_retryability_test.dart',
  './test/player/proxy_playback_test.dart',
  './test/player/proxy_startup_test.dart',
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
          ...strictValidationTargets,
        ],
      ),
    if (stage == 'all' || stage == 'analyze') ...[
      ('dart', ['analyze', '--no-fatal-warnings', './lib']),
      (
        'dart',
        [
          'analyze',
          '--fatal-infos',
          ...strictValidationTargets,
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
