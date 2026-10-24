/// Project workflow service (T7 / issue #22).
///
/// The project label is authoritative. `ghostcontainer.toml` is a convenience
/// for resolving a directory to a prefix; unlabelled restored images fall back
/// to the `{prefix}-{name}:latest` naming convention. All runtime mutations go
/// through the shared services or the injected [ProjectCli] seam.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bridge/container_bridge.dart';
import 'app_constants.dart';
import 'container_models.dart';
import 'container_service.dart';
import 'errors.dart';
import 'image_models.dart';
import 'image_service.dart';
import 'project_build_log_store.dart';

const projectLabel = 'com.ghost233.project';
const projectTestRoleLabel = 'com.ghost233.role';
const localRegistryPrefix = '127.0.0.1:5056';
const maxProjectOutputBytes = 64 * 1024;

/// One-shot and streaming CLI operations required by the project workflow.
/// The production adapter is wired outside this stage; tests use a fake.
abstract class ProjectCli {
  Future<BridgeCommandResult> run(List<String> args, {Duration? timeout});

  ProjectCliProcess start(List<String> args);
}

abstract class ProjectCliProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;

  /// Terminates the whole CLI process group in the production adapter.
  void terminate();
}

class ProjectSummary {
  const ProjectSummary({
    required this.project,
    required this.images,
    required this.containers,
    this.path,
  });

  final String project;
  final String? path;
  final List<String> images;
  final int containers;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    if (path != null) 'path': path,
    'images': images,
    'containers': containers,
  };
}

class ProjectImageStatus {
  const ProjectImageStatus({
    required this.reference,
    required this.inUse,
    this.sizeBytes,
    this.createdAt,
  });

  final String reference;
  final int? sizeBytes;
  final DateTime? createdAt;
  final bool inUse;

  Map<String, Object?> toJson() => <String, Object?>{
    'reference': reference,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    'inUse': inUse,
  };
}

class ProjectDetails {
  const ProjectDetails({
    required this.project,
    required this.images,
    required this.containers,
    this.path,
  });

  final String project;
  final String? path;
  final List<ProjectImageStatus> images;
  final List<ContainerSnapshotInfo> containers;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    if (path != null) 'path': path,
    'images': images.map((image) => image.toJson()).toList(growable: false),
    'containers': containers
        .map(
          (container) => <String, Object?>{
            'id': container.id,
            'name': container.id,
            'image': container.image,
            'status': container.state.wireName,
            'labels': container.labels,
            if (container.createdAt != null)
              'createdAt': container.createdAt!.toIso8601String(),
          },
        )
        .toList(growable: false),
  };
}

class ProjectInitResult {
  const ProjectInitResult({required this.path, required this.prefix});

  final String path;
  final String prefix;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'prefix': prefix,
  };
}

class ProjectBuildResult {
  const ProjectBuildResult({
    required this.project,
    required this.image,
    required this.exitCode,
    required this.durationMs,
    this.testsPassed,
    this.output,
    this.failureLogPath,
  });

  final String project;
  final String image;
  final int exitCode;
  final int durationMs;
  final bool? testsPassed;
  final String? output;
  final String? failureLogPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    'image': image,
    if (testsPassed != null) 'testsPassed': testsPassed,
    'exitCode': exitCode,
    'durationMs': durationMs,
    if (output != null) 'output': output,
  };
}

class ProjectTestResult {
  const ProjectTestResult({
    required this.project,
    required this.image,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.truncated,
    required this.durationMs,
  });

  final String project;
  final String image;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool truncated;
  final int durationMs;

  bool get testsPassed => exitCode == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    'image': image,
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'truncated': truncated,
    'durationMs': durationMs,
  };
}

class ProjectPushResult {
  const ProjectPushResult({
    required this.source,
    required this.target,
    required this.sizeBytes,
  });

  final String source;
  final String target;
  final int? sizeBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source,
    'target': target,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
  };
}

class ProjectPublishResult {
  const ProjectPublishResult({required this.project, required this.pushed});

  final String project;
  final List<ProjectPushResult> pushed;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    'pushed': pushed.map((image) => image.toJson()).toList(growable: false),
  };
}

class ProjectRestoredImage {
  const ProjectRestoredImage({required this.reference});

  final String reference;

  Map<String, Object?> toJson() => <String, Object?>{'reference': reference};
}

