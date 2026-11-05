import 'dart:io';

import 'package:ghost_container_manager/services/directory_registry.dart';

Future<void> main(List<String> args) async {
  try {
    final registry = DirectoryRegistry(File(args[0]));
    if (args.length > 3 && args[3] == 'legacy') {
      await registry.createIntent(
        operationId: args[1],
        directory: args[2],
        businessName: 'legacy',
        runtimeName: 'legacy',
      );
    } else {
      await registry.reserveCreate(
        operationId: args[1],
        endpoint: 'b' * 64,
        directory: args[2],
        businessName: 'name',
        runtimeName: 'runtime',
        requestDigest: 'a' * 64,
      );
    }
    stdout.write('won');
  } on StateError {
    stdout.write('collision');
  }
}
