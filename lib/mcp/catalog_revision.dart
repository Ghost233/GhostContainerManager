/// catalogRevision（issue #30）：工具注册表内容的规范化稳定哈希。
///
/// 计算方式：kToolCatalog 每个条目经 [ToolCatalogEntry.toDetailJson]
/// 序列化后按工具名组成对象，再做规范化 JSON（Map 键递归排序、零空白），
/// 对 UTF-8 字节做 SHA-256，取前 16 个小写 hex 字符。注册表在进程内不可
/// 变，结果只计算一次并缓存；同一构建的任意多个服务器实例必然一致，注册
/// 表内容变化则哈希变化——客户端可用它判断缓存的工具目录是否过期。
///
/// SHA-256 使用本文件的纯 Dart 实现（FIPS 180-4），不新增第三方依赖；
/// [sha256HexDigest] 公开以便测试用标准已知向量校验实现正确性。
library;

import 'dart:convert';

import 'tool_catalog.dart';

String? _cachedRevision;

/// 当前注册表的 catalogRevision（16 个小写 hex 字符）。
String catalogRevision() => _cachedRevision ??= _computeCatalogRevision();

String _computeCatalogRevision() {
  final canonical = canonicalJson(<String, Object?>{
    for (final entry in kToolCatalog) entry.name: entry.toDetailJson(),
  });
  return sha256HexDigest(utf8.encode(canonical)).substring(0, 16);
}

/// 规范化 JSON：Map 键递归按字典序排序、无空白，保证同一内容在任何
/// 实例/任何时候序列化出同一字符串（catalogRevision 的稳定性前提）。
String canonicalJson(Object? value) {
  return switch (value) {
    null => 'null',
    final bool b => b ? 'true' : 'false',
    final num n => jsonEncode(n),
    final String s => jsonEncode(s),
    final List<Object?> list => '[${list.map(canonicalJson).join(',')}]',
    final Map<Object?, Object?> map => _canonicalMap(map),
    _ => throw ArgumentError.value(
      value,
      'value',
      'canonicalJson 只支持 null/bool/num/String/List/Map',
    ),
  };
}

String _canonicalMap(Map<Object?, Object?> map) {
  final keys = map.keys.map((k) => k! as String).toList()..sort();
  return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(map[k])}').join(',')}}';
}

const int _mask32 = 0xffffffff;

int _rrot(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// SHA-256（FIPS 180-4）纯 Dart 实现，返回 64 个小写 hex 字符。
///
/// 正确性由 test/mcp/catalog_tools_test.dart 的标准已知向量
/// （空串、"abc"、56 字节双分块串）强制保证。
String sha256HexDigest(List<int> message) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  // 预填充：追加 0x80、补零至 ≡56 (mod 64)，最后 8 字节为大端位长。
  final bytes = List<int>.of(message);
  final bitLength = message.length * 8;
  bytes.add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    bytes.add((bitLength >> (i * 8)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var block = 0; block < bytes.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      final o = block + t * 4;
      w[t] =
          (bytes[o] << 24) |
          (bytes[o + 1] << 16) |
          (bytes[o + 2] << 8) |
          bytes[o + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rrot(w[t - 15], 7) ^ _rrot(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rrot(w[t - 2], 17) ^ _rrot(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _mask32;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var t = 0; t < 64; t++) {
      final bs1 = _rrot(e, 6) ^ _rrot(e, 11) ^ _rrot(e, 25);
      final ch = (e & f) ^ (~e & _mask32 & g);
      final temp1 = (h + bs1 + ch + k[t] + w[t]) & _mask32;
      final bs0 = _rrot(a, 2) ^ _rrot(a, 13) ^ _rrot(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (bs0 + maj) & _mask32;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _mask32;
    }
    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
    h5 = (h5 + f) & _mask32;
    h6 = (h6 + g) & _mask32;
    h7 = (h7 + h) & _mask32;
  }

  final out = StringBuffer();
  for (final word in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
    out.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}
