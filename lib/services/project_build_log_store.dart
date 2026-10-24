import 'dart:io';

abstract class ProjectBuildLogStore {
  Future<String> write({
    required String project,
    required String imageName,
    required String dockerfile,
    required String stage,
    required String reason,
    required String logTail,
  });
}

class FileProjectBuildLogStore implements ProjectBuildLogStore {
  FileProjectBuildLogStore({
    required this.directory,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String directory;
  final DateTime Function() _clock;
  int _sequence = 0;

  @override
  Future<String> write({
    required String project,
    required String imageName,
    required String dockerfile,
    required String stage,
    required String reason,
    required String logTail,
  }) async {
    final directory = Directory(this.directory);
    await directory.create(recursive: true);
    final now = _clock().toUtc();
    final sequence = (_sequence++).toString().padLeft(6, '0');
    final file = File(
      '${directory.path}/${now.microsecondsSinceEpoch}-$sequence-$project-$imageName.log',
    );
    final content = StringBuffer()
      ..writeln('project: $project')
      ..writeln('name: $imageName')
      ..writeln('dockerfile: $dockerfile')
      ..writeln('timestamp: ${now.toIso8601String()}')
      ..writeln('stage: $stage')
      ..writeln('reason: $reason')
      ..writeln('--- output tail (up to 1000 lines) ---')
      ..write(logTail);
    await file.writeAsString(content.toString(), flush: true);

    final logs = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.log')) logs.add(entity);
    }
    logs.sort((a, b) => a.path.compareTo(b.path));
    while (logs.length > 20) {
      await logs.removeAt(0).delete();
    }
    return file.path;
  }
}
