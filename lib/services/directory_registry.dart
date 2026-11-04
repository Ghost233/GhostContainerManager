import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Shared management entry for explicit directory resource registrations.
///
/// [storage] is an application-owned file, not a file in the managed directory.
class DirectoryRegistry {
  DirectoryRegistry(this.storage);

  final File storage;
  static final Map<String, Future<void>> _writes = {};

  Future<String> _identity(String path) async {
    if (!path.startsWith('/')) throw ArgumentError.value(path, 'path');
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw ArgumentError.value(path, 'path', 'Must be an existing directory');
    }
    return directory.resolveSymbolicLinks();
  }

  Future<Map<String, List<String>>> _read() async {
    if (!await storage.exists()) return {};
    final data = jsonDecode(await storage.readAsString());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid registry');
    }
    return data.map((key, value) {
      if (value is! List || value.any((item) => item is! String)) {
        throw const FormatException('Invalid registry entry');
      }
      return MapEntry(key, value.cast<String>());
    });
  }

  Future<List<String>> query(String path) async {
    final identity = await _identity(path);
    return List.unmodifiable((await _read())[identity] ?? <String>[]);
  }

  Future<void> register(String path, String resource) async {
    final identity = await _identity(path);
    await storage.parent.create(recursive: true);
    final key =
        '${await storage.parent.resolveSymbolicLinks()}/${storage.uri.pathSegments.last}';
    final previous = _writes[key] ?? Future<void>.value();
    final done = Completer<void>();
    _writes[key] = done.future;
    try {
      await previous;
      final lock = await File('$key.lock').open(mode: FileMode.append);
      try {
        await lock.lock();
        final entries = await _read();
        final resources = entries.putIfAbsent(identity, () => <String>[]);
        if (!resources.contains(resource)) resources.add(resource);
        final temp = await storage.parent.createTemp('.directory-registry-');
        try {
          final file = File('${temp.path}/registry');
          await file.writeAsString(jsonEncode(entries), flush: true);
          await file.rename(storage.path);
        } finally {
          await temp.delete(recursive: true);
        }
      } finally {
        await lock.close();
      }
    } finally {
      done.complete();
      if (identical(_writes[key], done.future)) _writes.remove(key);
    }
  }
}
