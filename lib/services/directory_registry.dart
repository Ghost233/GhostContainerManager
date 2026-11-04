import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

// macOS flock locks open file descriptions, unlike process-scoped fcntl locks.
// Isolates can therefore contend safely even inside the same process.
final class _MacFileLock {
  static final _libc = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  static final _malloc = _libc
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  static final _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32),
        int Function(Pointer<Uint8>, int)
      >('open');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );

  static int acquire(String path) {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Directory registry locking requires macOS');
    }
    final bytes = utf8.encode(path);
    if (bytes.contains(0)) throw ArgumentError.value(path, 'path');
    final name = _malloc(bytes.length + 1);
    if (name == nullptr) throw StateError('Cannot allocate lock path');
    try {
      name.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      // O_RDWR | O_CLOEXEC. The lock file is created by Dart before this call;
      // open's variadic O_CREAT mode argument has a different arm64 ABI.
      final fd = _open(name, 0x01000002);
      if (fd < 0) _throwError('Cannot open lock file', path);
      if (_flock(fd, 2) != 0) {
        final error = _errno().value;
        _close(fd);
        throw FileSystemException(
          'Cannot acquire lock',
          path,
          OSError('', error),
        );
      }
      return fd;
    } finally {
      _free(name.cast());
    }
  }

  static void release(int fd, String path) {
    // close releases the flock even if an explicit unlock would fail.
    if (_close(fd) != 0) _throwError('Cannot close lock file', path);
  }

  static Never _throwError(String message, String path) {
    throw FileSystemException(message, path, OSError('', _errno().value));
  }
}

/// The last durably completed step; [completed] includes the final refresh.
enum CreationPhase { prepared, created, registered, started, completed }

/// The step that failed, without persisting error messages or runtime secrets.
enum CreationFailureStage { create, register, start, refresh }

/// Only recovery identity is stored; runtime configuration and secrets are not.
class CreationIntent {
  const CreationIntent({
    required this.operationId,
    required this.directory,
    required this.businessName,
    required this.runtimeName,
    required this.phase,
    this.containerId,
    this.shouldStart,
    this.failureStage,
  });

  final String operationId;
  final String directory;
  final String businessName;
  final String runtimeName;
  final CreationPhase phase;
  final String? containerId;

  /// Null means an old record whose start requirement is unknown.
  final bool? shouldStart;
  final CreationFailureStage? failureStage;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'directory': directory,
    'businessName': businessName,
    'runtimeName': runtimeName,
    'phase': phase.name,
    if (containerId != null) 'containerId': containerId,
    if (shouldStart != null) 'shouldStart': shouldStart,
    if (failureStage != null) 'failureStage': failureStage!.name,
  };

  static CreationIntent fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const {
            'operationId',
            'directory',
            'businessName',
            'runtimeName',
            'phase',
            'containerId',
            'shouldStart',
            'failureStage',
          }.contains(key),
        ) ||
        value['operationId'] is! String ||
        value['directory'] is! String ||
        value['businessName'] is! String ||
        value['runtimeName'] is! String ||
        value['phase'] is! String ||
        (value.containsKey('containerId') && value['containerId'] is! String) ||
        (value.containsKey('shouldStart') && value['shouldStart'] is! bool) ||
        (value.containsKey('failureStage') &&
            value['failureStage'] is! String)) {
      throw const FormatException('Invalid creation intent');
    }
    final phase = CreationPhase.values.where((p) => p.name == value['phase']);
    final id = value['containerId'] as String?;
    final start = value['shouldStart'] as bool?;
    final failureName = value['failureStage'];
    final failures = CreationFailureStage.values.where(
      (s) => s.name == failureName,
    );
    if (phase.length != 1 ||
        (failureName != null && failures.length != 1) ||
        (phase.isNotEmpty &&
            phase.single == CreationPhase.started &&
            start != true) ||
        (phase.isNotEmpty &&
            phase.single == CreationPhase.completed &&
            start == null) ||
        (phase.isNotEmpty &&
            failureName != null &&
            !_failureAllowed(phase.single, start, failures.single)) ||
        !_operationPattern.hasMatch(value['operationId'] as String) ||
        !(value['directory'] as String).startsWith('/') ||
        (value['businessName'] as String).isEmpty ||
        (value['runtimeName'] as String).isEmpty ||
        (phase.single == CreationPhase.prepared ? id != null : !_validId(id))) {
      throw const FormatException('Invalid creation intent');
    }
    return CreationIntent(
      operationId: value['operationId'] as String,
      directory: value['directory'] as String,
      businessName: value['businessName'] as String,
      runtimeName: value['runtimeName'] as String,
      phase: phase.single,
      containerId: id,
      shouldStart: start,
      failureStage: failureName == null ? null : failures.single,
    );
  }
}

