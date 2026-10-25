import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/launcher/maclauncher_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

void main() {
  late FakeContainerBridge containerBridge;
  late ContainerService containerService;
  late FakeMacLauncherSdk sdk;

  setUp(() {
    containerBridge = FakeContainerBridge();
    containerService = ContainerService(bridge: containerBridge);
    sdk = FakeMacLauncherSdk();
  });

  tearDown(() async {
    containerService.stopPolling();
    await containerService.dispose();
    await sdk.close();
  });

  test('connect registers one SDK service per managed container', () async {
    containerBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
      snapshot(id: 'worker', labels: const {'com.ghost233.role': 'queue'}),
      snapshot(id: 'unlabelled'),
      snapshot(id: 'outside', labels: const {'com.example.managed': 'true'}),
      snapshot(id: 'wrong-prefix', labels: const {'com.ghost233': 'true'}),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );

    await launcher.connect();

    expect(connector.projectId, 'com.ghost233.ghostcontainermanager');
    expect(connector.projectName, 'Ghost Container Manager');
    expect(connector.services?.keys, unorderedEquals(['web', 'worker']));
    expect(connector.services?['web']?.name, 'web');
    expect(connector.services?['worker']?.name, 'worker');
  });

  test('connect follows managed container additions and removals', () async {
    containerBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final factory = _FakeSdkFactory();
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: factory.call,
    );
    addTearDown(() async {
      await launcher.dispose();
      await factory.close();
    });
    await launcher.connect();
    expect(factory.registrations.single.services.keys, ['web']);

    containerBridge.containers = [
      ...containerBridge.containers,
      snapshot(id: 'worker', labels: const {'com.ghost233.role': 'test'}),
      snapshot(id: 'outside', labels: const {'com.example.managed': 'true'}),
    ];
    await containerService.listContainers(const ContainerQuery());
    await _flushAsync();

    expect(factory.registrations, hasLength(2));
    expect(factory.registrations[0].sdk.disposeCalls, 1);
    expect(
      factory.registrations[1].services.keys,
      unorderedEquals(['web', 'worker']),
    );

    containerBridge.containers.removeWhere(
      (container) => (container['configuration'] as Map)['id'] == 'worker',
    );
    await containerService.listContainers(const ContainerQuery());
    await _flushAsync();

    expect(factory.registrations, hasLength(3));
    expect(factory.registrations[1].sdk.disposeCalls, 1);
    expect(factory.registrations[2].services.keys, ['web']);
    expect(containerBridge.startCalls, 0);
    expect(containerBridge.stopCalls, 0);

    await containerService.listContainers(const ContainerQuery());
    await _flushAsync();
    expect(factory.registrations, hasLength(3));
  });

  test('concurrent connect shares one SDK registration', () async {
    containerBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final factory = _FakeSdkFactory();
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: factory.call,
    );
    addTearDown(() async {
      await launcher.dispose();
      await factory.close();
    });

    await Future.wait([launcher.connect(), launcher.connect()]);
    await launcher.connect();

    expect(factory.registrations, hasLength(1));
  });

  test(
    'dispose during initial discovery prevents late SDK connection',
    () async {
      final gatedBridge = _GatedListBridge();
      gatedBridge.containers = [
        snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
      ];
      final gatedService = ContainerService(bridge: gatedBridge);
      addTearDown(() async {
        if (!gatedBridge.gate.isCompleted) gatedBridge.gate.complete();
        gatedService.stopPolling();
        await gatedService.dispose();
      });
      final factory = _FakeSdkFactory();
      final launcher = MacLauncherBridge(
        containers: gatedService,
        sdkConnector: factory.call,
      );

      final pending = launcher.connect();
      final outcome = pending.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await _flushAsync();
      await launcher.dispose();
      gatedBridge.gate.complete();

      expect(await outcome, isA<StateError>());
      expect(factory.registrations, isEmpty);
    },
  );

  test('disconnect and dispose never write containers', () async {
    containerBridge.containers = [
      snapshot(
        id: 'web',
        status: 'stopped',
        labels: const {'com.ghost233.managed': 'true'},
      ),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    containerBridge.calls.clear();

    sdk.emit(SdkConnectionStatus(SdkConnectionState.disconnected));
    await Future<void>.delayed(Duration.zero);
    await launcher.dispose();

    expect(sdk.disposeCalls, 1);
    expect(containerBridge.calls, isEmpty);
  });

  test('onStart uses ContainerService and preserves failures', () async {
    containerBridge.containers = [
      snapshot(
        id: 'web',
        status: 'stopped',
        labels: const {'com.ghost233.managed': 'true'},
      ),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onStart = connector.services!['web']!.onStart;
    expect(onStart, isNotNull);
    containerBridge.calls.clear();

    await onStart!();

    expect(containerBridge.startCalls, 1);
    expect(containerBridge.calls, ['containerStart:web']);
    containerBridge.writeFailures['start:web'] = 'start denied';
    await expectLater(
      onStart(),
      throwsA(
        isA<GcmException>().having(
          (error) => error.message,
          'message',
          contains('start denied'),
        ),
      ),
    );
  });

  test('onRecycle restarts through Service and preserves failures', () async {
    containerBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onRecycle = connector.services!['web']!.onRecycle;
    expect(onRecycle, isNotNull);
    containerBridge.calls.clear();

    await onRecycle!();

    expect(containerBridge.stopCalls, 1);
    expect(containerBridge.startCalls, 1);
    expect(
      containerBridge.calls.where(
        (call) =>
            call == 'containerStop:web timeout=5' ||
            call == 'containerStart:web',
      ),
      ['containerStop:web timeout=5', 'containerStart:web'],
    );
    containerBridge.writeFailures['stop:web'] = 'stop denied';
    await expectLater(
      onRecycle(),
      throwsA(
        isA<GcmException>().having(
          (error) => error.message,
          'message',
          contains('stop denied'),
        ),
      ),
    );
    expect(containerBridge.startCalls, 1);
  });

  test(
    'onStatus inspects fresh runtime state and preserves failures',
    () async {
      containerBridge.containers = [
        snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
      ];
      final connector = FakeSdkConnector(sdk);
      final launcher = MacLauncherBridge(
        containers: containerService,
        sdkConnector: connector.call,
      );
      await launcher.connect();
      final onStatus = connector.services!['web']!.onStatus;
      expect(onStatus, isNotNull);
      containerBridge.calls.clear();

      final cases = <(String, ServiceState)>[
        ('stopped', ServiceState.stopped),
        ('running', ServiceState.running),
        ('stopping', ServiceState.stopping),
        ('future-wire-state', ServiceState.unknown),
      ];
      for (final (wireState, expected) in cases) {
        containerBridge.containers = [
          snapshot(
            id: 'web',
            status: wireState,
            labels: const {'com.ghost233.managed': 'true'},
          ),
        ];
        final status = await onStatus!();
        expect(status.state, expected);
        expect(status.instanceId, isNull);
        expect(status.ready, isNull);
        expect(status.observedAt, isNull);
      }
      expect(
        containerBridge.calls.where((call) => call == 'containerInspect:web'),
        hasLength(cases.length),
      );

      containerBridge.inspectFailures['web'] = 'inspect denied';
      await expectLater(
        onStatus!(),
        throwsA(
          isA<GcmException>().having(
            (error) => error.message,
            'message',
            contains('inspect denied'),
          ),
        ),
      );
    },
  );

  test('onStatus follows synthetic Service activities', () async {
    containerBridge.containers = [
      snapshot(
        id: 'web',
        status: 'stopped',
        labels: const {'com.ghost233.managed': 'true'},
      ),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onStatus = connector.services!['web']!.onStatus!;

    containerBridge.startGate = Completer<void>();
    final starting = containerService.start('web');
    expect((await onStatus()).state, ServiceState.starting);
    containerBridge.startGate!.complete();
    await starting;

    containerBridge.stopGate = Completer<void>();
    final stopping = containerService.stop('web');
    expect((await onStatus()).state, ServiceState.stopping);
    containerBridge.stopGate!.complete();
    await stopping;
  });

  test('onLogs returns the recent batch and cancels at EOF', () async {
    final logBridge = _TrackingLogsBridge();
    logBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final logService = ContainerService(bridge: logBridge);
    addTearDown(() async {
      logService.stopPolling();
      await logService.dispose();
      if (logBridge.logEvents.hasListener || logBridge.logsCancelled) {
        await logBridge.logEvents.close();
      }
    });
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: logService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onLogs = connector.services!['web']!.onLogs;
    expect(onLogs, isNotNull);

    logBridge.logEvents.add(
      BridgeLogEvent.data(source: 'stdio', bytes: utf8.encode('first\nsecond')),
    );
    logBridge.logEvents.add(
      BridgeLogEvent.data(
        source: 'stdio',
        bytes: utf8.encode('-continued\nthird\n'),
      ),
    );
    logBridge.logEvents.add(
      BridgeLogEvent.data(source: 'boot', bytes: utf8.encode('boot line\n')),
    );
    logBridge.logEvents.add(const BridgeLogEvent.eof());

    final batch = await onLogs!(LogQuery(limit: 2));

    expect(batch.entries.map((entry) => entry.text), ['third', 'boot line']);
    expect(batch.entries[0].stream, LogStream.unknown);
    expect(batch.entries[1].stream, LogStream.app);
    expect(batch.entries.every((entry) => entry.timestamp == null), isTrue);
    expect(batch.truncated, isTrue);
    expect(batch.observedAt, isNotNull);
    expect(batch.observedAt!.isUtc, isTrue);
    expect(batch.instanceId, isNull);
    expect(logBridge.logsCancelled, isTrue);
  });

  test('onLogs bounds a continuous stream without EOF', () async {
    final logBridge = _TrackingLogsBridge();
    logBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final logService = ContainerService(bridge: logBridge);
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: logService,
      sdkConnector: connector.call,
    );
    addTearDown(() async {
      await launcher.dispose();
      logService.stopPolling();
      await logService.dispose();
      if (logBridge.logEvents.hasListener || logBridge.logsCancelled) {
        await logBridge.logEvents.close();
      }
    });
    await launcher.connect();

    final onLogs = connector.services!['web']!.onLogs!;
    final pending = onLogs(LogQuery(limit: 500));
    await logBridge.listened.future;

    var sequence = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (logBridge.logsCancelled) return;
      logBridge.logEvents.add(
        BridgeLogEvent.data(
          source: 'stdio',
          bytes: utf8.encode('line ${sequence++}\n'),
        ),
      );
    });
    try {
      final batch = await pending.timeout(const Duration(seconds: 1));
      timer.cancel();

      expect(batch.entries, isNotEmpty);
      expect(batch.entries.length, lessThan(500));
      expect(batch.truncated, isNull);
      expect(batch.observedAt, isNotNull);
      expect(logBridge.logsCancelled, isTrue);
    } finally {
      timer.cancel();
    }
  });

  test('dispose cancels an in-flight log read', () async {
    final logBridge = _TrackingLogsBridge();
    logBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    final logService = ContainerService(bridge: logBridge);
    addTearDown(() async {
      logService.stopPolling();
      await logService.dispose();
      if (logBridge.logEvents.hasListener || logBridge.logsCancelled) {
        await logBridge.logEvents.close();
      }
    });
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: logService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onLogs = connector.services!['web']!.onLogs!;

    final pending = onLogs(LogQuery());
    final outcome = pending.then<Object>(
      (batch) => batch,
      onError: (Object error) => error,
    );
    await logBridge.listened.future;
    await launcher.dispose().timeout(const Duration(seconds: 1));

    expect(sdk.disposeCalls, 1);
    expect(logBridge.logsCancelled, isTrue);
    expect(
      await outcome,
      isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('disposed'),
      ),
    );
  });

  test('onLogs surfaces Service log failures', () async {
    containerBridge.containers = [
      snapshot(id: 'web', labels: const {'com.ghost233.managed': 'true'}),
    ];
    containerBridge.logResponses['web'] = [
      const BridgeLogEvent.error('xpc died'),
    ];
    final connector = FakeSdkConnector(sdk);
    final launcher = MacLauncherBridge(
      containers: containerService,
      sdkConnector: connector.call,
    );
    await launcher.connect();
    final onLogs = connector.services!['web']!.onLogs!;

    await expectLater(
      onLogs(LogQuery()),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('xpc died'),
        ),
      ),
    );
  });
}

