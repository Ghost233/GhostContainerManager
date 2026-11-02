/// Engine-reported image and writable-layer usage; no host runtime-store access.
library;

import 'dart:convert';

import '../bridge/container_bridge.dart';
import '../bridge/docker_container_bridge.dart';
import 'errors.dart';

class ImageDiskFootprint {
  const ImageDiskFootprint({
    required this.expandedBytes,
    required this.layerDiskBytes,
    required this.containerDiskBytes,
  });
  final int? expandedBytes;
  final int layerDiskBytes;
  final int containerDiskBytes;
  int get actualDiskBytes => layerDiskBytes + containerDiskBytes;
}

class ImageFootprintService {
  ImageFootprintService({ContainerBridge? bridge})
    : _bridge = bridge ?? DockerContainerBridge();
  final ContainerBridge _bridge;
  static String defaultAppRoot() => '';
  Future<int?> expandedSizeBytes({
    required String digest,
    String? appRoot,
  }) async {
    final result = await _bridge.imageInspect(digest);
    return (result['sizeBytes'] as num?)?.toInt();
  }

  Future<int> layerDiskBytes({required String digest, String? appRoot}) async =>
      (await expandedSizeBytes(digest: digest)) ?? 0;
  Future<int> containerDirectoryBytes(String id, {String? appRoot}) async {
    final result = await _bridge.cliRun(['container', 'inspect', '--size', id]);
    if (!result.ok) {
      throw GcmException(
        GcmErrorCode.runtimeUnavailable,
        '无法读取容器大小',
        cause: result.combinedOutput,
      );
    }
    final data = jsonDecode(result.stdout) as List;
    final size = (data.single as Map)['SizeRw'];
    if (size is! num) {
      throw const GcmException(GcmErrorCode.internal, 'Docker 未返回容器可写层大小');
    }
    return size.toInt();
  }

  Future<ImageDiskFootprint> footprintFor({
    required String digest,
    required List<String> containerIds,
    String? appRoot,
  }) async {
    final expanded = await expandedSizeBytes(digest: digest);
    var writable = 0;
    for (final id in containerIds) {
      writable += await containerDirectoryBytes(id);
    }
    return ImageDiskFootprint(
      expandedBytes: expanded,
      layerDiskBytes: expanded ?? 0,
      containerDiskBytes: writable,
    );
  }
}
