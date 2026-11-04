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
/// Recovery never recreates or deletes a container, and does not retry an
/// uncertain start.
class DirectoryContainerRecovery {
  DirectoryContainerRecovery({
    required DirectoryRegistry registry,
    required ContainerBridge bridge,
    required Future<void> Function() refresh,
  }) : _registry = registry,
       _identity = ContainerRuntimeIdentityService(bridge),
       _refresh = refresh;

  final DirectoryRegistry _registry;
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
        shouldStart: start,
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
        try {
          await _registry.recordIntentFailure(
            operationId,
            CreationFailureStage.create,
          );
        } catch (storageError) {
          return DirectoryCreationResult(
            operationId: operationId,
            status: DirectoryCreationStatus.unknown,
            stage: DirectoryCreationStage.storage,
            error: (error, storageError),
          );
        }
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
      try {
        return await _recoverLocked((await _registry.readIntent(operationId))!);
      } catch (error) {
        return DirectoryCreationResult(
          operationId: operationId,
          containerId: id,
          status: DirectoryCreationStatus.failed,
          stage: DirectoryCreationStage.storage,
          error: error,
        );
      }
    });
  }

  Future<DirectoryCreationResult> recover(
    String operationId, {
    String? expectedContainerId,
  }) => _registry.withIntentLock(operationId, () async {
    final intent = await _registry.readIntent(operationId);
    if (intent == null) throw StateError('Unknown creation intent');
    return _recoverLocked(intent, expectedContainerId: expectedContainerId);
  });

  /// Explicit retry: re-check identity by full ID under the same operation lock.
  Future<DirectoryCreationResult> retryStart(String operationId) =>
      _registry.withIntentLock(operationId, () async {
        final intent = await _registry.readIntent(operationId);
        if (intent == null) throw StateError('Unknown creation intent');
        return _recoverLocked(intent);
      });

  Future<DirectoryCreationResult> _recoverLocked(
    CreationIntent intent, {
    String? expectedContainerId,
  }) async {
    final operationId = intent.operationId;
    if (intent.containerId != null &&
        expectedContainerId != null &&
        intent.containerId != expectedContainerId) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: intent.containerId,
        status: DirectoryCreationStatus.conflict,
        stage: DirectoryCreationStage.identity,
      );
    }
    final knownId = intent.containerId ?? expectedContainerId;
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
    // A prepared intent does not prove the original request has terminated.
    // A unique match, including an externally supplied ID, cannot establish
    // quiescence after a timeout or a process restart. Do not register or start.
    if (intent.phase == CreationPhase.prepared) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: match.fullId,
        status: DirectoryCreationStatus.unknown,
        stage: DirectoryCreationStage.create,
      );
    }
    try {
      if (intent.phase == CreationPhase.created) {
        intent = await _registry.advanceIntent(
          operationId,
          CreationPhase.registered,
          containerId: match.fullId,
        );
      }
    } catch (error) {
      Object reported = error;
      if (intent.phase == CreationPhase.created) {
        try {
          await _registry.recordIntentFailure(
            operationId,
            CreationFailureStage.register,
          );
        } catch (storageError) {
          reported = (error, storageError);
        }
      }
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: match.fullId,
        status: DirectoryCreationStatus.failed,
        stage: DirectoryCreationStage.storage,
        error: reported,
      );
    }
    final id = match.fullId;
    if (intent.phase == CreationPhase.completed) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: id,
        status: DirectoryCreationStatus.registered,
      );
    }
    if (intent.shouldStart == null) {
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: id,
        status: DirectoryCreationStatus.unknown,
        stage: DirectoryCreationStage.start,
      );
    }
    if (intent.phase == CreationPhase.registered &&
        intent.shouldStart == true) {
      if (intent.failureStage == CreationFailureStage.start) {
        // Even a running observation cannot prove a prior start request has
        // terminated: another actor may have started the same container.
        return DirectoryCreationResult(
          operationId: operationId,
          containerId: id,
          status: DirectoryCreationStatus.unknown,
          stage: DirectoryCreationStage.start,
        );
      } else {
        // This durable sentinel is written before issuing start. A crash after
        // the write is indistinguishable from a request still in flight.
        try {
          await _registry.recordIntentFailure(
            operationId,
            CreationFailureStage.start,
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
        try {
          await _identity.start(
            fullId: id,
            runtimeName: intent.runtimeName,
            operationId: operationId,
          );
        } catch (error) {
          return DirectoryCreationResult(
            operationId: operationId,
            containerId: id,
            status: DirectoryCreationStatus.unknown,
            stage: DirectoryCreationStage.start,
            error: error,
          );
        }
      }
      try {
        intent = await _registry.advanceIntent(
          operationId,
          CreationPhase.started,
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
    }
    try {
      await _refresh();
    } catch (error) {
      try {
        await _registry.recordIntentFailure(
          operationId,
          CreationFailureStage.refresh,
        );
      } catch (storageError) {
        return DirectoryCreationResult(
          operationId: operationId,
          containerId: id,
          status: DirectoryCreationStatus.failed,
          stage: DirectoryCreationStage.storage,
          error: (error, storageError),
        );
      }
      return DirectoryCreationResult(
        operationId: operationId,
        containerId: id,
        status: DirectoryCreationStatus.failed,
        stage: DirectoryCreationStage.refresh,
        error: error,
      );
    }
    try {
      await _registry.advanceIntent(
        operationId,
        CreationPhase.completed,
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
    return DirectoryCreationResult(
      operationId: operationId,
      containerId: id,
      status: DirectoryCreationStatus.registered,
    );
  }
}
