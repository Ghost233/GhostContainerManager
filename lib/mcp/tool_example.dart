/// 工具示例参数生成（issue #35 / #30 验收 4）：为每个业务工具生成一份
/// 必能通过其 inputSchema 校验的示例参数对象，随 gcm_help tool 模式输出。
///
/// 示例由 schema 派生（单一事实来源不双写）：枚举取首值、整数/数值取
/// minimum（无则 1）、字符串取 defaultValue 或「example」（注册表内仅有
/// 的 pattern 是名称前缀规则，该占位串满足）、对象只填 required 字段、
/// 数组给单元素。正确性由 test/mcp/catalog_tools_test.dart 强制——
/// 35 个示例逐一过 mcp_dart 内建校验器，任何 schema 改动导致示例失效
/// 都会测试变红。
library;

import 'package:mcp_dart/mcp_dart.dart';

/// 为 [schema] 生成一份可通过校验的示例参数对象（顶层约定为 JsonObject）。
Object? exampleForSchema(JsonSchema schema) {
  return switch (schema) {
    final JsonObject o => _objectExample(o),
    final JsonString s =>
      s.enumValues?.first ?? s.defaultValue?.toString() ?? 'example',
    final JsonInteger i => i.defaultValue ?? i.minimum ?? 1,
    final JsonNumber n => n.defaultValue ?? n.minimum ?? 1,
    final JsonBoolean b => b.defaultValue ?? true,
    final JsonArray a =>
      a.items == null
          ? const <Object?>[]
          : <Object?>[exampleForSchema(a.items!)],
    _ => null,
  };
}

Map<String, Object?> _objectExample(JsonObject schema) {
  final properties = schema.properties ?? const <String, JsonSchema>{};
  return <String, Object?>{
    for (final key in schema.required ?? const <String>[])
      key: exampleForSchema(properties[key] ?? const JsonString()),
  };
}