Map<String, Object?> snapshot({
  required String id,
  String status = 'running',
  Map<String, String> labels = const {},
}) {
  return <String, Object?>{
    'configuration': <String, Object?>{
      'id': id,
      'image': <String, Object?>{'reference': 'docker.io/library/nginx:latest'},
      'labels': labels,
    },
    'status': status,
    'networks': <Object?>[],
  };
}

class _GatedListBridge extends FakeContainerBridge {
  final gate = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> containerList() async {
    calls.add('containerList');
    await gate.future;
    return containers;
  }
}

class _TrackingLogsBridge extends FakeContainerBridge {
  _TrackingLogsBridge() {
    logEvents.onListen = () {
      if (!listened.isCompleted) listened.complete();
    };
    logEvents.onCancel = () {
      logsCancelled = true;
    };
  }

  final logEvents = StreamController<BridgeLogEvent>();
  final listened = Completer<void>();
  bool logsCancelled = false;

  @override
  Stream<BridgeLogEvent> containerLogs(String id) {
    calls.add('containerLogs:$id');
    return logEvents.stream;
  }
}

Future<void> _flushAsync() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _SdkRegistration {
  _SdkRegistration(this.sdk, this.services);

  final FakeMacLauncherSdk sdk;
  final Map<String, ServiceCallbacks> services;
}

