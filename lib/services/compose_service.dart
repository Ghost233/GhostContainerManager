/// Compose v1: thin passthrough onto the orchard compose plugin
/// (`container compose up|down`), plus project discovery by labels.
///
/// Locked facts (docs/research/compose-plugin-integration.md):
/// - The plugin ships only up/down — no ps/diff/logs/build.
/// - Output is human text, never JSON → pass through verbatim (truncated).
/// - Projects are discoverable via labels `com.compose.project` /
///   `com.compose.service` on containers.
/// - Plugin lives in /usr/local/libexec/container-plugins/ (sudo install)
///   and upgrading container wipes that directory → probe on EVERY use,
///   never cache detection.
library;

// Private fields assigned from named parameters (T1b precedent).
// ignore_for_file: prefer_initializing_formals

import '../bridge/container_bridge.dart';
import 'container_models.dart';
import 'container_service.dart';
import 'errors.dart';

/// Result of the `container compose --help` plugin-presence probe.
class ComposePluginStatus {
  const ComposePluginStatus({required this.installed, required this.detail});

  final bool installed;

  /// First lines of `--help` output, or the failure description.
  final String detail;
}

/// Raw passthrough result of `compose up|down` (human text, never JSON).
class ComposeRunResult {
  const ComposeRunResult({
    required this.exitCode,
    required this.output,
    required this.truncated,
  });

  final int exitCode;

  /// stdout followed by stderr (when non-empty).
  final String output;

  /// True when [output] was cut to [ComposeService.maxOutputBytes] (tail
  /// kept — errors and final summaries live at the end).
  final bool truncated;

  Map<String, Object?> toWire() => <String, Object?>{
    'exitCode': exitCode,
    'output': output,
    'truncated': truncated,
  };
}

/// One service inside a compose project (label-derived).
class ComposeProjectService {
  const ComposeProjectService({
    required this.serviceName,
    required this.containerId,
    required this.state,
  });

  final String serviceName;
  final String containerId;
  final ContainerState state;

  Map<String, Object?> toWire() => <String, Object?>{
    'service': serviceName,
    'containerId': containerId,
    'state': state.wireName,
  };
}

/// A compose project aggregated from container labels.
class ComposeProject {
  const ComposeProject({required this.name, required this.services});

  final String name;
  final List<ComposeProjectService> services;

  int get runningCount => services
      .where((service) => service.state == ContainerState.running)
      .length;

  Map<String, Object?> toWire() => <String, Object?>{
    'name': name,
    'runningCount': runningCount,
    'services': services
        .map((service) => service.toWire())
        .toList(growable: false),
  };
}

class ComposeService {
  ComposeService({
    required ContainerBridge bridge,
    required ContainerService containerService,
    int maxOutputBytes = defaultMaxOutputBytes,
  }) : _bridge = bridge,
       _containerService = containerService,
       maxOutputBytes = maxOutputBytes;

  final ContainerBridge _bridge;
  final ContainerService _containerService;

  /// Same 64 KiB cap as container_exec (#13 shell/pty analogy).
  static const int defaultMaxOutputBytes = 64 * 1024;
  final int maxOutputBytes;

  static const String projectLabel = 'com.compose.project';
  static const String serviceLabel = 'com.compose.service';

  static const String installHint =
      'Install the compose plugin, then retry: download the '
      'container-compose binary from its release page and run\n'
      '  sudo mkdir -p /usr/local/libexec/container-plugins && '
      'sudo cp container-compose /usr/local/libexec/container-plugins/\n'
      'Note: upgrading container wipes the plugin directory — reinstall '
      'after every container upgrade.';

  /// Official plugin probe (`container compose --help`). Never cached —
  /// upgrading the container CLI deletes plugin binaries.
  Future<ComposePluginStatus> detect() async {
    final result = await _bridge.composeHelp();
    if (result.exitCode == 0 &&
        result.stdout.contains('up') &&
        result.stdout.contains('down')) {
      return ComposePluginStatus(
        installed: true,
        detail: _firstLines(result.stdout),
      );
    }
    return ComposePluginStatus(
      installed: false,
      detail: result.stderr.trim().isEmpty
          ? 'exit ${result.exitCode}: ${_firstLines(result.stdout)}'
          : result.stderr.trim(),
    );
  }

  /// Throws when the plugin is absent — call before every up/down run.
  Future<void> _requirePlugin() async {
    final status = await detect();
    if (!status.installed) {
      throw GcmException(
        GcmErrorCode.notFound,
        'The compose plugin is not installed.',
        hint: installHint,
      );
    }
  }