class ProjectRestoreResult {
  const ProjectRestoreResult({required this.project, required this.restored});

  final String project;
  final List<ProjectRestoredImage> restored;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    'restored': restored.map((image) => image.toJson()).toList(growable: false),
  };
}

class ProjectRetainedImage {
  const ProjectRetainedImage({required this.reference, required this.reason});

  final String reference;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'reference': reference,
    'reason': reason,
  };
}

class ProjectExternalImage {
  const ProjectExternalImage({required this.reference, required this.usedBy});

  final String reference;
  final List<String> usedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'reference': reference,
    'usedBy': usedBy,
  };
}

class ProjectDiskReport {
  const ProjectDiskReport({
    required this.beforeBytes,
    required this.afterBytes,
    required this.reclaimedBytes,
  });

  final int beforeBytes;
  final int afterBytes;
  final int reclaimedBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'beforeBytes': beforeBytes,
    'afterBytes': afterBytes,
    'reclaimedBytes': reclaimedBytes,
  };
}

/// Shared UI/MCP report for a real or dry-run project reclaim.
class ProjectReclaimReport {
  const ProjectReclaimReport({
    required this.project,
    required this.stoppedContainers,
    required this.deletedContainers,
    required this.failedContainers,
    required this.deletedImages,
    required this.retainedImages,
    required this.skippedExternalImages,
    required this.disk,
    required this.errors,
  });

  final String project;
  final List<String> stoppedContainers;
  final List<String> deletedContainers;
  final List<String> failedContainers;
  final List<String> deletedImages;
  final List<ProjectRetainedImage> retainedImages;
  final List<ProjectExternalImage> skippedExternalImages;
  final ProjectDiskReport disk;
  final List<String> errors;

  Map<String, Object?> toJson() => <String, Object?>{
    'project': project,
    'containers': <String, Object?>{
      'stopped': stoppedContainers,
      'deleted': deletedContainers,
      'failed': failedContainers,
    },
    'images': <String, Object?>{
      'deleted': deletedImages,
      'retained': retainedImages
          .map((image) => image.toJson())
          .toList(growable: false),
      'skippedExternal': skippedExternalImages
          .map((image) => image.toJson())
          .toList(growable: false),
    },
    'disk': disk.toJson(),
    'errors': errors,
  };
}

class ProjectService {
  factory ProjectService({
    required ProjectCli cli,
    required ContainerService containerService,
    required ImageService imageService,
    Iterable<String> projectPaths = const <String>[],
    String? buildLogDirectory,
    ProjectBuildLogStore? buildLogStore,
    DateTime Function()? clock,
  }) => ProjectService._(
    cli,
    containerService,
    imageService,
    projectPaths: projectPaths,
    buildLogDirectory: buildLogDirectory,
    buildLogStore: buildLogStore,
    clock: clock,
  );

  ProjectService._(
    this._cli,
    this._containerService,
    this._imageService, {
    Iterable<String> projectPaths = const <String>[],
    String? buildLogDirectory,
    ProjectBuildLogStore? buildLogStore,
    DateTime Function()? clock,
  }) : _projectPaths = <String>{...projectPaths},
       _buildLogStore =
           buildLogStore ??
           FileProjectBuildLogStore(
             directory: buildLogDirectory ?? _defaultBuildLogDirectory(),
             clock: clock,
           );

  final ProjectCli _cli;
  final ContainerService _containerService;
  final ImageService _imageService;
  final Set<String> _projectPaths;
  final ProjectBuildLogStore _buildLogStore;
  final Set<String> _lockedProjects = <String>{};

