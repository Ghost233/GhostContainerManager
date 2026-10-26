/// GCM 工具定义注册表读取面（issue #30）：gcm_help tool 模式与
/// catalogRevision 的统一来源。
///
/// 元数据单一事实来源仍是 lib/mcp/tool_catalog.dart 的 [kToolCatalog]
/// （ADR-0001）；本文件只是它的按名索引视图——[GcmToolRegistry.definitions]
/// 从注册表派生为不可修改的 name → 定义 Map，[GcmToolRegistry.lookup] 按名
/// 查找，[GcmToolRegistry.catalogRevision] 给出注册表内容的规范化稳定哈希
/// （lib/mcp/catalog_revision.dart 的纯 Dart SHA-256，截前 16 个小写 hex，
/// 不新增第三方依赖）。
library;

import 'package:mcp_dart/mcp_dart.dart';

import 'catalog_revision.dart' as revision;
import 'tool_catalog.dart';

/// 单个业务工具的完整定义（gcm_help tool 模式的响应载体）。
class GcmToolDefinition {
  const GcmToolDefinition({
    required this.name,
    required this.domain,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.outputSchema,
    required this.annotations,
    this.meta,
  });

  factory GcmToolDefinition.fromCatalogEntry(ToolCatalogEntry entry) =>
      GcmToolDefinition(
        name: entry.name,
        domain: entry.domain,
        title: entry.title,
        description: entry.description,
        inputSchema: entry.inputSchema,
        outputSchema: entry.outputSchema,
        annotations: entry.annotations,
        meta: entry.meta,
      );

  final String name;
  final String domain;
  final String title;
  final String description;
  final JsonObject inputSchema;
  final JsonObject outputSchema;
  final ToolAnnotations annotations;
  final Map<String, Object?>? meta;

  /// gcm_help tool 模式响应里 `tool` 字段的 JSON 形状：完整
  /// inputSchema/outputSchema、四字段 hint 注解与 meta。
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'title': title,
    'domain': domain,
    'description': description,
    'inputSchema': inputSchema.toJson(),
    'outputSchema': outputSchema.toJson(),
    'annotations': <String, Object?>{
      'readOnlyHint': annotations.readOnlyHint,
      'destructiveHint': annotations.destructiveHint,
      'idempotentHint': annotations.idempotentHint,
      'openWorldHint': annotations.openWorldHint,
    },
    'meta': meta,
  };
}

/// [kToolCatalog] 的按名索引视图。注册表在进程内不可变，实例本身无状态
/// 差异——任意两个实例的 definitions 与 catalogRevision 必然一致。
class GcmToolRegistry {
  GcmToolRegistry();

  late final Map<String, GcmToolDefinition> _definitions =
      Map<String, GcmToolDefinition>.unmodifiable(<String, GcmToolDefinition>{
        for (final entry in kToolCatalog)
          entry.name: GcmToolDefinition.fromCatalogEntry(entry),
      });

  /// 全部工具定义（name → 定义）的不可修改视图，与注册表条目一一对应。
  Map<String, GcmToolDefinition> definitions() => _definitions;

  /// 按名查找；未知名返回 null。
  GcmToolDefinition? lookup(String name) => _definitions[name];

  /// 注册表内容的规范化稳定哈希（16 个小写 hex 字符）；目录不变则不变。
  String get catalogRevision => revision.catalogRevision();
}
