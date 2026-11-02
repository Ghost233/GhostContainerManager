import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_constants.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.downloadUrl,
    required this.sha256,
  });
  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String downloadUrl;
  final String? sha256;
}

typedef UpdateJsonReader = Future<Map<String, Object?>> Function(Uri uri);

/// The app owns version discovery; Launcher owns downloading and opening DMGs.
class AppUpdateService {
  AppUpdateService({
    this.currentVersion = gcmAppVersion,
    UpdateJsonReader? readJson,
  }) : _readJson = readJson ?? _fetchJson;

  static final latestRelease = Uri.https(
    'api.github.com',
    '/repos/Ghost233/GhostContainerManager/releases/latest',
  );
  final String currentVersion;
  final UpdateJsonReader _readJson;
  Future<AppUpdateInfo>? _pending;

  Future<AppUpdateInfo> check() =>
      _pending ??= _query().whenComplete(() => _pending = null);

  Future<AppUpdateInfo> _query() async {
    final current = _version(currentVersion);
    final release = await _readJson(latestRelease);
    if (release['draft'] != false || release['prerelease'] != false) {
      throw const FormatException('更新源未返回正式发布版本');
    }
    final tag = release['tag_name'];
    if (tag is! String) throw const FormatException('发布信息缺少版本号');
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    final version = _version(latest);
    final assets =
        (release['assets'] as List?)?.whereType<Map>().toList() ?? [];
    final name = 'GhostContainerManager-$latest.dmg';
    final matches = assets.where((a) => a['name'] == name).toList();
    if (matches.length != 1 ||
        matches.single['size'] is! num ||
        (matches.single['size'] as num) <= 0) {
      throw FormatException('发布包缺失或无效：$name');
    }
    final asset = matches.single;
    final url = _downloadUri(asset['browser_download_url']);
    String? checksum;
    final digest = asset['digest'];
    if (digest is String &&
        RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      checksum = digest.substring(7).toLowerCase();
    } else {
      final manifests = assets
          .where((a) => a['name'] == 'manifest.json')
          .toList();
      if (manifests.length == 1) {
        final manifest = await _readJson(
          _downloadUri(manifests.single['browser_download_url']),
        );
        if (manifest['version'] != latest || manifest['tag'] != tag) {
          throw const FormatException('更新清单版本与 Release 不一致');
        }
        final entries =
            (manifest['assets'] as List?)
                ?.whereType<Map>()
                .where((a) => a['name'] == name)
                .toList() ??
            [];
        if (entries.length != 1 ||
            entries.single['size'] != asset['size'] ||
            entries.single['sha256'] is! String ||
            !RegExp(r'^[a-fA-F0-9]{64}$')
                .hasMatch(entries.single['sha256'] as String)) {
          throw const FormatException('更新清单缺少匹配的大小或 SHA-256');
        }
        checksum = (entries.single['sha256'] as String).toLowerCase();
      }
    }
    var comparison = 0;
    for (var i = 0; i < 3 && comparison == 0; i++) {
      comparison = version[i].compareTo(current[i]);
    }
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latest,
      hasUpdate: comparison > 0,
      downloadUrl: url.toString(),
      sha256: checksum,
    );
  }

  static List<int> _version(String value) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value)) {
      throw FormatException('无法比较版本：$value');
    }
    return value.split('.').map(int.parse).toList();
  }

  static Uri _downloadUri(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(
          '/Ghost233/GhostContainerManager/releases/download/',
        )) {
      throw const FormatException('更新地址不是本项目的 HTTPS Release 资产');
    }
    return uri;
  }

  static Future<Map<String, Object?>> _fetchJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'GhostContainerManager/$gcmAppVersion',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('更新查询返回 HTTP ${response.statusCode}', uri: uri);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const FormatException('更新元数据超过 1 MiB');
          }
          bytes.addAll(chunk);
        }
        final result = jsonDecode(utf8.decode(bytes));
        if (result is! Map<String, dynamic>) {
          throw const FormatException('更新源没有返回 JSON 对象');
        }
        return result.cast<String, Object?>();
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}
