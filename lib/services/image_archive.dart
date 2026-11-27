/// Docker image archives are local files, even when the active Docker engine
/// is reached through SSH. This service never pulls, starts, or retags an
/// image itself; archive restoration is handled by Docker.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../bridge/container_bridge.dart';
import 'errors.dart';
import 'image_models.dart';

class ImageArchiveService {
  ImageArchiveService(this._bridge);

  final ContainerBridge _bridge;
  static const _archiveTimeout = Duration(minutes: 15);
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  bool _busy = false;

  Future<Map<String, Object?>> save(String reference, String path) =>
      _exclusive(() async {
        final ref = validateImageReference(reference).reference;
        final file = await _archivePath(path);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const GcmException(GcmErrorCode.conflict, '目标文件已存在，不覆盖。');
        }
        final context = await _context();
        final scratch = await file.parent.createTemp('.gcm-save-');
        try {
          final staged = File('${scratch.path}/image.tar');
          await _docker([
            'image',
            'save',
            '--output',
            staged.path,
            ref,
          ], '导出镜像');
          final digest = await _hash(staged);
          final length = await staged.length();
          if (length == 0) {
            throw const GcmException(GcmErrorCode.internal, 'Docker 导出了空归档。');
          }
          // Darwin's ln does not replace an existing target. Stage on the same
          // volume, so clients never observe a partially written archive.
          final published = await Process.run('/bin/ln', [
            '-h',
            staged.path,
            file.path,
          ]);
          if (published.exitCode != 0) {
            throw const GcmException(
              GcmErrorCode.conflict,
              '无法写入归档：目标可能已存在，或文件系统不支持安全发布。',
            );
          }
          return {
            'path': file.path,
            'reference': ref,
            'context': context,
            'bytes': length,
            'sha256': digest,
          };
        } finally {
          await scratch.delete(recursive: true);
        }
      });

  Future<String> checksum(String path) async {
    final file = await _archivePath(path);
    await _checkInput(file);
    return _hash(file);
  }

  Future<Map<String, Object?>> load(
    String path, {
    required String expectedSha256,
    required bool confirmTagChanges,
  }) => _exclusive(() async {
    if (!confirmTagChanges || !_digestPattern.hasMatch(expectedSha256)) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        '导入需要 64 位小写 SHA-256，并须确认 Docker 可能恢复或覆盖同名 tag。',
      );
    }
    final file = await _archivePath(path);
    await _checkInput(file);
    final context = await _context();
    final scratch = await Directory.systemTemp.createTemp('gcm-load-');
    try {
      // Docker opens the staging path, not the caller's pathname. Hash the
      // private copy to ensure Docker consumes exactly the verified bytes.
      final staged = await file.copy('${scratch.path}/image.tar');
      final digest = await _hash(staged);
      if (digest != expectedSha256) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          '镜像归档 SHA-256 不匹配，未执行导入。',
        );
      }
      final out = await _docker([
        'image',
        'load',
        '--input',
        staged.path,
      ], '导入镜像');
      final loaded = out.stdout
          .split('\n')
          .map(
            (line) =>
                RegExp(r'^Loaded image(?: ID)?: (.+)$')
                    .firstMatch(line.trim())
                    ?.group(1),
          )
          .whereType<String>()
          .toSet()
          .toList(growable: false);
      return {
        'path': file.path,
        'context': context,
        'bytes': await staged.length(),
        'sha256': digest,
        'loadedReferences': loaded,
      };
    } finally {
      await scratch.delete(recursive: true);
    }
  });

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) {
      throw const GcmException(GcmErrorCode.conflict, '已有镜像归档操作正在运行。');
    }
    _busy = true;
    try {
      return await action();
    } on FileSystemException {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        '无法读写本机的镜像归档，请检查目录权限与剩余空间。',
      );
    } finally {
      _busy = false;
    }
  }

  Future<File> _archivePath(String path) async {
    final input = File(path);
    if (!path.startsWith('/') ||
        path.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        !path.endsWith('.tar') ||
        !await input.parent.exists()) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        '请选择已有本机目录下的绝对 .tar 路径。',
      );
    }
    final parent = await input.parent.resolveSymbolicLinks();
    return File('$parent/${input.uri.pathSegments.last}');
  }

  Future<void> _checkInput(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() == 0) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        '导入需要非空的普通 .tar 文件，不接受符号链接。',
      );
    }
  }

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<String> _context() async {
    final context = (await _docker([
      'context',
      'show',
    ], '读取 Docker context')).stdout.trim();
    if (context.isEmpty || context.contains(RegExp(r'[\r\n]'))) {
      throw const GcmException(GcmErrorCode.internal, '无法确认 Docker context。');
    }
    return context;
  }

  Future<BridgeCommandResult> _docker(List<String> args, String verb) async {
    final out = await _bridge.cliRun(args, timeout: _archiveTimeout);
    if (!out.ok) {
      if (out.timedOut) {
        throw GcmException(
          GcmErrorCode.internal,
          '$verb超时。',
          hint: '如为导入，请先检查当前镜像状态，不要直接重试。',
        );
      }
      throw GcmException(
        GcmErrorCode.internal,
        '$verb失败（退出码 ${out.exitCode}）。',
        hint: '请检查当前 Docker context、磁盘空间与归档格式。',
      );
    }
    return out;
  }
}
