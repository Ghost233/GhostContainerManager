import 'dart:io';

import 'package:ghost_container_manager/services/directory_registry.dart';

Future<void> main(List<String> args) async {
  try {
    await DirectoryRegistry(File(args[0])).reserveCreate(
      operationId: args[1],
      endpoint: 'b' * 64,
      directory: args[2],
      businessName: 'name',
      runtimeName: 'runtime',
      requestDigest: 'a' * 64,
    );
    stdout.write('won');
  } on StateError {
    stdout.write('collision');
  }
}
