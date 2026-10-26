import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/mcp/tool_catalog.dart';
import 'package:ghost_container_manager/mcp/tool_registry.dart';

/// issue #30：GcmToolRegistry 是 kToolCatalog 的按名索引视图——
/// 定义数与注册表一致、catalogRevision 跨实例稳定、lookup 未知名返回 null。
void main() {
  group('GcmToolRegistry（issue #30）', () {
    test('definitions 覆盖全部 35 个注册表条目且不可修改', () {
      final registry = GcmToolRegistry();
      final definitions = registry.definitions();
      expect(definitions, hasLength(35));
      expect(definitions.keys, containsAll(kToolCatalog.map((e) => e.name)));
      final existing = registry.lookup('container_create')!;
      expect(
        () => definitions['injected_tool'] = existing,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('catalogRevision 为 12 位小写 hex 且两个实例一致', () {
      final first = GcmToolRegistry();
      final second = GcmToolRegistry();
      expect(first.catalogRevision, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(second.catalogRevision, first.catalogRevision);
    });

    test('lookup 命中返回完整定义，未知名返回 null', () {
      final registry = GcmToolRegistry();
      expect(registry.lookup('nope_not_a_tool'), isNull);

      final definition = registry.lookup('container_create')!;
      expect(definition.name, 'container_create');
      expect(definition.domain, 'container');
      expect(definition.title, 'Create Container');
      expect(definition.description, isNotEmpty);

      final json = definition.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'name',
          'title',
          'domain',
          'description',
          'inputSchema',
          'outputSchema',
          'annotations',
          'meta',
        ]),
      );
      final annotations = (json['annotations'] as Map).cast<String, dynamic>();
      expect(
        annotations.keys,
        containsAll(<String>[
          'readOnlyHint',
          'destructiveHint',
          'idempotentHint',
          'openWorldHint',
        ]),
      );
      final inputSchema = (json['inputSchema'] as Map).cast<String, dynamic>();
      expect(
        (inputSchema['properties'] as Map).keys,
        containsAll(<String>['image', 'name', 'ports', 'mounts']),
      );
    });
  });
}
