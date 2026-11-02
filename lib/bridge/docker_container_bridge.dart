/// Docker-compatible runtime adapter. All commands inherit the user's Docker
/// context, DOCKER_HOST, TLS settings and credential configuration.
library;

// Public injection names are part of the test seam.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'container_bridge.dart';

typedef DockerCommandRunner = Future<BridgeCommandResult> Function(
  List<String> arguments,
  Duration timeout,
);

class DockerContainerBridge implements ContainerBridge {
  DockerContainerBridge({
    String? executable,
    DockerCommandRunner? runner,
    Future<Process> Function(List<String>)? processStarter,
  }) : _executable = executable,
       _runner = runner,
       _processStarter = processStarter;

  String? _executable;
  final DockerCommandRunner? _runner;
  final Future<Process> Function(List<String>)? _processStarter;
  final _pulls = <String, BridgeCliProcess>{};
  final _cancelled = <String>{};
  final _progress = StreamController<BridgeImagePullEvent>.broadcast();

  @override
  Future<String?> locateBinary({String? customPath}) async {
    for (final candidate in [
      ?customPath,
      ?_executable,
      ...?Platform.environment['PATH']?.split(':').map((p) => '$p/docker'),
      '/usr/local/bin/docker',
      '/opt/homebrew/bin/docker',
    ]) {
      if (await File(candidate).exists()) {
        _executable = candidate;
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<BridgeCommandResult> cliRun(
    List<String> arguments, {
    Duration? timeout,
  }) async {
    final limit = timeout ?? const Duration(seconds: 60);
    if (_runner != null) return _runner(arguments, limit);
    final process = cliStart(arguments);
    final out = StringBuffer(), err = StringBuffer();
    final stdout = process.stdoutLines.listen(out.writeln);
    final stderr = process.stderrLines.listen(err.writeln);
    var timedOut = false;
    final timer = Timer(limit, () {
      timedOut = true;
      unawaited(process.terminate());
    });
    try {
      final code = await process.exitCode;
      return BridgeCommandResult(
        exitCode: code,
        stdout: out.toString(),
        stderr: err.toString(),
        timedOut: timedOut,
      );
    } finally {
      timer.cancel();
      await stdout.cancel();
      await stderr.cancel();
    }
  }

  @override
  BridgeCliProcess cliStart(List<String> arguments) =>
      _DockerProcess(() => _launch(arguments));

  Future<Process> _launch(List<String> arguments) async {
    if (_processStarter != null) {
      return _processStarter(arguments);
    }
    final executable = _executable ?? await locateBinary();
    if (executable == null) {
      throw const BridgeCallException('Docker CLI not found');
    }
    return Process.start(
      executable,
      arguments,
      environment: {
        'PATH':
            '${Platform.environment['PATH'] ?? ''}:/usr/local/bin:/opt/homebrew/bin',
      },
    );
  }

  Future<Object?> _json(List<String> args) async {
    final result = await cliRun(args);
    if (!result.ok) throw BridgeCallException(result.combinedOutput.trim());
    try {
      return jsonDecode(result.stdout);
    } on FormatException {
      throw BridgeCallException(
        'Invalid Docker JSON: ${args.take(2).join(' ')}',
      );
    }
  }

  Future<void> _write(List<String> args) async {
    final result = await cliRun(args);
    if (!result.ok) throw BridgeCallException(result.combinedOutput.trim());
  }

  @override
  Future<BridgeCommandResult> systemVersion() =>
      cliRun(['version', '--format', '{{json .}}']);
  @override
  Future<BridgeCommandResult> systemStatus() =>
      cliRun(['info', '--format', '{{json .}}']);
  @override
  Future<BridgePingResult> ping() async {
    final result = await systemStatus();
    if (!result.ok) return BridgePingResult.failure(result.combinedOutput);
    final data = jsonDecode(result.stdout) as Map;
    return BridgePingResult.ok(
      apiServerVersion: data['ServerVersion'] as String?,
      appRoot: data['DockerRootDir'] as String?,
    );
  }

  @override
  Future<List<Map<String, Object?>>> containerList() async {
    final result = await cliRun([
      'container',
      'ls',
      '--all',
      '--quiet',
      '--no-trunc',
    ]);
    if (!result.ok) throw BridgeCallException(result.combinedOutput);
    final ids = result.stdout
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final rows = <Map<String, Object?>>[];
    // Bounded argv; deleted containers between list and inspect are surfaced.
    for (var i = 0; i < ids.length; i += 100) {
      final values = await _json([
        'container',
        'inspect',
        ...ids.skip(i).take(100),
      ]) as List;
      rows.addAll(
        values.map(
          (v) => normalizeContainer(Map<String, Object?>.from(v as Map)),
        ),
      );
    }
    return rows;
  }

  @override
  Future<Map<String, Object?>> containerInspect(String id) async {
    final values = await _json(['container', 'inspect', id]) as List;
    return normalizeContainer(Map<String, Object?>.from(values.single as Map));
  }

  static Map<String, Object?> normalizeContainer(Map<String, Object?> raw) {
    final config = (raw['Config'] as Map?) ?? {};
    final state = (raw['State'] as Map?) ?? {};
    final network = (raw['NetworkSettings'] as Map?) ?? {};
    final networks = (network['Networks'] as Map?) ?? {};
    final host = raw['HostConfig'] as Map? ?? {};
    final networkPorts = network['Ports'] as Map? ?? {};
    final ports = networkPorts.isEmpty
        ? host['PortBindings'] as Map? ?? {}
        : networkPorts;
    final command = [raw['Path'] ?? '', ...?raw['Args'] as List?];
    final status = state['Status'];
    return {
      'id': (raw['Name'] as String? ?? raw['Id'] as String? ?? '').replaceFirst(
        RegExp(r'^/'),
        '',
      ),
      'status': switch (status) {
        'running' || 'paused' || 'restarting' => 'running',
        'created' || 'exited' || 'dead' => 'stopped',
        _ => 'unknown',
      },
      'startedDate': state['StartedAt'],
      'configuration': {
        'docker': raw,
        'id': (raw['Name'] as String? ?? raw['Id'] as String? ?? '')
            .replaceFirst(RegExp(r'^/'), ''),
        'creationDate': raw['Created'],
        'image': {
          'reference': config['Image'],
          'descriptor': {'digest': raw['Image']},
        },
        'labels': config['Labels'] ?? {},
        'initProcess': {
          'executable': command.first,
          'arguments': command.skip(1).toList(),
          'environment': config['Env'] ?? [],
        },
        'mounts': [
          for (final m in (raw['Mounts'] as List? ?? []))
            {
              'type': {m['Type'] ?? 'bind': {}},
              'source': m['Type'] == 'volume'
                  ? m['Name']
                  : m['Type'] == 'tmpfs'
                  ? null
                  : m['Source'],
              'destination': m['Destination'],
              'options': [if (m['RW'] == false) 'ro'],
            },
        ],
        'publishedPorts': [
          for (final entry in ports.entries)
            for (final binding in entry.value as List? ?? [])
              {
                'hostAddress': binding['HostIp'],
                'hostPort': int.tryParse('${binding['HostPort']}') ?? 0,
                'containerPort':
                    int.tryParse(entry.key.toString().split('/').first) ?? 0,
                'proto': entry.key.toString().split('/').last,
              },
        ],
        'stopSignal': config['StopSignal'] ?? 'SIGTERM',
      },
      'networks': [
        for (final e in networks.entries)
          {
            'network': e.key,
            'hostname': config['Hostname'],
            'ipv4Address': e.value['IPAddress'],
            'ipv4Gateway': e.value['Gateway'],
          },
      ],
      'docker': raw,
    };
  }

  @override
  Future<void> containerCreate({
    required String id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
    List<Map<String, Object?>> mounts = const [],
    Map<String, String> labels = const {},
  }) => _write([
    'container',
    'create',
    '--name',
    id,
    for (final e in env) ...['--env', e],
    for (final p in ports) ...['--publish', p],
    if (network != null) ...['--network', network],
    for (final m in mounts) ...[
      '--mount',
      'type=bind,source=${m['source']},target=${m['target']}${m['readonly'] == true ? ',readonly' : ''}',
    ],
    for (final e in labels.entries) ...['--label', '${e.key}=${e.value}'],
    image,
    ...command,
  ]);
  @override
  Future<void> containerStart(String id) => _write(['container', 'start', id]);
  @override
  Future<bool> containerStop(String id, {int timeoutSeconds = 5}) async {
    await _write(['container', 'stop', '--time', '$timeoutSeconds', id]);
    return true;
  }

  @override
  Future<void> containerDelete(String id, {bool force = false}) =>
      _write(['container', 'rm', if (force) '--force', id]);
  @override
  Future<String> containerKill(String id, {String signal = 'KILL'}) async {
    await _write(['container', 'kill', '--signal', signal, id]);
    return (await containerInspect(id))['status'] as String;
  }

  @override
  Future<BridgeExecResult> containerExec({
    required String id,
    required List<String> command,
    List<String> env = const [],
    String? workdir,
    String? user,
    int timeoutSeconds = 60,
  }) async {
    final arguments = <String>[
      'container',
      'exec',
      for (final e in env) ...['--env', e],
      if (workdir != null) ...['--workdir', workdir],
      if (user != null) ...['--user', user],
      id,
      ...command,
    ];
    const cap = 65536;
    if (_runner != null) {
      final result = await cliRun(
        arguments,
        timeout: Duration(seconds: timeoutSeconds),
      );
      final out = utf8.encode(result.stdout), err = utf8.encode(result.stderr);
      return BridgeExecResult(
        exitCode: result.exitCode,
        stdout: utf8.decode(out.take(cap).toList(), allowMalformed: true),
        stderr: utf8.decode(err.take(cap).toList(), allowMalformed: true),
        stdoutTruncated: out.length > cap,
        stderrTruncated: err.length > cap,
        timedOut: result.timedOut,
      );
    }
    final Process process;
    try {
      process = await _launch(arguments);
    } catch (e) {
      throw BridgeCallException('$e');
    }
    await process.stdin.close();
    final out = <int>[], err = <int>[];
    var outSize = 0, errSize = 0;
    var timedOut = false;
    final a = process.stdout.listen((bytes) {
      outSize += bytes.length;
      out.addAll(bytes.take(cap - out.length));
    });
    final b = process.stderr.listen((bytes) {
      errSize += bytes.length;
      err.addAll(bytes.take(cap - err.length));
    });
    final drained = Future.wait([a.asFuture<void>(), b.asFuture<void>()]);
    Timer? force;
    final timer = Timer(Duration(seconds: timeoutSeconds), () {
      timedOut = true;
      process.kill();
      force = Timer(
        const Duration(seconds: 2),
        () => process.kill(ProcessSignal.sigkill),
      );
    });
    try {
      final code = await process.exitCode;
      await drained;
      return BridgeExecResult(
        exitCode: code,
        stdout: utf8.decode(out, allowMalformed: true),
        stderr: utf8.decode(err, allowMalformed: true),
        stdoutTruncated: outSize > cap,
        stderrTruncated: errSize > cap,
        timedOut: timedOut,
      );
    } finally {
      timer.cancel();
      force?.cancel();
      await a.cancel();
      await b.cancel();
    }
  }

  @override
  Stream<BridgeLogEvent> containerLogs(String id) async* {
    final process = cliStart([
      'container',
      'logs',
      '--follow',
      '--timestamps',
      id,
    ]);
    final events = StreamController<BridgeLogEvent>();
    final a = process.stdoutLines.listen(
      (s) => events.add(
        BridgeLogEvent.data(source: 'stdout', bytes: utf8.encode('$s\n')),
      ),
    );
    final b = process.stderrLines.listen(
      (s) => events.add(
        BridgeLogEvent.data(source: 'stderr', bytes: utf8.encode('$s\n')),
      ),
    );
    unawaited(
      process.exitCode.then((code) {
        if (code != 0) {
          events.add(BridgeLogEvent.error('docker logs exit $code'));
        }
        events.add(const BridgeLogEvent.eof());
        return events.close();
      }),
    );
    try {
      yield* events.stream;
    } finally {
      await process.terminate();
      await a.cancel();
      await b.cancel();
    }
  }

  @override
  Future<Map<String, Object?>> containerStats(String id) async {
    final raw = await _json([
      'container',
      'stats',
      '--no-stream',
      '--format',
      '{{json .}}',
      id,
    ]) as Map;
    final mem = '${raw['MemUsage']}'.split('/');
    final net = '${raw['NetIO']}'.split('/');
    final block = '${raw['BlockIO']}'.split('/');
    return {
      'id': id,
      'memoryUsageBytes': parseSize(mem.first),
      'memoryLimitBytes': mem.length > 1 ? parseSize(mem[1]) : null,
      'networkRxBytes': parseSize(net.first),
      'networkTxBytes': net.length > 1 ? parseSize(net[1]) : null,
      'blockReadBytes': parseSize(block.first),
      'blockWriteBytes': block.length > 1 ? parseSize(block[1]) : null,
      'numProcesses': int.tryParse('${raw['PIDs']}'),
      'cpuPercent': double.tryParse('${raw['CPUPerc']}'.replaceAll('%', '')),
    };
  }

  static int? parseSize(String raw) {
    final m = RegExp(
      r'^\s*([\d.]+)\s*([KMGT]?i?B)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m == null) return null;
    final unit = m[2]!.toUpperCase();
    final power = {
      'B': 0,
      'KB': 1,
      'KIB': 1,
      'MB': 2,
      'MIB': 2,
      'GB': 3,
      'GIB': 3,
      'TB': 4,
      'TIB': 4,
    }[unit]!;
    var factor = 1;
    for (var i = 0; i < power; i++) {
      factor *= unit.contains('I') ? 1024 : 1000;
    }
    return (double.parse(m[1]!) * factor).round();
  }

  @override
  Future<BridgeCommandResult> networkList() async {
    final result = await cliRun(['network', 'ls', '--quiet']);
    if (!result.ok) return result;
    final ids = result.stdout
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (ids.isEmpty) {
      return const BridgeCommandResult(exitCode: 0, stdout: '[]', stderr: '');
    }
    return cliRun(['network', 'inspect', ...ids]);
  }

  @override
  Future<BridgeCommandResult> networkInspect(String id) =>
      cliRun(['network', 'inspect', id]);
  @override
  Future<BridgeCommandResult> composeHelp() => cliRun(['compose', '--help']);
  @override
  Future<BridgeCommandResult> composeRun(
    List<String> arguments, {
    Duration? timeout,
  }) => cliRun([
    'compose',
    ...arguments,
  ], timeout: timeout ?? const Duration(minutes: 10));
  @override
  Future<List<Map<String, Object?>>> imageList() async {
    final result = await cliRun([
      'image',
      'ls',
      '--all',
      '--quiet',
      '--no-trunc',
    ]);
    if (!result.ok) throw BridgeCallException(result.combinedOutput);
    final ids = result.stdout
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toSet();
    final rows = <Map<String, Object?>>[];
    for (final id in ids) {
      final raw = (await _json(['image', 'inspect', id]) as List).single as Map;
      final tags = (raw['RepoTags'] as List? ?? [])
          .where((t) => t != '<none>:<none>')
          .toList();
      for (final tag in tags.isEmpty ? [id] : tags) {
        rows.add({
          'reference': tag,
          'digest': raw['Id'],
          'sizeBytes': raw['Size'],
          'createdAt': raw['Created'],
        });
      }
    }
    return rows;
  }

  @override
  Future<Map<String, Object?>> imageInspect(String reference) async {
    final raw =
        (await _json(['image', 'inspect', reference]) as List).single as Map;
    final config = raw['Config'] as Map? ?? {};
    return {
      'reference': reference,
      'digest': raw['Id'],
      'sizeBytes': raw['Size'],
      'layers': (raw['RootFS']?['Layers'] as List? ?? []).length,
      'platforms': ['${raw['Os']}/${raw['Architecture']}'],
      'config': {
        'env': config['Env'] ?? [],
        'entrypoint': config['Entrypoint'] ?? [],
        'cmd': config['Cmd'] ?? [],
        'exposedPorts': (config['ExposedPorts'] as Map? ?? {}).keys.toList(),
        'labels': config['Labels'] ?? {},
      },
    };
  }

  @override
  Future<void> imageDelete(String reference) =>
      _write(['image', 'rm', reference]);
  @override
  Future<Map<String, Object?>> imagePull({
    required String pullId,
    required String reference,
    String? platform,
  }) async {
    final process = cliStart([
      'image',
      'pull',
      if (platform != null) ...['--platform', platform],
      reference,
    ]);
    _pulls[pullId] = process;
    final messages = StringBuffer();
    void progress(String line) {
      messages.writeln(line);
      _progress.add(BridgeImagePullEvent(pullId: pullId, description: line));
    }

    final a = process.stdoutLines.listen(progress),
        b = process.stderrLines.listen(progress);
    try {
      final code = await process.exitCode;
      if (_cancelled.remove(pullId)) {
        return {'reference': reference, 'cancelled': true};
      }
      if (code != 0) throw BridgeCallException(messages.toString());
      return await imageInspect(reference);
    } finally {
      _pulls.remove(pullId);
      await a.cancel();
      await b.cancel();
    }
  }

  @override
  Future<void> imagePullCancel(String pullId) async {
    final p = _pulls[pullId];
    if (p != null) {
      _cancelled.add(pullId);
      await p.terminate();
    }
  }

  @override
  Stream<BridgeImagePullEvent> imagePullEvents() => _progress.stream;
}

class _DockerProcess implements BridgeCliProcess {
  _DockerProcess(Future<Process> Function() launch) {
    _exit = _run(launch);
  }
  final _stdout = _ReplayLines(), _stderr = _ReplayLines();
  Process? _process;
  bool _terminated = false;
  late final Future<int> _exit;
  Future<int> _run(Future<Process> Function() launch) async {
    try {
      final p = await launch();
      await p.stdin.close();
      _process = p;
      if (_terminated) p.kill();
      final out = p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_stdout.add);
      final err = p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_stderr.add);
      final drained = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
      final code = await p.exitCode;
      await drained;
      return code;
    } catch (e) {
      _stderr.add('$e');
      return 127;
    } finally {
      _process = null;
      _stdout.close();
      _stderr.close();
    }
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;
  @override
  Stream<String> get stderrLines => _stderr.stream;
  @override
  Future<int> get exitCode => _exit;
  @override
  Future<void> terminate() async {
    _terminated = true;
    final p = _process;
    if (p == null) return;
    p.kill();
    final timer = Timer(
      const Duration(seconds: 2),
      () => p.kill(ProcessSignal.sigkill),
    );
    try {
      await _exit;
    } finally {
      timer.cancel();
    }
  }
}

class _ReplayLines {
  final _lines = <String>[];
  final _events = StreamController<String>.broadcast(sync: true);
  bool _done = false;
  Stream<String> get stream => Stream<String>.multi((sink) {
    for (final line in _lines) {
      sink.addSync(line);
    }
    if (_done) {
      sink.closeSync();
      return;
    }
    final sub = _events.stream.listen(sink.addSync, onDone: sink.closeSync);
    sink.onCancel = sub.cancel;
  });
  void add(String line) {
    _lines.add(line);
    if (_lines.length > 5000) {
      _lines.removeAt(0);
    }
    _events.add(line);
  }

  void close() {
    _done = true;
    unawaited(_events.close());
  }
}
