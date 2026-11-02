/// Persistent project resource relationships and approval-bound cleanup.
library;

// Named public dependencies mirror the other service constructors.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'container_models.dart';
import 'container_service.dart';
import 'errors.dart';
import 'image_models.dart';
import 'image_service.dart';

const _projectLabel = 'com.ghost233.project';

class _Resource {
  _Resource(this.data);
  final Map<String, Object?> data;
  String get id => data['id'] as String;
  String get project => data['project'] as String;
  String get kind => data['kind'] as String;
  String get reference => data['reference'] as String;
  String get identity => data['identity'] as String;
  List<String> links(String key) => (data[key] as List).cast<String>();
}

class _CleanupPlan {
  _CleanupPlan(this.project, this.expiresAt, this.candidates);
  final String project;
  final DateTime expiresAt;
  final Map<String, String> candidates;
}

/// One shared instance serializes relationship writes and cleanup execution.
/// Runtime state remains authoritative; records describe intent, not liveness.
class ProjectCleanup {
  ProjectCleanup({
    this.directory,
    required ContainerService containers,
    required ImageService images,
    DateTime Function()? clock,
  }) : _containers = containers,
       _images = images,
       _clock = clock ?? DateTime.now;

  /// Null selects an isolated in-memory store for UI tests.
  final String? directory;
  final Map<String, List<_Resource>> _memory = {};
  final ContainerService _containers;
  final ImageService _images;
  final DateTime Function() _clock;
  final Map<String, _CleanupPlan> _plans = {};
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static void _project(String project) {
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,126}$').hasMatch(project)) {
      throw const GcmException(GcmErrorCode.invalidArgument, '非法项目名');
    }
  }

  static String _token() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<List<_Resource>> _read(String project) async {
    _project(project);
    if (directory == null) return [...?_memory[project]];
    final file = File('$directory/$project.json');
    if (!await file.exists()) return [];
    final rows = jsonDecode(await file.readAsString()) as List;
    final records = rows.map((row) {
      final data = (row as Map).cast<String, Object?>();
      if (data['project'] != project ||
          data['id'] is! String ||
          !['image', 'container'].contains(data['kind']) ||
          data['reference'] is! String ||
          data['identity'] is! String ||
          data['purpose'] is! String ||
          data['keep'] is! bool ||
          data['temporary'] is! bool ||
          data['resultsCollected'] is! bool) {
        throw const FormatException('Invalid project resource record');
      }
      for (final key in ['dependsOn', 'supersedes']) {
        if (data[key] is! List ||
            (data[key] as List).any((v) => v is! String)) {
          throw const FormatException('Invalid project resource relationships');
        }
      }
      return _Resource(data);
    }).toList();
    if (records.map((r) => r.id).toSet().length != records.length) {
      throw const FormatException('Duplicate project resource id');
    }
    return records;
  }

  Future<List<_Resource>> _all() async {
    if (directory == null) {
      return _memory.values.expand((rows) => rows).toList();
    }
    final dir = Directory(directory!);
    if (!await dir.exists()) return [];
    final result = <_Resource>[];
    await for (final file in dir.list(followLinks: false)) {
      if (file is File && file.path.endsWith('.json')) {
        final name = file.uri.pathSegments.last;
        result.addAll(await _read(name.substring(0, name.length - 5)));
      }
    }
    return result;
  }

  Future<void> _write(String project, List<_Resource> records) async {
    if (directory == null) {
      _memory[project] = [...records];
      return;
    }
    await Directory(directory!).create(recursive: true);
    final target = '$directory/$project.json';
    final temporary = File('$target.tmp');
    await temporary.writeAsString(
      jsonEncode(records.map((r) => r.data).toList()),
      flush: true,
    );
    await temporary.rename(target);
  }

  Future<Set<String>> projects() =>
      _serial(() async => (await _all()).map((r) => r.project).toSet());

  Future<List<Map<String, Object?>>> resources(String project) => _serial(
    () async =>
        (await _read(project))
            .map((r) => Map<String, Object?>.from(r.data))
            .toList(),
  );

  /// Explicit registration also adopts unlabelled resources. A conflicting
  /// project label is rejected; inferred names never grant cleanup permission.
  Future<Map<String, Object?>> record({
    required String project,
    required String kind,
    required String reference,
    required String purpose,
    String? taskId,
    List<String> dependsOn = const [],
    List<String> supersedes = const [],
    bool temporary = false,
    bool resultsCollected = false,
    bool keep = false,
  }) => _serial(() async {
    _project(project);
    if (!['container', 'image'].contains(kind) || purpose.trim().isEmpty) {
      throw const GcmException(GcmErrorCode.invalidArgument, '需要合法资源类型和非空用途');
    }
    final rows = await _read(project);
    final all = await _all();
    final linked = <String>{...dependsOn, ...supersedes};
    for (final id in linked) {
      final matches = all.where((r) => r.id == id).toList();
      if (matches.length != 1 ||
          (supersedes.contains(id) &&
              (matches.single.project != project ||
                  matches.single.kind != kind))) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          '关系目标不存在或不属于本项目同类资源',
        );
      }
    }
    String identity;
    String? owner;
    Map<String, Object?>? usesImage;
    final dependencies = dependsOn.toSet();
    if (kind == 'image') {
      final normalized = validateImageReference(reference).reference;
      if (normalized != reference) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          '请使用完整 name:tag',
        );
      }
      final matches = (await _images.listImages())
          .where((i) => i.reference == reference)
          .toList();
      if (matches.length != 1 || (matches.single.digest?.isEmpty ?? true)) {
        throw const GcmException(GcmErrorCode.notFound, '镜像不存在或缺少内容摘要');
      }
      identity = matches.single.digest!;
      owner = (await _images.inspect(reference)).labels[_projectLabel];
    } else {
      final container = await _containers.inspect(reference);
      if (container.createdAt == null) {
        throw const GcmException(GcmErrorCode.conflict, '容器缺少创建时间，无法绑定资源身份');
      }
      identity = container.createdAt!.toUtc().toIso8601String();
      owner = container.labels[_projectLabel];
      final raw = container.rawConfiguration['image'];
      final descriptor = raw is Map ? raw['descriptor'] : null;
      final digest = descriptor is Map ? descriptor['digest'] : null;
      usesImage = {
        'reference': container.image,
        if (digest is String) 'digest': digest,
      };
      if (digest is String) {
        dependencies.addAll(
          all
              .where((r) => r.kind == 'image' && r.identity == digest)
              .map((r) => r.id),
        );
        linked.addAll(dependencies);
      }
    }
    if (owner != null && owner != project) {
      throw const GcmException(GcmErrorCode.conflict, '资源已属于其他项目');
    }
    if (all.any(
      (r) =>
          r.kind == kind &&
          r.identity == identity &&
          r.reference == reference &&
          r.project != project,
    )) {
      throw const GcmException(GcmErrorCode.conflict, '资源已登记到其他项目');
    }
    final existing = rows
        .where(
          (r) =>
              r.kind == kind &&
              r.reference == reference &&
              r.identity == identity,
        )
        .firstOrNull;
    final id = existing?.id ?? _token();
    if (linked.contains(id)) {
      throw const GcmException(GcmErrorCode.invalidArgument, '资源不能依赖或替代自身');
    }
    // Edges point to existing records. Reject cycles on updates as well.
    bool reaches(String next, Set<String> visited) {
      if (next == id) return true;
      if (!visited.add(next)) return false;
      final row = all.where((r) => r.id == next).firstOrNull;
      return row != null &&
          [
            ...row.links('dependsOn'),
            ...row.links('supersedes'),
          ].any((link) => reaches(link, visited));
    }

    if (linked.any((link) => reaches(link, {}))) {
      throw const GcmException(GcmErrorCode.invalidArgument, '资源关系形成循环');
    }
    final data = <String, Object?>{
      'id': id,
      'project': project,
      'kind': kind,
      'reference': reference,
      'identity': identity,
      'purpose': purpose,
      'taskId': ?taskId,
      'dependsOn': dependencies.toList(),
      'usesImage': ?usesImage,
      'supersedes': supersedes.toSet().toList(),
      'temporary': temporary,
      'resultsCollected': resultsCollected,
      'keep': keep,
    };
    rows.removeWhere((r) => r.id == id);
    rows.add(_Resource(data));
    await _write(project, rows);
    return Map<String, Object?>.from(data);
  });

  Future<String?> _retention(_Resource row, List<_Resource> all) async {
    if (row.data['keep'] == true) return 'keep';
    if (row.data['temporary'] == true && row.data['resultsCollected'] != true) {
      return 'resultsPending';
    }
    var superseded = false;
    for (final replacement in all.where(
      (r) => r.project == row.project && r.links('supersedes').contains(row.id),
    )) {
      if (replacement.kind == 'image') {
        superseded = (await _images.listImages()).any(
          (i) =>
              i.reference == replacement.reference &&
              i.digest == replacement.identity,
        );
      } else {
        superseded = (await _containers.listContainers(const ContainerQuery()))
            .any(
              (c) =>
                  c.id == replacement.reference &&
                  c.createdAt?.toUtc().toIso8601String() ==
                      replacement.identity,
            );
      }
      if (superseded) break;
    }
    if (!superseded &&
        !(row.data['temporary'] == true &&
            row.data['resultsCollected'] == true)) {
      return 'notSuperseded';
    }
    final containers = await _containers.listContainers(const ContainerQuery());
    if (row.kind == 'container') {
      final live = containers.where((c) => c.id == row.reference).firstOrNull;
      if (live == null) return 'missing';
      if (live.createdAt?.toUtc().toIso8601String() != row.identity) {
        return 'identityChanged';
      }
      if (live.labels[_projectLabel] != null &&
          live.labels[_projectLabel] != row.project) {
        return 'ownerChanged';
      }
      if (live.state != ContainerState.stopped) return live.state.wireName;
    } else {
      final images = await _images.listImages();
      final live = images
          .where((i) => i.reference == row.reference)
          .firstOrNull;
      if (live == null) return 'missingOrUntagged';
      if (live.digest != row.identity) return 'identityChanged';
      if ((await _images.inspect(row.reference)).labels[_projectLabel]
          case final String owner when owner != row.project) {
        return 'ownerChanged';
      }
      final aliases =
          images
              .where((i) => i.digest == row.identity)
              .map((i) => i.reference)
              .toSet()
            ..add(row.reference);
      // A container's old tag may now resolve to different content. Its stored
      // descriptor, when present, remains authoritative. Unknown digests retain.
      for (final c in containers) {
        final image = c.rawConfiguration['image'];
        final descriptor = image is Map ? image['descriptor'] : null;
        final digest = descriptor is Map ? descriptor['digest'] : null;
        if (digest == row.identity || aliases.contains(c.image)) {
          return 'containerReference';
        }
        if (digest == null) return 'unknownContainerReference';
      }
    }
    if (all.any(
      (r) => r.id != row.id && r.links('dependsOn').contains(row.id),
    )) {
      return 'dependency';
    }
    return null;
  }

  Future<Map<String, Object?>> plan(String project) => _serial(() async {
    _project(project);
    final all = await _all();
    final candidates = <Map<String, Object?>>[];
    final retained = <Map<String, Object?>>[];
    for (final row in all.where((r) => r.project == project)) {
      final reason = await _retention(row, all);
      final item = <String, Object?>{
        ...row.data,
        'reason': reason ?? 'eligible',
        'dataEffect': row.kind == 'container'
            ? '删除容器可写层；宿主挂载数据保留'
            : '删除此镜像引用，共享层可能保留',
      };
      (reason == null ? candidates : retained).add(item);
    }
    _plans.removeWhere((_, p) => !_clock().isBefore(p.expiresAt));
    // At most one outstanding plan per project; a fresh plan replaces old intent.
    _plans.removeWhere((_, p) => p.project == project);
    final planId = _token();
    final expires = _clock().add(const Duration(minutes: 30));
    _plans[planId] = _CleanupPlan(project, expires, {
      for (final row in candidates)
        row['id'] as String: jsonEncode(
          all.singleWhere((r) => r.id == row['id']).data,
        ),
    });
    return {
      'project': project,
      'planId': planId,
      'expiresAt': expires.toUtc().toIso8601String(),
      'requiresApproval': true,
      'candidates': candidates,
      'retained': retained,
    };
  });

  Future<Map<String, Object?>> execute({
    required String project,
    required String planId,
    required List<String> approved,
  }) => _serial(() async {
    _project(project);
    final plan = _plans[planId];
    if (plan == null ||
        plan.project != project ||
        !_clock().isBefore(plan.expiresAt)) {
      throw const GcmException(
        GcmErrorCode.conflict,
        '清理计划不存在、已过期或不属于本项目，请重新获取',
      );
    }
    if (approved.isEmpty ||
        approved.toSet().length != approved.length ||
        approved.any((id) => !plan.candidates.containsKey(id))) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        '仅可批准计划中非空、不重复的候选 ID',
      );
    }
    // Consume before side effects: replay cannot broaden or repeat approval.
    _plans.remove(planId);
    final deleted = <String>[];
    final skipped = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    // Containers first; images are evaluated against fresh runtime references.
    final initial = await _read(project);
    final ids = [...approved]
      ..sort((a, b) {
        final ak = initial.where((r) => r.id == a).firstOrNull?.kind ?? '';
        final bk = initial.where((r) => r.id == b).firstOrNull?.kind ?? '';
        final order = ak.compareTo(bk);
        return order == 0 ? a.compareTo(b) : order;
      });
    for (final id in ids) {
      try {
        final all = await _all();
        final row = all
            .where((r) => r.id == id && r.project == project)
            .firstOrNull;
        String? reason;
        if (row == null || jsonEncode(row.data) != plan.candidates[id]) {
          reason = 'recordChanged';
        } else {
          reason = await _retention(row, all);
        }
        if (reason != null) {
          skipped.add({'id': id, 'reason': reason});
          continue;
        }
        if (row!.kind == 'container') {
          await _containers.delete(row.reference, force: false);
        } else {
          await _images.delete(row.reference);
        }
        // Persist before reporting success. Disk errors are returned explicitly.
        final remaining = await _read(project);
        remaining.removeWhere((r) => r.id == id);
        await _write(project, remaining);
        deleted.add(id);
      } on Object catch (error) {
        failed.add({'id': id, 'error': error.toString()});
      }
    }
    return {
      'project': project,
      'planId': planId,
      'deleted': deleted,
      'skipped': skipped,
      'failed': failed,
    };
  });
}
