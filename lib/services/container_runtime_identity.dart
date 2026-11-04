import 'dart:convert';

import '../bridge/container_bridge.dart';

/// Internal primitives for future directory creation/recovery. Labels are
/// consistency markers, not authorization or evidence of ownership.
class ContainerRuntimeIdentityService {
  ContainerRuntimeIdentityService(this._bridge);

  static const productLabel = 'com.ghost233.gcm.managed';
  static const operationLabel = 'com.ghost233.gcm.create-operation';
  static final _fullId = RegExp(r'^[0-9a-f]{64}$');
  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');
  final ContainerBridge _bridge;

  Future<BridgeCommandResult> _run(List<String> arguments) {
    final bridge = _bridge;
    if (bridge is! CompleteOutputContainerBridge) {
      throw const BridgeCallException(
        'Runtime bridge cannot establish output completeness',
      );
    }
    return (bridge as CompleteOutputContainerBridge).cliRunForIdentity(
      arguments,
    );
  }

  /// This does not persist an intent or register ownership. Failures, including
  /// malformed successful output, leave the runtime outcome unknown.
  Future<CreatedRuntimeContainer> create({
    required String businessName,
    required String runtimeName,
    required String operationId,
    required String image,
    Map<String, String> labels = const {},
    List<String> arguments = const [],
  }) async {
    _validateName(businessName);
    _validateName(runtimeName);
    _validateOperation(operationId);
    if (image.trim().isEmpty ||
        labels.containsKey(productLabel) ||
        labels.containsKey(operationLabel)) {
      throw ArgumentError('Invalid image or reserved container label');
    }
    final result = await _run([
      'container',
      'create',
      '--name',
      runtimeName,
      '--label',
      '$productLabel=true',
      '--label',
      '$operationLabel=$operationId',
      for (final entry in labels.entries) ...[
        '--label',
        '${entry.key}=${entry.value}',
      ],
      image,
      ...arguments,
    ]);
    _check(result, 'create');
    final id = result.stdout.trim();
    if (!_fullId.hasMatch(id)) {
      throw const BridgeCallException(
        'Create returned an invalid full container ID; outcome unknown',
      );
    }
    return CreatedRuntimeContainer(
      businessName: businessName,
      runtimeName: runtimeName,
      fullId: id,
    );
  }

  /// A fresh runtime query, independent of the UI refresh cache. Success means
  /// the list and every subsequent inspection completed; concurrent runtime
  /// mutations and in-flight create requests are not ruled out by this result.
  Future<RuntimeContainerQuery> queryOperation(String operationId) async {
    _validateOperation(operationId);
    final result = await _run([
      'container',
      'ls',
      '--all',
      '--quiet',
      '--no-trunc',
      '--filter',
      'label=$operationLabel=$operationId',
    ]);
    _check(result, 'query');
    final ids = result.stdout
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (ids.any((id) => !_fullId.hasMatch(id)) ||
        ids.toSet().length != ids.length) {
      throw const BridgeCallException(
        'Query returned invalid or duplicate full container IDs',
      );
    }
    final matches = <RuntimeContainerIdentity>[];
    for (final id in ids) {
      final identity = await inspect(id);
      if (identity.operationId != operationId) {
        throw const BridgeCallException(
          'Container operation label changed during query',
        );
      }
      matches.add(identity);
    }
    return RuntimeContainerQuery(List.unmodifiable(matches));
  }

  /// Inspects only an immutable full ID. Mismatched labels remain visible so a
  /// caller can report conflicts rather than silently discard candidates.
  Future<RuntimeContainerIdentity> inspect(String fullId) async {
    if (!_fullId.hasMatch(fullId)) {
      throw ArgumentError('Expected a full container ID');
    }
    final result = await _run(['container', 'inspect', fullId]);
    _check(result, 'inspect');
    Object? decoded;
    try {
      decoded = jsonDecode(result.stdout);
    } on FormatException {
      throw const BridgeCallException('Invalid container inspection JSON');
    }
    if (decoded is! List || decoded.length != 1 || decoded.single is! Map) {
      throw const BridgeCallException('Invalid container inspection result');
    }
    final raw = decoded.single as Map;
    final id = raw['Id'];
    final name = raw['Name'];
    final config = raw['Config'];
    final labels = config is Map ? config['Labels'] : null;
    if (id != fullId ||
        name is! String ||
        !name.startsWith('/') ||
        !_name.hasMatch(name.substring(1)) ||
        labels is! Map ||
        labels.keys.any((key) => key is! String) ||
        labels.values.any((value) => value is! String)) {
      throw const BridgeCallException(
        'Invalid or mismatched container identity',
      );
    }
    return RuntimeContainerIdentity(
      fullId: fullId,
      runtimeName: name.substring(1),
      labels: Map<String, String>.unmodifiable(labels.cast<String, String>()),
    );
  }

  static void _check(BridgeCommandResult result, String operation) {
    if (!result.ok || result.outputMayBeIncomplete) {
      throw BridgeCallException(
        'Container identity $operation failed${result.timedOut ? ' (timed out; outcome unknown)' : ''}${result.outputMayBeIncomplete ? ' (output may be incomplete)' : ''}: ${result.combinedOutput.trim()}',
      );
    }
  }

  static void _validateName(String value) {
    if (value.length > 63 || !_name.hasMatch(value)) {
      throw ArgumentError('Invalid container name');
    }
  }

  static void _validateOperation(String value) {
    if (value.isEmpty || value.length > 128 || !_name.hasMatch(value)) {
      throw ArgumentError('Invalid operation ID');
    }
  }
}

class CreatedRuntimeContainer {
  const CreatedRuntimeContainer({
    required this.businessName,
    required this.runtimeName,
    required this.fullId,
  });
  final String businessName;
  final String runtimeName;
  final String fullId;
}

class RuntimeContainerIdentity {
  const RuntimeContainerIdentity({
    required this.fullId,
    required this.runtimeName,
    required this.labels,
  });
  final String fullId;
  final String runtimeName;
  final Map<String, String> labels;
  String? get operationId =>
      labels[ContainerRuntimeIdentityService.operationLabel];
  bool get hasProductMarker =>
      labels[ContainerRuntimeIdentityService.productLabel] == 'true';

  bool matches({
    required String operationId,
    required String runtimeName,
    required String fullId,
  }) =>
      this.fullId == fullId &&
      this.runtimeName == runtimeName &&
      hasProductMarker &&
      this.operationId == operationId;
}

class RuntimeContainerQuery {
  const RuntimeContainerQuery(this.matches);
  final List<RuntimeContainerIdentity> matches;

  /// Failures throw instead of yielding an apparently complete empty result.
  bool get complete => true;
}
