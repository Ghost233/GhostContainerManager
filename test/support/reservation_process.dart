import 'dart:io';

import 'package:ghost_container_manager/services/directory_registry.dart';

Future<void> main(List<String> args) async {
  try {
    await DirectoryRegistry(File(args[0])).reserveCreate(
      operationId: args[1],
      endpoint: 'opaque',
      directory: args[2],
      businessName: 'name',
      runtimeName: 'runtime',
      requestDigest: 'digest',
    );
    stdout.write('won');
  } on StateError {
    stdout.write('collision');
  }
}