bool _failureAllowed(
  CreationPhase phase,
  bool? start,
  CreationFailureStage failure,
) => switch (failure) {
  CreationFailureStage.create => phase == CreationPhase.prepared,
  CreationFailureStage.register => phase == CreationPhase.created,
  CreationFailureStage.start =>
    phase == CreationPhase.registered && start == true,
  CreationFailureStage.refresh =>
    (phase == CreationPhase.registered && start == false) ||
        (phase == CreationPhase.started && start == true),
};

final _operationPattern = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
final _containerPattern = RegExp(r'^[0-9a-f]{64}$');
bool _validId(String? id) => id != null && _containerPattern.hasMatch(id);

String? _resourceContainerId(String resource) {
  const prefix = 'container:';
  if (!resource.toLowerCase().startsWith(prefix)) return null;
  final id = resource.substring(prefix.length).toLowerCase();
  return _validId(id) ? id : null;
}

class _RegistryData {
  _RegistryData(this.entries, this.intents);
  final Map<String, List<String>> entries;
  final Map<String, CreationIntent> intents;

  Map<String, Object> toJson() => {
    'version': 1,
    'entries': entries,
    'intents': intents.map((key, value) => MapEntry(key, value.toJson())),
  };
}

// jsonDecode validates syntax first but discards repeated keys. Compare decoded
// key tokens within each object, keeping arrays and objects on an explicit stack.
void _rejectDuplicateKeys(String source) {
  final scopes = <Set<String>?>[];
  var i = 0;
  while (i < source.length) {
    final char = source.codeUnitAt(i);
    if (char == 0x22) {
      final start = i++;
      while (source.codeUnitAt(i) != 0x22) {
        if (source.codeUnitAt(i) == 0x5c) i++;
        i++;
      }
      i++;
      var next = i;
      while (next < source.length &&
          const [0x20, 0x09, 0x0a, 0x0d].contains(source.codeUnitAt(next))) {
        next++;
      }
      if (next < source.length && source.codeUnitAt(next) == 0x3a) {
        final key = jsonDecode(source.substring(start, i)) as String;
        if (!scopes.last!.add(key)) {
          throw const FormatException('Duplicate registry object key');
        }
      }
    } else {
      if (char == 0x7b) {
        scopes.add(<String>{});
      } else if (char == 0x5b) {
        scopes.add(null);
      } else if (char == 0x7d || char == 0x5d) {
        scopes.removeLast();
      }
      i++;
    }
  }
}

/// Shared management entry for explicit directory resource registrations.
/// [storage] is an application-owned file, not a file in the managed directory.
class DirectoryRegistry {
  DirectoryRegistry(this.storage);

  final File storage;
  static final Map<String, Future<void>> _locks = {};

