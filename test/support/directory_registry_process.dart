import 'dart:io';

import 'package:ghost_container_manager/services/directory_registry.dart';

Future<void> main(List<String> args) async {
  final registry = DirectoryRegistry(File(args[0]));
  await registry.withIntentLock('shared', () async {
    final marker = File(args[1]);
    if (await marker.exists()) exitCode = 1;
    await marker.writeAsString('held');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await marker.delete();
  });
}