class _FakeSdkFactory {
  final registrations = <_SdkRegistration>[];

  MacLauncherSdk call({
    required String projectId,
    required String projectName,
    required SdkEntry? entry,
    required Map<String, ServiceCallbacks> services,
  }) {
    final sdk = FakeMacLauncherSdk();
    registrations.add(_SdkRegistration(sdk, services));
    return sdk;
  }

  Future<void> close() async {
    for (final registration in registrations) {
      await registration.sdk.close();
    }
  }
}

class FakeSdkConnector {
  FakeSdkConnector(this.sdk);

  final FakeMacLauncherSdk sdk;
  String? projectId;
  String? projectName;
  Map<String, ServiceCallbacks>? services;

  MacLauncherSdk call({
    required String projectId,
    required String projectName,
    required SdkEntry? entry,
    required Map<String, ServiceCallbacks> services,
  }) {
    this.projectId = projectId;
    this.projectName = projectName;
    this.services = services;
    return sdk;
  }
}

class FakeMacLauncherSdk implements MacLauncherSdk {
  final _states = StreamController<SdkConnectionStatus>.broadcast();

  int disposeCalls = 0;

  @override
  Stream<SdkConnectionStatus> get states => _states.stream;

  void emit(SdkConnectionStatus status) {
    _states.add(status);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  Future<void> close() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError('${invocation.memberName}');
  }
}