  Future<String> _identity(String path) async {
    if (!path.startsWith('/')) throw ArgumentError.value(path, 'path');
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw ArgumentError.value(path, 'path', 'Must be an existing directory');
    }
    return directory.resolveSymbolicLinks();
  }

  Future<_RegistryData> _read() async {
    // Only a genuinely absent file is an empty registry; unreadable files fail.
    String contents;
    try {
      contents = await storage.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 &&
          await FileSystemEntity.type(storage.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        return _RegistryData({}, {});
      }
      rethrow;
    }
    final data = jsonDecode(contents);
    _rejectDuplicateKeys(contents);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid registry');
    }
    final Map<String, dynamic> rawEntries;
    final Map<String, dynamic> rawIntents;
    if (data.containsKey('version')) {
      if (data.length != 3 ||
          data['version'] != 1 ||
          data['entries'] is! Map<String, dynamic> ||
          data['intents'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid registry version');
      }
      rawEntries = data['entries'] as Map<String, dynamic>;
      rawIntents = data['intents'] as Map<String, dynamic>;
    } else {
      rawEntries = data;
      rawIntents = {};
    }
    final entries = rawEntries.map((key, value) {
      if (!key.startsWith('/') ||
          value is! List ||
          value.any((item) => item is! String)) {
        throw const FormatException('Invalid registry entry');
      }
      return MapEntry(key, value.cast<String>().toList());
    });
    final intents = rawIntents.map((key, value) {
      final intent = CreationIntent.fromJson(value);
      if (key != intent.operationId) {
        throw const FormatException('Invalid intent key');
      }
      return MapEntry(key, intent);
    });
    final owners = <String, String>{};
    for (final entry in entries.entries) {
      for (final resource in entry.value) {
        final id = _resourceContainerId(resource);
        if (id != null) {
          final previous = owners[id];
          if (previous != null && previous != entry.key) {
            throw const FormatException('Conflicting container ownership');
          }
          owners[id] = entry.key;
        }
      }
    }
    for (final intent in intents.values) {
      if (intent.phase.index >= CreationPhase.registered.index &&
          owners[intent.containerId] != intent.directory) {
        throw const FormatException('Missing registered container');
      }
    }
    return _RegistryData(entries, intents);
  }

  Future<T> _locked<T>(String suffix, Future<T> Function() action) async {
    await storage.parent.create(recursive: true);
    final key =
        '${await storage.parent.resolveSymbolicLinks()}/${storage.uri.pathSegments.last}$suffix';
    final previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[key] = done.future;
    try {
      await previous;
      // Create without truncating; flock's open file description is separate.
      final file = await File(key).open(mode: FileMode.append);
      await file.close();
      // flock may wait for another process or isolate. Never block the caller's
      // event loop; the returned descriptor remains owned by this operation.
      final fd = await Isolate.run(() => _MacFileLock.acquire(key));
      try {
        return await action();
      } finally {
        _MacFileLock.release(fd, key);
      }
    } finally {
      done.complete();
      if (identical(_locks[key], done.future)) _locks.remove(key);
    }
  }

  // Flush before atomic replacement protects process-restart recovery from
  // partial JSON. This does not promise survival of OS crash or power loss:
  // the containing directory and its creation are not synchronously flushed.
  Future<void> _write(_RegistryData data) async {
    final temp = await storage.parent.createTemp('.directory-registry-');
    try {
      final file = File('${temp.path}/registry');
      await file.writeAsString(jsonEncode(data.toJson()), flush: true);
      await file.rename(storage.path);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<List<String>> query(String path) async {
    final identity = await _identity(path);
    return List.unmodifiable((await _read()).entries[identity] ?? <String>[]);
  }

  /// Registers a full Docker container ID using the ownership-aware encoding.
  Future<void> registerContainer(String path, String containerId) {
    if (!_validId(containerId)) {
      throw ArgumentError.value(containerId, 'containerId');
    }
    return register(path, 'container:$containerId');
  }

  /// Legacy opaque resources remain supported. Only `container:<full-id>`
  /// represents container ownership; other strings have no inferred type.
  Future<void> register(String path, String resource) async {
    final identity = await _identity(path);
    await _locked('.lock', () async {
      final data = await _read();
      _register(data, identity, resource);
      await _write(data);
    });
  }

  void _register(_RegistryData data, String identity, String resource) {
    final id = _resourceContainerId(resource);
    if (id != null) {
      for (final entry in data.entries.entries) {
        if (entry.key != identity &&
            entry.value.any((item) => _resourceContainerId(item) == id)) {
          throw StateError('Container already belongs to another directory');
        }
      }
    }
    final resources = data.entries.putIfAbsent(identity, () => <String>[]);
    if (id != null &&
        resources.any((item) => _resourceContainerId(item) == id)) {
      return;
    }
    if (!resources.contains(resource)) resources.add(resource);
  }

  /// Call around a whole completion/recovery operation, including runtime checks.
  /// Do not nest this lock for the same operation ID.
  Future<T> withIntentLock<T>(String operationId, Future<T> Function() action) {
    if (!_operationPattern.hasMatch(operationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    return _locked('.intent-$operationId.lock', action);
  }

  /// Snapshot of unfinished operations, including those requiring inspection.
  /// Recovery must re-read each intent under [withIntentLock] before acting.
  Future<List<CreationIntent>> pendingIntents() async {
    final intents =
        (await _read()).intents.values
            .where((intent) => intent.phase != CreationPhase.completed)
            .toList()
          ..sort((a, b) => a.operationId.compareTo(b.operationId));
    return List.unmodifiable(intents);
  }

  Future<CreationIntent?> readIntent(String operationId) async {
    if (!_operationPattern.hasMatch(operationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    return (await _read()).intents[operationId];
  }

  Future<CreationIntent> createIntent({
    required String operationId,
    required String directory,
    required String businessName,
    required String runtimeName,
    bool shouldStart = false,
  }) async {
    if (!_operationPattern.hasMatch(operationId) ||
        businessName.isEmpty ||
        runtimeName.isEmpty) {
      throw ArgumentError('Invalid creation intent');
    }
    final identity = await _identity(directory);
    return _locked('.lock', () async {
      final data = await _read();
      final existing = data.intents[operationId];
      if (existing != null) {
        if (existing.directory != identity ||
            existing.businessName != businessName ||
            existing.runtimeName != runtimeName ||
            (existing.shouldStart != null &&
                existing.shouldStart != shouldStart)) {
          throw StateError('Operation ID already used');
        }
        return existing;
      }
      final intent = CreationIntent(
        operationId: operationId,
        directory: identity,
        businessName: businessName,
        runtimeName: runtimeName,
        phase: CreationPhase.prepared,
        shouldStart: shouldStart,
      );
      data.intents[operationId] = intent;
      await _write(data);
      return intent;
    });
  }

  /// Records only the failed step. Successful advancement clears the failure.
  Future<CreationIntent> recordIntentFailure(
    String operationId,
    CreationFailureStage failureStage,
  ) async {
    if (!_operationPattern.hasMatch(operationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    return _locked('.lock', () async {
      final data = await _read();
      final old = data.intents[operationId];
      if (old == null ||
          !_failureAllowed(old.phase, old.shouldStart, failureStage)) {
        throw StateError('Invalid intent failure stage');
      }
      if (old.failureStage == failureStage) return old;
      final updated = CreationIntent(
        operationId: old.operationId,
        directory: old.directory,
        businessName: old.businessName,
        runtimeName: old.runtimeName,
        phase: old.phase,
        containerId: old.containerId,
        shouldStart: old.shouldStart,
        failureStage: failureStage,
      );
      data.intents[operationId] = updated;
      await _write(data);
      return updated;
    });
  }

  /// Advances monotonically; registration and ownership are committed together.
  Future<CreationIntent> advanceIntent(
    String operationId,
    CreationPhase phase, {
    String? containerId,
  }) async {
    if (!_operationPattern.hasMatch(operationId) ||
        phase == CreationPhase.prepared ||
        !_validId(containerId)) {
      throw ArgumentError('Invalid intent transition');
    }
    return _locked('.lock', () async {
      final data = await _read();
      final old = data.intents[operationId];
      if (old == null) throw StateError('Unknown creation intent');
      if (old.containerId != null && old.containerId != containerId) {
        throw StateError('Container ID cannot change');
      }
      if (phase == old.phase) return old;
      final valid = switch (old.phase) {
        CreationPhase.prepared => phase == CreationPhase.created,
        CreationPhase.created => phase == CreationPhase.registered,
        CreationPhase.registered =>
          old.shouldStart == true
              ? phase == CreationPhase.started
              : old.shouldStart == false && phase == CreationPhase.completed,
        CreationPhase.started => phase == CreationPhase.completed,
        CreationPhase.completed => false,
      };
      if (!valid) throw StateError('Invalid intent transition');
      if (phase == CreationPhase.registered) {
        _register(data, old.directory, 'container:$containerId');
      }
      final updated = CreationIntent(
        operationId: old.operationId,
        directory: old.directory,
        businessName: old.businessName,
        runtimeName: old.runtimeName,
        phase: phase,
        containerId: containerId,
        shouldStart: old.shouldStart,
      );
      data.intents[operationId] = updated;
      await _write(data);
      return updated;
    });
  }
}