  static String _defaultBuildLogDirectory() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/Library/Application Support/'
        '$applicationBundleId/build-logs';
  }

  Future<ProjectInitResult> initProject({
    required String path,
    String? prefix,
  }) async {
    if (path.trim().isEmpty) _invalid('项目路径不能为空');
    final resolvedPrefix = prefix ?? _basename(path);
    _validatePrefix(resolvedPrefix);
    final directory = Directory(path);
    await directory.create(recursive: true);
    final file = File(_join(path, 'ghostcontainer.toml'));
    if (await file.exists()) {
      throw GcmException(
        GcmErrorCode.conflict,
        '项目配置已存在：${file.path}',
        hint: '请直接编辑现有 ghostcontainer.toml，或选择新目录。',
      );
    }
    await file.writeAsString('prefix = "$resolvedPrefix"\n', flush: true);
    _projectPaths.add(path);
    return ProjectInitResult(path: path, prefix: resolvedPrefix);
  }

  Future<List<ProjectSummary>> listProjects() async {
    final containers = await _containerService.listContainers(
      const ContainerQuery(),
    );
    final tomlProjects = await _discoverTomlProjects();
    final known = <String>{
      ...tomlProjects.keys,
      ...containers.map((c) => c.labels[projectLabel]).whereType<String>(),
    };
    final images = await _imageInventory(known);
    final names = <String>{
      ...known.where(_isValidPrefix),
      ...images.map((image) => image.project),
    };
    final result = <ProjectSummary>[];
    for (final name in names.toList()..sort()) {
      final projectImages =
          images
              .where((image) => image.project == name)
              .map((image) => image.info.reference)
              .toList()
            ..sort();
      result.add(
        ProjectSummary(
          project: name,
          path: tomlProjects[name],
          images: List<String>.unmodifiable(projectImages),
          containers: containers
              .where((c) => c.labels[projectLabel] == name)
              .length,
        ),
      );
    }
    return List<ProjectSummary>.unmodifiable(result);
  }

  Future<ProjectDetails> getProject({String? project, String? path}) async {
    final resolved = await _resolveProject(project: project, path: path);
    final containers = await _containerService.listContainers(
      const ContainerQuery(),
    );
    final members = containers
        .where((c) => c.labels[projectLabel] == resolved.project)
        .toList(growable: false);
    final images = await _imageInventory(<String>{resolved.project});
    final projectImages = images
        .where((image) => image.project == resolved.project)
        .toList(growable: false);
    if (resolved.path == null && members.isEmpty && projectImages.isEmpty) {
      throw GcmException(
        GcmErrorCode.notFound,
        '项目 ${resolved.project} 不存在',
        hint: '可通过 project_list 查看项目，或用 path 初始化目录。',
      );
    }
    final statuses = projectImages
        .map(
          (record) => ProjectImageStatus(
            reference: record.info.reference,
            sizeBytes: record.info.sizeBytes,
            createdAt: record.info.createdAt,
            inUse: containers.any((c) => c.image == record.info.reference),
          ),
        )
        .toList(growable: false);
    return ProjectDetails(
      project: resolved.project,
      path: resolved.path,
      images: statuses,
      containers: members,
    );
  }

  Future<ProjectBuildResult> buildProject({
    String? project,
    String? path,
    required String name,
    String? dockerfile,
    String? context,
    Map<String, String> buildArgs = const <String, String>{},
    bool skipTests = true,
    List<String>? testCommand,
    bool noCache = false,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    _validateImageName(name);
    if (!skipTests) {
      if (testCommand == null) {
        _invalid('skipTests=false 需要显式 testCommand；MCP 请改用 project_test。');
      }
      _validateTestCommand(testCommand);
    }
    final resolved = await _resolveProject(project: project, path: path);
    final stopwatch = Stopwatch()..start();
    return _withProjectLock(resolved.project, () async {
      if (resolved.path == null && context == null && dockerfile == null) {
        _invalid(
          '项目 ${resolved.project} 没有可用的项目目录',
          hint: '请使用 path 参数定位项目目录；应用重启后可能需要重新提供。',
        );
      }
      final basePath = resolved.path ?? context ?? '.';
      final actualDockerfile = dockerfile ?? _join(basePath, 'Dockerfile');
      await _validateDockerfile(actualDockerfile);
      final image = _projectImage(resolved.project, name);
      final args = <String>[
        'build',
        '-t',
        image,
        '--label',
        '$projectLabel=${resolved.project}',
        '-f',
        actualDockerfile,
        for (final entry
            in buildArgs.entries.toList()..sort(
              (a, b) => a.key.compareTo(b.key),
            )) ...['--build-arg', '${entry.key}=${entry.value}'],
        if (noCache) '--no-cache',
        '--progress',
        'plain',
        context ?? basePath,
      ];
      var stage = 'build';
      var outputLines = <String>[];
      var failureRecorded = false;
      try {
        final built = await _collectProcess(
          _cli.start(args),
          onProgress: onProgress,
          cancellation: cancellation,
        );
        outputLines = built.lines;
        if (built.cancelled) throw _cancelled('项目构建已取消');
        if (built.exitCode != 0) {
          final output = _lastLines(outputLines, 50);
          failureRecorded = true;
          final logPath = await _writeBuildFailure(
            project: resolved.project,
            name: name,
            dockerfile: actualDockerfile,
            stage: stage,
            reason: 'exit code ${built.exitCode}',
            lines: outputLines,
          );
          return ProjectBuildResult(
            project: resolved.project,
            image: image,
            exitCode: built.exitCode,
            durationMs: stopwatch.elapsedMilliseconds,
            output: output,
            failureLogPath: logPath,
          );
        }

        bool? testsPassed;
        String? failureOutput;
        String? failureLogPath;
        if (!skipTests && testCommand != null) {
          stage = 'test';
          final tested = await _runTestProcess(
            project: resolved.project,
            image: image,
            command: testCommand,
            cancellation: cancellation,
          );
          outputLines = <String>[...outputLines, ...tested.lines];
          if (tested.cancelled) throw _cancelled('项目构建测试已取消');
          testsPassed = tested.exitCode == 0;
          if (!testsPassed) {
            failureOutput = _lastLines(outputLines, 50);
            failureRecorded = true;
            failureLogPath = await _writeBuildFailure(
              project: resolved.project,
              name: name,
              dockerfile: actualDockerfile,
              stage: stage,
              reason: 'test exit code ${tested.exitCode}',
              lines: outputLines,
            );
          }
        }
        return ProjectBuildResult(
          project: resolved.project,
          image: image,
          exitCode: built.exitCode,
          durationMs: stopwatch.elapsedMilliseconds,
          testsPassed: testsPassed,
          output: failureOutput,
          failureLogPath: failureLogPath,
        );
      } catch (error) {
        if (!failureRecorded) {
          await _writeBuildFailure(
            project: resolved.project,
            name: name,
            dockerfile: actualDockerfile,
            stage: stage,
            reason: '$error',
            lines: outputLines,
          );
        }
        if (error is GcmException) rethrow;
        throw GcmException(
          GcmErrorCode.internal,
          '项目构建失败：$error',
          cause: error,
        );
      }
    });
  }

  Future<ProjectTestResult> testProject({
    String? project,
    String? path,
    required String name,
    required List<String> command,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    _validateImageName(name);
    _validateTestCommand(command);
    final resolved = await _resolveProject(project: project, path: path);
    final stopwatch = Stopwatch()..start();
    return _withProjectLock(resolved.project, () async {
      final image = _projectImage(resolved.project, name);
      final result = await _runTestProcess(
        project: resolved.project,
        image: image,
        command: command,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (result.cancelled) throw _cancelled('项目测试已取消');
      return ProjectTestResult(
        project: resolved.project,
        image: image,
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        truncated: result.stdoutTruncated || result.stderrTruncated,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    });
  }

  Future<ProjectPublishResult> publishProject({
    String? project,
    String? path,
    required String name,
    bool deleteLocal = false,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    _validateImageName(name);
    final resolved = await _resolveProject(project: project, path: path);
    return _withProjectLock(resolved.project, () async {
      final source = _projectImage(resolved.project, name);
      final target = '$localRegistryPrefix/$source';
      final inspection = await _imageService.inspect(source);
      await _runCli(<String>['image', 'tag', source, target]);
      final pushed = await _collectProcess(
        _cli.start(<String>['image', 'push', '--scheme', 'http', target]),
        onProgress: onProgress,
        cancellation: cancellation,
      );
      _ensureProcessSucceeded(pushed, '推送项目镜像');
      if (deleteLocal) {
        // Both names are local references. Removing only the project tag would
        // retain the same content through the registry tag and release nothing.
        await _runCli(<String>['image', 'delete', target]);
        await _runCli(<String>['image', 'delete', source]);
      }
      return ProjectPublishResult(
        project: resolved.project,
        pushed: <ProjectPushResult>[
          ProjectPushResult(
            source: source,
            target: target,
            sizeBytes: inspection.sizeBytes,
          ),
        ],
      );
    });
  }

  Future<ProjectRestoreResult> restoreProject({
    String? project,
    String? path,
    required String name,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    _validateImageName(name);
    final resolved = await _resolveProject(project: project, path: path);
    return _withProjectLock(resolved.project, () async {
      final reference = _projectImage(resolved.project, name);
      final remote = '$localRegistryPrefix/$reference';
      final pulled = await _collectProcess(
        _cli.start(<String>['image', 'pull', '--scheme', 'http', remote]),
        onProgress: onProgress,
        cancellation: cancellation,
      );
      _ensureProcessSucceeded(pulled, '拉回项目镜像');
      await _runCli(<String>['image', 'tag', remote, reference]);
      return ProjectRestoreResult(
        project: resolved.project,
        restored: <ProjectRestoredImage>[
          ProjectRestoredImage(reference: reference),
        ],
      );
    });
  }

  /// Reclaims project containers first, then rechecks fresh image references.
  /// Unlabelled lookalikes are never deletion candidates for this destructive
  /// operation; the naming fallback is only for discovery/restore.
  Future<ProjectReclaimReport> reclaimProject({
    String? project,
    String? path,
    bool dryRun = false,
  }) async {
    final resolved = await _resolveProject(project: project, path: path);
    return _withProjectLock(resolved.project, () async {
      final beforeBytes = await _diskUsageBytes();
      final initialContainers = await _containerService.listContainers(
        const ContainerQuery(),
      );
      final projectContainers =
          initialContainers
              .where((c) => c.labels[projectLabel] == resolved.project)
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      final stopped = <String>[];
      final deleted = <String>[];
      final failed = <String>[];
      final errors = <String>[];

      void recordContainerFailure(String id, Object error) {
        if (!failed.contains(id)) failed.add(id);
        errors.add('container $id: $error');
      }

      for (final container in projectContainers) {
        if (dryRun) {
          if (container.state != ContainerState.stopped) {
            stopped.add(container.id);
          }
          deleted.add(container.id);
          continue;
        }
        if (container.state != ContainerState.stopped) {
          try {
            await _containerService.stop(container.id);
            stopped.add(container.id);
          } on Object catch (error) {
            recordContainerFailure(container.id, error);
            continue;
          }
        }
        try {
          await _containerService.delete(container.id, force: true);
          deleted.add(container.id);
        } on Object catch (error) {
          recordContainerFailure(container.id, error);
        }
      }

      // This fresh read is the final authority, not the optimistic in-memory
      // activity snapshot used by the UI while writes were in flight.
      final freshContainers = dryRun
          ? initialContainers
          : await _containerService.listContainers(const ContainerQuery());
      final inventory = await _imageInventory(<String>{
        resolved.project,
      }, allowFallback: false);
      final candidates =
          inventory.where((image) => image.project == resolved.project).toList()
            ..sort((a, b) => a.info.reference.compareTo(b.info.reference));
      final deletedImages = <String>[];
      final retained = <ProjectRetainedImage>[];
      final skippedExternal = <ProjectExternalImage>[];
      for (final candidate in candidates) {
        final reference = candidate.info.reference;
        final projectUsers = <String>[];
        final externalUsers = <String>[];
        for (final container in freshContainers) {
          if (container.image != reference) continue;
          if (container.labels[projectLabel] == resolved.project) {
            projectUsers.add(container.id);
          } else {
            externalUsers.add(container.id);
          }
        }
        projectUsers.sort();
        externalUsers.sort();
        if (externalUsers.isNotEmpty) {
          skippedExternal.add(
            ProjectExternalImage(
              reference: reference,
              usedBy: List<String>.unmodifiable(externalUsers),
            ),
          );
          continue;
        }
        if (projectUsers.isNotEmpty) {
          retained.add(
            ProjectRetainedImage(reference: reference, reason: 'inUse.project'),
          );
          continue;
        }
        if (dryRun) {
          deletedImages.add(reference);
          continue;
        }
        try {
          await _runCli(<String>['image', 'delete', reference]);
          deletedImages.add(reference);
        } on Object catch (error) {
          errors.add('image $reference: $error');
        }
      }

      final afterBytes = dryRun ? beforeBytes : await _diskUsageBytes();
      return ProjectReclaimReport(
        project: resolved.project,
        stoppedContainers: List<String>.unmodifiable(stopped),
        deletedContainers: List<String>.unmodifiable(deleted),
        failedContainers: List<String>.unmodifiable(failed),
        deletedImages: List<String>.unmodifiable(deletedImages),
        retainedImages: List<ProjectRetainedImage>.unmodifiable(retained),
        skippedExternalImages: List<ProjectExternalImage>.unmodifiable(
          skippedExternal,
        ),
        disk: ProjectDiskReport(
          beforeBytes: beforeBytes,
          afterBytes: afterBytes,
          reclaimedBytes: beforeBytes > afterBytes
              ? beforeBytes - afterBytes
              : 0,
        ),
        errors: List<String>.unmodifiable(errors),
      );
    });
  }

  Future<int> _diskUsageBytes() async {
    final result = await _runCli(<String>['system', 'df', '--format', 'json']);
    try {
      final bytes = _readDfSizes(jsonDecode(result.stdout));
      if (bytes == null) throw const FormatException('missing size');
      return bytes;
    } on FormatException catch (error) {
      throw GcmException(
        GcmErrorCode.internal,
        '无法解析 container system df 的 JSON 输出。',
        source: 'cli',
        cause: error,
      );
    }
  }

  static int? _readDfSizes(Object? node) {
    if (node is List) {
      var total = 0;
      var found = false;
      for (final item in node) {
        final value = _readDfSizes(item);
        if (value != null) {
          total += value;
          found = true;
        }
      }
      return found ? total : null;
    }
    if (node is Map) {
      for (final key in const <String>['sizeBytes', 'size']) {
        final raw = node[key];
        final value = raw is num ? raw : num.tryParse('$raw');
        if (value != null && value >= 0) return value.toInt();
      }
      var total = 0;
      var found = false;
      for (final item in node.values) {
        final value = _readDfSizes(item);
        if (value != null) {
          total += value;
          found = true;
        }
      }
      return found ? total : null;
    }
    return null;
  }

  Future<BridgeCommandResult> _runCli(
    List<String> args, {
    Duration? timeout,
  }) async {
    final result = await _cli.run(args, timeout: timeout);
    if (result.timedOut && result.exitCode == -1) {
      throw GcmException(
        GcmErrorCode.timeout,
        'container ${args.join(' ')} 超时',
        hint: '运行时可能卡住；重试或检查 container CLI 日志。',
        source: 'cli',
        cause: result.combinedOutput,
      );
    }
    if (result.exitCode != 0) {
      _throwCliFailure('container ${args.join(' ')}', result.stderr);
    }
    return result;
  }

  static void _ensureProcessSucceeded(
    _CliProcessResult result,
    String operation,
  ) {
    if (result.cancelled) throw _cancelled('$operation已取消');
    if (result.exitCode != 0) {
      _throwCliFailure(operation, result.stderr);
    }
  }

  static Never _throwCliFailure(String operation, String stderr) =>
      throw GcmException(
        GcmErrorCode.internal,
        '$operation失败${stderr.trim().isEmpty ? '' : '：${stderr.trim()}'}',
        hint: '检查本地 registry、镜像引用及 container CLI 日志。',
        source: 'cli',
        cause: stderr,
      );

  Future<_CliProcessResult> _runTestProcess({
    required String project,
    required String image,
    required List<String> command,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) {
    return _collectProcess(
      _cli.start(<String>[
        'run',
        '--rm',
        '--label',
        '$projectLabel=$project',
        '--label',
        '$projectTestRoleLabel=test',
        image,
        ...command,
      ]),
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  static Future<_CliProcessResult> _collectProcess(
    ProjectCliProcess process, {
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    final lines = ListQueue<String>();
    final stdout = _BoundedOutput();
    final stderr = _BoundedOutput();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    var cancelled = false;
    var exited = false;
    const progressInterval = Duration(milliseconds: 100);
    Timer? progressTimer;
    String? pendingProgress;
    var progressWindowOpen = false;

    void emitProgress(String line) {
      final callback = onProgress;
      if (callback == null) return;
      if (progressWindowOpen) {
        pendingProgress = line;
        return;
      }
      callback(line);
      progressWindowOpen = true;
      progressTimer = Timer(progressInterval, () {
        progressWindowOpen = false;
        progressTimer = null;
        final pending = pendingProgress;
        if (pending != null) {
          pendingProgress = null;
          emitProgress(pending);
        }
      });
    }

    void flushProgress() {
      progressTimer?.cancel();
      progressTimer = null;
      progressWindowOpen = false;
      final pending = pendingProgress;
      pendingProgress = null;
      if (pending != null) onProgress?.call(pending);
    }

    void addLine(String line, _BoundedOutput target) {
      lines.addLast(line);
      while (lines.length > 1000) {
        lines.removeFirst();
      }
      target.addLine(line);
      emitProgress(line);
    }

    final stdoutSubscription = process.stdoutLines.listen(
      (line) => addLine(line, stdout),
      onError: (Object error, StackTrace stackTrace) {
        if (!stdoutDone.isCompleted) {
          stdoutDone.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
    );
    final stderrSubscription = process.stderrLines.listen(
      (line) => addLine(line, stderr),
      onError: (Object error, StackTrace stackTrace) {
        if (!stderrDone.isCompleted) {
          stderrDone.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
    );
    final cancellationSubscription = cancellation?.listen((_) {
      if (!cancelled && !exited) {
        cancelled = true;
        process.terminate();
      }
    });
    try {
      final exitCode = await process.exitCode;
      exited = true;
      await Future.wait<void>(<Future<void>>[
        stdoutDone.future,
        stderrDone.future,
      ]);
      return _CliProcessResult(
        exitCode: exitCode,
        lines: List<String>.unmodifiable(lines),
        stdout: stdout.text,
        stderr: stderr.text,
        stdoutTruncated: stdout.truncated,
        stderrTruncated: stderr.truncated,
        cancelled: cancelled,
      );
    } finally {
      flushProgress();
      await cancellationSubscription?.cancel();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
  }

  Future<String?> _writeBuildFailure({
    required String project,
    required String name,
    required String dockerfile,
    required String stage,
    required String reason,
    required List<String> lines,
  }) async {
    try {
      return await _buildLogStore.write(
        project: project,
        imageName: name,
        dockerfile: dockerfile,
        stage: stage,
        reason: reason,
        logTail: _lastLines(lines, 1000),
      );
    } catch (_) {
      // Failure diagnostics must not replace the original build result/error.
      return null;
    }
  }

  Future<T> _withProjectLock<T>(
    String project,
    Future<T> Function() action,
  ) async {
    if (!_lockedProjects.add(project)) {
      throw GcmException(
        GcmErrorCode.conflict,
        '项目 $project 已有工作流在执行',
        hint: '同一项目的 build/test/reclaim/publish 不能并行，请稍后重试。',
      );
    }
    try {
      return await action();
    } finally {
      _lockedProjects.remove(project);
    }
  }

  static Future<void> _validateDockerfile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw GcmException(
        GcmErrorCode.notFound,
        'Dockerfile 不存在：$path',
        hint: '请检查 path、context 或 dockerfile 参数。',
      );
    }
    if (await file.length() > 16 * 1024) {
      _invalid('Dockerfile 超过 16 KiB 上限：$path', hint: '上游限制为 16 KiB。');
    }
  }

  static void _validateImageName(String name) {
    if (!_isValidPrefix(name)) {
      _invalid('非法镜像自定义名：$name', hint: '仅传名称，不要带项目、tag、digest 或 registry。');
    }
  }

  static void _validateTestCommand(List<String> command) {
    if (command.isEmpty) _invalid('project_test 必须显式提供 command');
  }

  static String _projectImage(String project, String name) =>
      '$project-$name:latest';

  static GcmException _cancelled(String message) =>
      GcmException(GcmErrorCode.internal, message, hint: 'CLI 进程已终止，可稍后重试。');

  static String _lastLines(List<String> lines, int limit) {
    if (lines.isEmpty) return '';
    final start = lines.length > limit ? lines.length - limit : 0;
    return '${lines.sublist(start).join('\n')}\n';
  }

  // Discovery helpers remain below; workflow operations all use the same
  // label-authoritative project resolution.

  Future<({String project, String? path})> _resolveProject({
    String? project,
    String? path,
  }) async {
    if ((project == null) == (path == null)) {
      _invalid('project 与 path 必须且只能提供一项');
    }
    if (path != null) {
      final prefix = await _readPrefix(path);
      return (project: prefix, path: path);
    }
    _validatePrefix(project!);
    final discovered = await _discoverTomlProjects();
    return (project: project, path: discovered[project]);
  }

  Future<Map<String, String>> _discoverTomlProjects() async {
    final candidates = <String>{};
    for (final root in _projectPaths) {
      final rootFile = File(_join(root, 'ghostcontainer.toml'));
      if (await rootFile.exists()) candidates.add(root);
      final directory = Directory(root);
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (await File(_join(entity.path, 'ghostcontainer.toml')).exists()) {
          candidates.add(entity.path);
        }
      }
    }
    final result = <String, String>{};
    for (final path in candidates.toList()..sort()) {
      try {
        final prefix = await _readPrefix(path);
        result.putIfAbsent(prefix, () => path);
      } on GcmException {
        // Discovery is best-effort; an explicit path still reports bad TOML.
      }
    }
    return result;
  }

  Future<String> _readPrefix(String path) async {
    final file = File(_join(path, 'ghostcontainer.toml'));
    final String source;
    try {
      source = await file.readAsString();
    } on FileSystemException catch (error) {
      throw GcmException(
        GcmErrorCode.notFound,
        '项目配置不存在：${file.path}',
        hint: '先运行 project_init，或改用显式 project 参数。',
        cause: error,
      );
    }
    String? prefix;
    for (final rawLine in source.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = RegExp(r'^prefix\s*=\s*"([^"]*)"$').firstMatch(line);
      if (match == null || prefix != null) {
        _invalid('ghostcontainer.toml 只允许一个 prefix 字段：${file.path}');
      }
      prefix = match[1];
    }
    if (prefix == null) _invalid('ghostcontainer.toml 缺少 prefix：${file.path}');
    _validatePrefix(prefix);
    return prefix;
  }

  Future<List<_ProjectImageRecord>> _imageInventory(
    Set<String> knownProjects, {
    bool allowFallback = true,
  }) async {
    final images = await _imageService.listImages();
    final result = <_ProjectImageRecord>[];
    for (final image in images) {
      var labels = const <String, String>{};
      if (!image.isDangling) {
        // Inspecting an untagged image by name would resolve the wrong tag.
        labels = (await _imageService.inspect(image.reference)).labels;
      }
      final labelProject = labels[projectLabel];
      final project = labelProject != null
          ? (_isValidPrefix(labelProject) ? labelProject : null)
          : allowFallback
          ? _fallbackProject(image.reference, knownProjects)
          : null;
      if (project == null) continue;
      result.add(_ProjectImageRecord(info: image, project: project));
    }
    return result;
  }

  String? _fallbackProject(String reference, Set<String> knownProjects) {
    final nameWithRegistry = splitImageReference(reference).name;
    final name = nameWithRegistry.split('/').last;
    final known = knownProjects.where(_isValidPrefix).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final project in known) {
      if (name.startsWith('$project-') && name.length > project.length + 1) {
        return project;
      }
    }
    // Unlabelled restored images have no separate project registry. The first
    // separator is a bounded discovery heuristic; an explicit project always
    // uses the full longest-prefix check above.
    final separator = name.indexOf('-');
    if (separator <= 0 || separator == name.length - 1) return null;
    final candidate = name.substring(0, separator);
    return _isValidPrefix(candidate) ? candidate : null;
  }

  static bool _isValidPrefix(String value) =>
      RegExp(r'^[a-z0-9][a-z0-9.-]{0,126}$').hasMatch(value);

  static void _validatePrefix(String value) {
    if (!_isValidPrefix(value)) {
      _invalid('非法项目 prefix：$value', hint: '须匹配 [a-z0-9][a-z0-9.-]{0,126}。');
    }
  }

  static Never _invalid(String message, {String? hint}) =>
      throw GcmException(GcmErrorCode.invalidArgument, message, hint: hint);

  static String _basename(String path) {
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    return trimmed.split('/').last;
  }

  static String _join(String root, String child) => child.startsWith('/')
      ? child
      : '${root.replaceAll(RegExp(r"/+$"), '')}/$child';
}

class _ProjectImageRecord {
  const _ProjectImageRecord({required this.info, required this.project});

  final ImageInfo info;
  final String project;
}

class _CliProcessResult {
  const _CliProcessResult({
    required this.exitCode,
    required this.lines,
    required this.stdout,
    required this.stderr,
    required this.stdoutTruncated,
    required this.stderrTruncated,
    required this.cancelled,
  });

  final int exitCode;
  final List<String> lines;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;
  final bool stderrTruncated;
  final bool cancelled;
}

class _BoundedOutput {
  static const _limit = maxProjectOutputBytes;

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  var _totalBytes = 0;

  void addLine(String line) {
    _addBytes(utf8.encode(line));
    _addBytes(utf8.encode('\n'));
  }

  void _addBytes(List<int> bytes) {
    _totalBytes += bytes.length;
    final remaining = _limit - _bytes.length;
    if (remaining <= 0) return;
    _bytes.add(bytes.length <= remaining ? bytes : bytes.sublist(0, remaining));
  }

  bool get truncated => _totalBytes > _limit;

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}
