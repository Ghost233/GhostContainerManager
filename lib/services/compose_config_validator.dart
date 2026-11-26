library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../bridge/container_bridge.dart';
import 'errors.dart';

/// Local, non-executing Compose validation. The CLI never receives the original
/// pathname or a project directory with ambient .env/extends/include files.
class ComposeConfigValidator {
  const ComposeConfigValidator(this._bridge);

  final ContainerBridge _bridge;

  static const _maxInput = 128 * 1024;
  static const _maxNodes = 8192;
  static const _maxDepth = 24;
  static const _maxServices = 128;
  static const _forbidden = {
    'include',
    'extends',
    'env_file',
    'label_file',
    'provider',
    'credential_spec',
  };

  static final _serviceName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$');

  Future<Map<String, Object?>> validate(
    String path, {
    bool summary = false,
  }) async {
    final compose = await _readSnapshot(path);
    Directory? stage;
    try {
      stage = await Directory.systemTemp.createTemp('gcm-compose-config-');
      final snapshot = File('${stage.path}/compose.json');
      await snapshot.writeAsString(compose, flush: true);
      final response = await _bridge.composeRun([
        '--project-directory',
        stage.path,
        '--file',
        snapshot.path,
        '--env-file',
        '/dev/null',
        '--profile',
        '*',
        'config',
        '--no-interpolate',
        '--no-env-resolution',
        if (summary) ...['--format', 'json'] else '--quiet',
      ], timeout: const Duration(seconds: 8));
      if (response.timedOut) {
        throw const GcmException(
          GcmErrorCode.timeout,
          'Compose validation timed out.',
        );
      }
      if (!response.ok) {
        // Raw output can quote arbitrary YAML values or local paths.
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'Compose rejected the configuration, or the installed plugin does not support the required read-only flags.',
        );
      }
      if (!summary) return const {'valid': true};
      if (response.outputMayBeIncomplete ||
          utf8.encode(response.stdout).length > 512 * 1024) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'Compose summary exceeds the output limit.',
        );
      }
      return {'valid': true, 'services': _projection(response.stdout)};
    } on GcmException {
      rethrow;
    } on Object {
      throw const GcmException(
        GcmErrorCode.runtimeUnavailable,
        'Unable to run isolated Compose validation.',
      );
    } finally {
      if (stage != null) {
        try {
          await stage.delete(recursive: true);
        } on FileSystemException {
          throw const GcmException(
            GcmErrorCode.internal,
            'Unable to remove the private validation snapshot.',
          );
        }
      }
    }
  }

  static Future<String> _readSnapshot(String path) async {
    final file = File(path);
    try {
      if (!path.startsWith('/') ||
          !RegExp(r'^[a-zA-Z0-9_.-]+[.](?:yaml|yml|json)$')
              .hasMatch(file.uri.pathSegments.last) ||
          await file.resolveSymbolicLinks() != file.absolute.path ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FormatException();
      }
      final reader = await file.open();
      late final List<int> bytes;
      try {
        bytes = await reader.read(_maxInput + 1);
      } finally {
        await reader.close();
      }
      if (bytes.isEmpty || bytes.length > _maxInput) {
        throw const FormatException();
      }
      final input = loadYaml(utf8.decode(bytes));
      if (input is! YamlMap) throw const FormatException();
      var nodes = 0;

      Object? visit(Object? node, int depth) {
        if (++nodes > _maxNodes || depth > _maxDepth) {
          throw const FormatException();
        }
        if (node is YamlMap) {
          final out = <String, Object?>{};
          for (final entry in node.entries) {
            final key = entry.key;
            if (key is! String || _forbidden.contains(key)) {
              throw const FormatException();
            }
            out[key] = visit(entry.value, depth + 1);
          }
          return out;
        }
        if (node is YamlList) {
          return [for (final item in node) visit(item, depth + 1)];
        }
        if (node == null ||
            node is String ||
            node is bool ||
            node is int ||
            node is double && node.isFinite) {
          return node;
        }
        throw const FormatException();
      }

      final converted = visit(input, 0) as Map<String, Object?>;
      final services = converted['services'];
      if (services is! Map<String, Object?> ||
          services.isEmpty ||
          services.length > _maxServices) {
        throw const FormatException();
      }
      final encoded = jsonEncode(converted);
      if (utf8.encode(encoded).length > _maxInput) {
        throw const FormatException();
      }
      return encoded;
    } on Object {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        'Use an existing local Compose file without symlinks, external includes, extensions, or env/label files.',
      );
    }
  }

  static List<Map<String, Object?>> _projection(String json) {
    final result = jsonDecode(json);
    final services = result is Map<String, Object?> ? result['services'] : null;
    if (services is! Map<String, Object?> ||
        services.isEmpty ||
        services.length > _maxServices) {
      throw const FormatException();
    }
    final names = services.keys.toList()..sort();
    return [
      for (final name in names)
        if (_serviceName.hasMatch(name) &&
            services[name] is Map<String, Object?>)
          _service(name, services[name]! as Map<String, Object?>)
        else
          throw const FormatException(),
    ];
  }

  static Map<String, Object?> _service(
    String name,
    Map<String, Object?> entry,
  ) {
    final volumes = entry['volumes'];
    final binds = volumes is List<Object?>
        ? volumes.whereType<Map<String, Object?>>()
        : const <Map<String, Object?>>[];
    return {
      'service': name,
      'readOnlyRoot': entry['read_only'] == true,
      'networkDisabled': entry['network_mode'] == 'none',
      'neverPull': entry['pull_policy'] == 'never',
      'readOnlyBindCount': binds
          .where((v) => v['type'] == 'bind' && v['read_only'] == true)
          .length,
      'writableBindCount': binds
          .where((v) => v['type'] == 'bind' && v['read_only'] != true)
          .length,
    };
  }
}
