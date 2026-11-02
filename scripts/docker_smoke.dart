import 'dart:convert';
import 'dart:io';

import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/container_models.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/project_cleanup.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:ghost_container_manager/services/image_footprint_service.dart';
import 'package:ghost_container_manager/bridge/project_cli_adapter.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
  stdout.writeln('PASS $message');
}

Future<void> main() async {
  final bridge = DockerContainerBridge();
  final containers = ContainerService(bridge: bridge);
  final images = ImageService(bridge: bridge, containerService: containers);
  final compose = ComposeService(bridge: bridge, containerService: containers);
  final project = 'gcm-smoke-${DateTime.now().millisecondsSinceEpoch}';
  final directory = await Directory.systemTemp.createTemp('gcm-docker-smoke-');
  final file = File('${directory.path}/compose.json');
  final result = await bridge.cliRun([
    'image',
    'ls',
    'golang',
    '--no-trunc',
    '--format',
    '{{.ID}}',
  ]);
  final image = result.stdout.trim().split('\n').first;
  check(
    image.startsWith('sha256:'),
    'cached toolchain image selected without downloading',
  );
  await file.writeAsString(
    jsonEncode({
      'name': project,
      'services': {
        'test': {
          'image': image,
          'container_name': project,
          'pull_policy': 'never',
          'entrypoint': ['/bin/sh', '-c'],
          'command': ['echo gcm-smoke-started; sleep 300'],
          'labels': {'com.ghost233.project': project},
          'tmpfs': ['/tmp'],
        },
      },
    }),
  );
  final cleanup = ProjectCleanup(
    directory: '${directory.path}/resources',
    containers: containers,
    images: images,
  );
  try {
    check(
      (await SystemService(bridge: bridge).checkReadiness()).ready,
      'Docker endpoint readiness',
    );
    check(
      (await bridge.composeRun(['--file', file.path, 'config', '--quiet'])).ok,
      'standard Compose configuration',
    );
    check(
      (await compose.up(file: file.path, pull: 'never')).exitCode == 0,
      'Compose up detached with no pull',
    );
    final snapshot = await containers.inspect(project);
    check(
      snapshot.state == ContainerState.running &&
          snapshot.labels['com.docker.compose.project'] == project,
      'Docker inspect normalization and Compose labels',
    );
    final exec = await bridge.containerExec(
      id: project,
      command: [
        '/bin/sh',
        '-c',
        'printf smoke-ok; printf smoke-error >&2; exit 7',
      ],
    );
    check(
      exec.exitCode == 7 &&
          exec.stdout.trim() == 'smoke-ok' &&
          exec.stderr.trim() == 'smoke-error',
      'exec preserves streams and nonzero exit',
    );
    check(
      (await bridge.containerStats(project))['memoryLimitBytes'] != null,
      'Docker stats',
    );
    check(
      await ImageFootprintService(bridge: bridge)
              .containerDirectoryBytes(project) >=
          0,
      'engine writable-layer size',
    );
    final projects = ProjectService(
      cli: BridgeProjectCli(bridge),
      containerService: containers,
      imageService: images,
      resourceDirectory: '${directory.path}/resources',
      buildLogDirectory: '${directory.path}/logs',
    );
    check(
      await projects.diskUsageBytes() != null,
      'Docker system df JSON-lines parsing',
    );
    check(
      (await bridge.imageInspect(image))['digest'] == image,
      'image ID addressing',
    );
    await cleanup.record(
      project: project,
      kind: 'container',
      reference: project,
      purpose: 'migration smoke',
      temporary: true,
      resultsCollected: true,
    );
    final runningPlan = await cleanup.plan(project);
    check(
      (runningPlan['candidates'] as List).isEmpty,
      'cleanup retains running container',
    );
    await containers.stop(project);
    final plan = await cleanup.plan(project);
    final approved = (plan['candidates'] as List)
        .map((r) => r['id'] as String)
        .toList();
    check(approved.length == 1, 'cleanup plans stopped temporary container');
    final report = await cleanup.execute(
      project: project,
      planId: plan['planId'] as String,
      approved: approved,
    );
    check(
      (report['deleted'] as List).length == 1,
      'cleanup deletes only approved smoke resource',
    );
  } finally {
    await compose.down(file: file.path);
    await containers.dispose();
    await directory.delete(recursive: true);
  }
}