  /// Compose projects currently present, aggregated from container labels.
  Future<List<ComposeProject>> listProjects() async {
    final containers = await _containerService.listContainers(
      const ContainerQuery(label: null),
    );
    final byProject = <String, List<ComposeProjectService>>{};
    for (final container in containers) {
      final project = container.labels[projectLabel];
      if (project == null || project.isEmpty) continue;
      byProject
          .putIfAbsent(project, () => <ComposeProjectService>[])
          .add(
            ComposeProjectService(
              serviceName: container.labels[serviceLabel] ?? '',
              containerId: container.id,
              state: container.state,
            ),
          );
    }
    return byProject.entries
        .map(
          (entry) => ComposeProject(
            name: entry.key,
            services: List.unmodifiable(entry.value),
          ),
        )
        .toList(growable: false);
  }

  /// `container compose up`. [file] must be an absolute path (the CLI runs
  /// with an unspecified working directory, so relative paths are unsafe).
  Future<ComposeRunResult> up({
    required String file,
    String? projectName,
    bool dryRun = false,
    bool forceRecreate = false,
    String pull = 'missing',
  }) {
    _requireAbsolute(file);
    const allowedPull = <String>{'missing', 'always', 'never'};
    if (!allowedPull.contains(pull)) {
      throw GcmException(
        GcmErrorCode.invalidArgument,
        'Invalid pull policy "$pull".',
        hint: 'Allowed values: ${allowedPull.join(', ')}.',
      );
    }
    final arguments = <String>[
      'up',
      '--file',
      file,
      if (projectName != null && projectName.isNotEmpty) ...[
        '--project-name',
        projectName,
      ],
      if (dryRun) '--dry-run',
      if (forceRecreate) '--force-recreate',
      '--pull',
      pull,
    ];
    return _run(arguments);
  }

  /// `container compose down`. At least one of [file] / [projectName] is
  /// required (the plugin cannot guess the project otherwise).
  Future<ComposeRunResult> down({
    String? file,
    String? projectName,
    bool keepNetworks = false,
  }) {
    final hasFile = file != null && file.isNotEmpty;
    final hasProject = projectName != null && projectName.isNotEmpty;
    if (!hasFile && !hasProject) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        'compose down requires at least one of file or projectName.',
      );
    }
    if (hasFile) _requireAbsolute(file);
    final arguments = <String>[
      'down',
      if (hasFile) ...['--file', file],
      if (hasProject) ...['--project-name', projectName],
      if (keepNetworks) '--keep-networks',
    ];
    return _run(arguments);
  }

  Future<ComposeRunResult> _run(List<String> arguments) async {
    await _requirePlugin();
    final result = await _bridge.composeRun(arguments);
    final output = _combine(result);
    if (result.exitCode != 0) {
      throw GcmException(
        GcmErrorCode.internal,
        'compose ${arguments.first} failed (exit ${result.exitCode}).',
        hint: _truncate(output).value,
      );
    }
    final truncated = _truncate(output);
    return ComposeRunResult(
      exitCode: result.exitCode,
      output: truncated.value,
      truncated: truncated.truncated,
    );
  }

  static String _combine(BridgeCommandResult result) {
    final stdout = result.stdout.trimRight();
    final stderr = result.stderr.trimRight();
    if (stderr.isEmpty) return stdout;
    if (stdout.isEmpty) return stderr;
    return '$stdout\n$stderr';
  }

  /// Keeps the TAIL: compose errors and the final plan summary live at the
  /// end of the output.
  _Truncated _truncate(String output) {
    final bytes = output.length;
    if (bytes <= maxOutputBytes) return _Truncated(output, false);
    final kept = output.substring(bytes - maxOutputBytes);
    return _Truncated('…（前段输出已截断）\n$kept', true);
  }

  static void _requireAbsolute(String file) {
    if (file.isEmpty || !file.startsWith('/')) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        'The compose file path must be absolute.',
        hint:
            'Relative paths resolve against an unspecified working '
            'directory; pass the full path, e.g. /Users/you/app/compose.yaml.',
      );
    }
  }

  static String _firstLines(String text) {
    final lines = text.trim().split('\n');
    return lines.take(3).join('\n');
  }
}

class _Truncated {
  const _Truncated(this.value, this.truncated);

  final String value;
  final bool truncated;
}
