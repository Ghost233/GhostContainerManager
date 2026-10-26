import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tool_catalog.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

void main() {
  group('tool catalog', () {
    test('35 entries across eight domains, matching the v1 spec', () {
      expect(kToolCatalog, hasLength(35));
      final byDomain = catalogByDomain();
      expect(byDomain.keys, <String>[
        'system',
        'container',
        'image',
        'mount',
        'network',
        'compose',
        'project',
        'registry',
      ]);
      expect(byDomain['system'], hasLength(3));
      expect(byDomain['container'], hasLength(10));
      expect(byDomain['image'], hasLength(4));
      expect(byDomain['mount'], hasLength(2));
      expect(byDomain['network'], hasLength(2));
      expect(byDomain['compose'], hasLength(3));
      expect(byDomain['project'], hasLength(8));
      expect(byDomain['registry'], hasLength(3));
    });

    test('catalogEntryByName resolves known and rejects unknown', () {
      expect(catalogEntryByName('container_list')?.domain, 'container');
      expect(catalogEntryByName('registry_stop')?.destructive, isTrue);
      expect(catalogEntryByName('nope'), isNull);
    });

    test('every catalog entry has a non-empty title and description', () {
      for (final entry in kToolCatalog) {
        expect(entry.title, isNotEmpty, reason: entry.name);
        expect(entry.description, isNotEmpty, reason: entry.name);
      }
    });
  });

  group('buildBusinessToolRegistry', () {
    test('collects only wired domains (system + container here)', () {
      final bridge = FakeContainerBridge();
      final registry = buildBusinessToolRegistry(
        systemService: SystemService(bridge: bridge),
        containerService: ContainerService(bridge: bridge),
      );
      expect(
        registry.callbacks.keys,
        containsAll(<String>[
          'system_status',
          'system_start',
          'system_stop',
          'container_list',
          'container_exec',
        ]),
      );
      expect(registry.callbacks, hasLength(13));
      expect(registry.callbacks.containsKey('image_list'), isFalse);
    });
  });
}
