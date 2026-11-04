// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import '../bridge/container_bridge.dart';
import 'container_runtime_identity.dart';
import 'directory_registry.dart';

/// Outcome of a directory creation or recovery. An unknown or conflict result
/// must never be interpreted as permission to recreate or remove a container.
enum DirectoryCreationStatus { registered, unknown, conflict, failed }

enum DirectoryCreationStage { create, query, identity, storage, start, refresh }

class DirectoryCreationResult {
  const DirectoryCreationResult({
    required this.operationId,
    required this.status,
    this.containerId,
    this.stage,
    this.error,
  });

  final String operationId;
  final DirectoryCreationStatus status;
  final String? containerId;
  final DirectoryCreationStage? stage;
  final Object? error;
}

/// Additive shared service; the legacy global container APIs are unchanged.
/// A recovery never issues another create, starts or deletes a container.
class DirectoryContainerRecovery {
  DirectoryContainerRecovery({
    required DirectoryRegistry registry,
    required ContainerBridge bridge,
    required Future<void> Function() refresh,
  }) : _registry = registry,
       _bridge = bridge,
       _identity = ContainerRuntimeIdentityService(bridge),
       _refresh = refresh;

  final DirectoryRegistry _registry;
  final ContainerBridge _bridge;
  final ContainerRuntimeIdentityService _identity;
  final Future<void> Function() _refresh;

  static String _operationId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// The generated operation ID and runtime name are never caller controlled.
  /// Intent persistence and the subsequent create share the recovery lock.
  Future<DirectoryCreationResult> create({
    required String directory,
    required String businessName,
    required String image,
    Map<String, String> labels = const {},
    List<String> arguments = const [],
    bool start = false,
  }) async {
    if (labels.containsKey(ContainerRuntimeIdentityService.productLabel) ||
        labels.containsKey(ContainerRuntimeIdentityService.operationLabel)) {
      throw ArgumentError('Reserved container label');
    }
    final operationId = _operationId();
    final runtimeName = 'gcm-$operationId';
    return _registry.withIntentLock(operationId, () async {
      if (await _registry.readIntent(operationId) != null) {
        throw StateError('Generated operation ID already exists');
      }
      final intent = await _registry.createIntent(
        operationId: operationId,
        directory: directory,
        businessName: businessName,
        runtimeName: runtimeName,
      );
      // Even a random collision must not cause a second create.
      if (intent.phase != CreationPhase.prepared) {
        return _recoverLocked(intent);
      }
      String id;
      try {
        id = (await _identity.create(
          businessName: businessName,
          runtimeName: runtimeName,
          operationId: operationId,
          image: image,
          labels: labels,
          arguments: arguments,
        )).fullId;
      } catch (error) {
        return DirectoryCreationResult(
          operationId: operationId,
          status: DirectoryCreationStatus.unknown,
          stage: DirectoryCreationStage.create,
          error: error,
        );
      }
      try {
        await _registry.advanceIntent(
          operationId,
          CreationPhase.created,
          containerId: id,
        );
      } catch (error) {
        return DirectoryCreationResult(
          operationId: operationId,
          containerId: id,
          status: DirectoryCreationStatus.failed,
          stage: DirectoryCreationStage.storage,
          error: error,
        );
      }
      final result = await _recoverLocked(
        (await _registry.readIntent(operationId))!,
      );
      if (result.status != DirectoryCreationStatus.registered) return result;
      if (start) return _startLocked(intent.operationId, id);
      return _refreshLocked(operationId, id);
    });
  }

  Future<DirectoryCreationResult> recover(String operationId) =>
      _registry.withIntentLock(operationId, () async {
        final intent = await _registry.readIntent(operationId);
        if (intent == null) throw StateError('Unknown creation intent');
        return _recoverLocked(intent);
      });

  /// Explicit retry: re-check identity by full ID under the same operation lock.
  Future<DirectoryCreationResult> retryStart(String operationId) =>
      _registry.withIntentLock(operationId, () async {
        final intent = await _registry.readIntent(operationId);
        if (intent == null) throw StateError('Unknown creation intent');
        if (intent.phase != CreationPhase.registered) {
          throw StateError('Container is not registered');
        }
        final result = await _recoverLocked(intent);
        if (result.status != DirectoryCreationStatus.registered) return result;
        return _startLocked(operationId, intent.containerId!);
      });

  Future<DirectoryCreationResult> _recoverLocked(CreationIntent intent) async {
    final operationId = intent.operationId;
    final knownId = intent.containerId;
    final RuntimeContainerQuery query;
    try {
      query = await _identity.queryOperation(operationId);
    } catch (error) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: knownId,
        status: DirectoryCreationStatus.unknown,
        stage: DirectoryCreationStage.query,
        error: error,
      );
    }
    if (query.matches.isEmpty) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: knownId,
        status: DirectoryCreationStatus.unknown,
        stage: DirectoryCreationStage.query,
      );
    }
    if (query.matches.length != 1) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: knownId,
        status: DirectoryCreationStatus.conflict,
        stage: DirectoryCreationStage.identity,
      );
    }
    final match = query.matches.single;
    if (!match.matches(
      operationId: operationId,
      runtimeName: intent.runtimeName,
      fullId: knownId ?? match.fullId,
    )) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: knownId,
        status: DirectoryCreationStatus.conflict,
        stage: DirectoryCreationStage.identity,
      );
    }
    try {
      if (intent.phase == CreationPhase.prepared) {
        intent = await _registry.advanceIntent(
          operationId,
          CreationPhase.created,
          containerId: match.fullId,
        );
      }
      if (intent.phase == CreationPhase.created) {
        await _registry.advanceIntent(
          operationId,
          CreationPhase.registered,
          containerId: match.fullId,
        );
      }
    } catch (error) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: match.fullId,
        status: DirectoryCreationStatus.failed,
        stage: DirectoryCreationStage.storage,
        error: error,
      );
    }
    return DirectoryCreationResult(
      operationId: operationId,
      containerId: match.fullId,
      status: DirectoryCreationStatus.registered,
    );
  }

  Future<DirectoryCreationResult> _startLocked(
    String operationId,
    String id,
  ) async {
    try {
      await _bridge.containerStart(id);
    } catch (error) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: id,
        status: DirectoryCreationStatus.failed,
        stage: DirectoryCreationStage.start,
        error: error,
      );
    }
    return _refreshLocked(operationId, id);
  }

  Future<DirectoryCreationResult> _refreshLocked(
    String operationId,
    String id,
  ) async {
    try {
      await _refresh();
    } catch (error) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: id,
        status: DirectoryCreationStatus.failed,
        stage: DirectoryCreationStage.refresh,
        error: error,
      );
    }
    return DirectoryCreationResult(
      operationId: operationId,
      containerId: id,
      status: DirectoryCreationStatus.registered,
    );
  }
}
