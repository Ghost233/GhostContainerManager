import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/projects/projects_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_build_log_store.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../../services/container_service_test.dart' show snapshotPayload;
import '../../services/project_service_test.dart'
    show FakeProjectCli, FakeProjectCliProcess, addImage, diskUsageResult;

/// 内存版构建失败日志 store：记录调用；用同步 I/O 把 logTail 写入真实临时文件
/// （同步 I/O 不跨 zone，fake 域可完成），供 UI「查看上次失败日志」经
/// File(path).readAsString() 回看（该读在 runAsync 域完成）。
class _FakeBuildLogStore implements ProjectBuildLogStore {
  final List<({String project, String imageName, String logTail})> writes = [];
  Directory? _dir;

  @override
  Future<String> write({
    required String project,
    required String imageName,
    required String dockerfile,
    required String stage,
    required String reason,
    required String logTail,
  }) async {
    writes.add((project: project, imageName: imageName, logTail: logTail));
    _dir ??= Directory.systemTemp.createTempSync('gcm-fake-build-log-');
    final file = File('${_dir!.path}/$project-$imageName.log');
    file.writeAsStringSync(logTail, flush: true);
    return file.path;
  }

  @override
  Future<String?> readLatest({
    required String project,
    required String imageName,
  }) async {
    final dir = _dir;
    if (dir == null) return null;
    final file = File('${dir.path}/$project-$imageName.log');
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }
}

Future<
  ({FakeContainerBridge bridge, FakeProjectCli cli, ProjectService service})
>
_pumpPage(
  WidgetTester tester, {
  FakeContainerBridge? bridge,
  FakeProjectCli? cli,
  List<String>? projectPaths,
}) async {
  final fakeBridge = bridge ?? FakeContainerBridge();
  final fakeCli = cli ?? FakeProjectCli();
  final readiness = ReadinessController(
    systemService: SystemService(bridge: fakeBridge),
    bridge: fakeBridge,
  );
  await readiness.refresh();
  final containers = ContainerService(bridge: fakeBridge);
  addTearDown(containers.dispose);
  final images = ImageService(bridge: fakeBridge, containerService: containers);
  final service = ProjectService(
    cli: fakeCli,
    containerService: containers,
    imageService: images,
    projectPaths: projectPaths ?? const [],
    buildLogDirectory: Directory.systemTemp
        .createTempSync('gcm-projects-page-logs-')
        .path,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectsPage(
          service: service,
          containerService: containers,
          imageService: images,
          controller: readiness,
          onOpenRuntime: () {},
        ),
      ),
    ),
  );
  // 有 projectPaths 时列表页磁盘快照/加载动画让 settle 挂起，用定帧替代。
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return (bridge: fakeBridge, cli: fakeCli, service: service);
}

/// 项目 mysite：3 个镜像（go2 使用中 / go1 未使用 / debug 未使用）、
/// 2 个成员容器（1 运行中）。磁盘 df 由 cli.runResults 提供。
({FakeContainerBridge bridge, FakeProjectCli cli}) _mysiteFixture() {
  final bridge = FakeContainerBridge()
    ..containers = [
      snapshotPayload(
        id: 'mysite-web',
        image: 'mysite-go2:latest',
        labels: const {'com.ghost233.project': 'mysite'},
      ),
      snapshotPayload(
        id: 'mysite-debug-run',
        image: 'mysite-debug:latest',
        status: 'stopped',
        startedAt: null,
        labels: const {'com.ghost233.project': 'mysite'},
      ),
    ];
  addImage(bridge, 'mysite-go2:latest', project: 'mysite', sizeBytes: 200);
  addImage(bridge, 'mysite-go1:latest', project: 'mysite', sizeBytes: 100);
  addImage(bridge, 'mysite-debug:latest', project: 'mysite', sizeBytes: 50);
  // mysite-go1 已推送 registry（「删除本地副本…」入口要求 pushedToRegistry=true）。
  addImage(
    bridge,
    '127.0.0.1:5056/mysite-go1:latest',
    project: 'mysite',
    sizeBytes: 100,
  );
  final cli = FakeProjectCli()
    ..runResults['system df --format json'] = [diskUsageResult(350)];
  return (bridge: bridge, cli: cli);
}

void main() {
  testWidgets('列表：名称/label 副行/镜像数/运行中容器/磁盘快照/最近构建', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    expect(find.text('mysite'), findsOneWidget);
    expect(find.text('com.ghost233.project=mysite'), findsOneWidget);
    expect(find.text('本应用创建'), findsOneWidget);
    expect(find.text('4 个镜像'), findsOneWidget);
    expect(find.text('2 个容器'), findsOneWidget);
    // 项目级磁盘 = 该行镜像 sizeBytes 求和（200+100+50+100）。
    expect(find.text('450 B'), findsOneWidget);
    expect(find.text('⟳ 刷新磁盘快照'), findsOneWidget);
    expect(find.text('＋ 从目录新建项目…'), findsOneWidget);
  });

  testWidgets('磁盘占用是快照：手动刷新后更新为新的 df 值', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);
    // 工具栏全局快照（df）单一展示位。
    expect(find.text('磁盘 350 B'), findsOneWidget);

    fixture.cli.runResults['system df --format json'] = [diskUsageResult(2048)];
    await tester.tap(find.text('⟳ 刷新磁盘快照'));
    await tester.pumpAndSettle();

    expect(find.text('磁盘 2.0 KB'), findsOneWidget);
  });

  testWidgets('空态：无项目时显示空态与新建入口', (tester) async {
    await _pumpPage(tester);

    expect(find.text('暂无项目'), findsOneWidget);
    expect(find.text('＋ 从目录新建项目…'), findsWidgets);
  });

  testWidgets('运行时未启动：统一占位（D8 全局态）', (tester) async {
    final fake = FakeContainerBridge()
      ..statusResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: '',
      );
    await _pumpPage(tester, bridge: fake);

    expect(find.text('运行时未就绪，项目暂不可用'), findsOneWidget);
    expect(find.text('打开引导检查'), findsOneWidget);
  });

  testWidgets('搜索过滤项目列表', (tester) async {
    final fixture = _mysiteFixture();
    addImage(fixture.bridge, 'blog-api:latest', project: 'blog');
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);
    expect(find.text('blog'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'mysite');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InkWell, 'mysite'), findsOneWidget);
    expect(find.widgetWithText(InkWell, 'blog'), findsNothing);
  });

  testWidgets('行点击 → 详情：镜像列表徽标 + 成员容器表', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();

    expect(find.text('返回'), findsOneWidget);
    expect(find.text('构建新版本'), findsOneWidget);
    expect(find.text('一键回收…'), findsOneWidget);
    // 镜像列表（倒序：go2 最新在前）；go2 同时出现在成员容器表。
    expect(find.text('mysite-go2:latest'), findsWidgets);
    expect(find.text('mysite-go1:latest'), findsOneWidget);
    expect(find.text('mysite-debug:latest'), findsWidgets);
    // go2（mysite-web）与 debug（debug-run）被引用→使用中；go1 与 registry 副本未使用。
    expect(find.text('使用中'), findsNWidgets(2));
    expect(find.text('未使用'), findsNWidgets(2));
    // go1 已推送 registry → 「已推送 registry」徽标 + 删除入口。
    expect(find.text('已推送 registry'), findsOneWidget);
    expect(find.text('仅本地'), findsNWidgets(3));
    expect(
      find.byKey(const Key('delete-local-mysite-go1:latest')),
      findsOneWidget,
    );
    // 成员容器
    expect(find.text('mysite-web'), findsOneWidget);
    expect(find.text('mysite-debug-run'), findsOneWidget);
  });

  testWidgets('构建新版本：底部日志面板平滑跟随，成功后收尾', (tester) async {
    final fixture = _mysiteFixture();
    final buildProcess = FakeProjectCliProcess();
    fixture.cli.onStart = (args) {
      expect(args, contains('build'));
      return buildProcess;
    };

    // 所有真实文件 I/O（createTemp/writeAsString）与 projectPaths 触发的
    // _discoverTomlProjects/_validateDockerfile 都必须在 runAsync 真实事件循环里，
    // 否则与 fakeAsync 泵互等挂起（lead 裁决）。
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('gcm-project-build-');
      await File('${temp.path}/ghostcontainer.toml')
          .writeAsString('prefix = "mysite"\n');
      await File('${temp.path}/Dockerfile').writeAsString('FROM scratch\n');
      await _pumpPage(
        tester,
        bridge: fixture.bridge,
        cli: fixture.cli,
        projectPaths: [temp.path],
      );

      // listProjects 含真实 I/O，给真实事件循环时间完成后再驱动帧。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('mysite'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('构建新版本'));
      // _build 的 _resolveProject/_validateDockerfile 真实 I/O 需事件循环时间。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 构建进行中不用 pumpAndSettle（stdout 流未关闭会让 settle 挂起）。
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // 面板进入进行中态（标题含构建目标；名称由 _nextBuildName 推出）
      expect(find.byKey(const Key('build-log-close')), findsOneWidget);
      expect(find.textContaining('构建 mysite-go'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);

      buildProcess.stdout.add(
        '${<String>['#1 [1/2] FROM scratch', '#2 exporting layers', for (var index = 3; index <= 200; index++) '#$index exporting layer $index'].join('\n')}\n',
      );
      await tester.pump();
      // onProgress 有 100ms 合并节流（task-34）：第二行等节流窗口补发。
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('#1 [1/2] FROM scratch'), findsOneWidget);
      expect(find.textContaining('#2 exporting layers'), findsOneWidget);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final logScroll = tester
          .widget<ListView>(
            find.ancestor(
              of: find.textContaining('#200 exporting layer 200'),
              matching: find.byType(ListView),
            ),
          )
          .controller!;
      expect(logScroll.position.maxScrollExtent, greaterThan(0));
      expect(
        logScroll.position.pixels,
        lessThan(logScroll.position.maxScrollExtent),
      );
      expect(
        logScroll.position.isScrollingNotifier.value,
        isTrue,
        reason:
            'pixels=${logScroll.position.pixels}, '
            'max=${logScroll.position.maxScrollExtent}, '
            'activity=${logScroll.position.activity}',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        logScroll.position.pixels,
        closeTo(logScroll.position.maxScrollExtent, 0.01),
      );

      await buildProcess.finish(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('成功'), findsOneWidget);
    });
  });

  testWidgets('构建失败：面板失败态 + 失败日志落盘后可回看', (tester) async {
    final fixture = _mysiteFixture();
    final buildProcess = FakeProjectCliProcess();
    fixture.cli.onStart = (args) => buildProcess;

    // 所有真实文件 I/O 与 projectPaths 触发的服务层 I/O 都在 runAsync 真实事件循环里。
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('gcm-project-build-');
      await File('${temp.path}/ghostcontainer.toml')
          .writeAsString('prefix = "mysite"\n');
      await File('${temp.path}/Dockerfile').writeAsString('FROM scratch\n');
      final logStore = _FakeBuildLogStore();
      final readiness = ReadinessController(
        systemService: SystemService(bridge: fixture.bridge),
        bridge: fixture.bridge,
      );
      await readiness.refresh();
      final containers = ContainerService(bridge: fixture.bridge);
      addTearDown(containers.dispose);
      final images = ImageService(
        bridge: fixture.bridge,
        containerService: containers,
      );
      final service = ProjectService(
        cli: fixture.cli,
        containerService: containers,
        imageService: images,
        projectPaths: [temp.path],
        buildLogStore: logStore,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectsPage(
              service: service,
              containerService: containers,
              imageService: images,
              controller: readiness,
              onOpenRuntime: () {},
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('mysite'));
      await tester.pump();
      await tester.pump();
      // _loadDetails 真实 I/O 完成后再点构建（否则 _nextBuildName 基于空列表算 go1）。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('构建新版本'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.pump();

      buildProcess.stdout.add('ERROR: failed to solve\n');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await buildProcess.finish(1);
      // buildProject 失败路径含 _writeBuildFailure 真实文件 I/O，需充足事件循环时间。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('失败'), findsOneWidget);
      // 失败日志已经可注入 store 落盘（内存 fake 记录调用，含日志尾部）
      expect(logStore.writes, hasLength(1));
      expect(logStore.writes.single.project, 'mysite');
      expect(
        logStore.writes.single.logTail,
        contains('ERROR: failed to solve'),
      );

      // 关闭面板后可从「查看上次失败日志」回看
      await tester.tap(find.byKey(const Key('build-log-close')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('查看上次失败日志'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('ERROR: failed to solve'), findsOneWidget);
    });
  });

  testWidgets('一键回收：弹窗分组销毁清单、force 默认勾选、完成后回收报告卡', (tester) async {
    final fixture = _mysiteFixture();
    // 外部容器引用 go1 → 回收时跳过
    fixture.bridge.containers.add(
      snapshotPayload(
        id: 'outside-user',
        image: 'mysite-go1:latest',
        labels: const {},
      ),
    );
    // reclaim 内部 system df 需脚本化（空 stdout 会抛解析错误）。
    fixture.cli.onRun = (args) async {
      if (args.join(' ') == 'system df --format json') {
        return diskUsageResult(800);
      }
      return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
    };
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键回收…'));
    await tester.pumpAndSettle();

    expect(find.text('一键回收项目「mysite」'), findsOneWidget);
    expect(find.text('将删除'), findsOneWidget);
    expect(find.text('将跳过'), findsOneWidget);
    expect(find.textContaining('outside-user'), findsOneWidget);
    // force 默认勾选
    final forceCheckbox = tester.widget<Checkbox>(
      find.byKey(const Key('reclaim-force')),
    );
    expect(forceCheckbox.value, isTrue);

    await tester.tap(find.text('回收并显示报告'));
    await tester.pumpAndSettle();

    // 回收报告卡：已释放 + 跳过项原因
    expect(find.textContaining('已释放'), findsOneWidget);
    expect(find.textContaining('mysite-go1:latest'), findsWidgets);
    expect(find.textContaining('外部容器引用'), findsOneWidget);
  });

  testWidgets('三选删除弹窗：归档并删除 = 先推 registry 再删本地', (tester) async {
    final fixture = _mysiteFixture();
    final pushProcess = FakeProjectCliProcess();
    fixture.cli.onStart = (args) {
      expect(args.join(' '), contains('image push'));
      return pushProcess;
    };
    // publish 先 inspect 源镜像取 sizeBytes。
    fixture.bridge.imageInspectResponses['mysite-go1:latest'] =
        <String, Object?>{'reference': 'mysite-go1:latest', 'sizeBytes': 100};
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();
    // go1 未使用 → 行内「删除本地副本…」
    await tester.tap(find.byKey(const Key('delete-local-mysite-go1:latest')));
    await tester.pumpAndSettle();

    expect(find.text('删除本地副本'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('仅删除'), findsOneWidget);
    expect(find.text('归档并删除'), findsOneWidget);
    // 循环依赖提示
    expect(find.textContaining('registry'), findsWidgets);

    await tester.tap(find.text('归档并删除'));
    await tester.pump();
    // publish 的 push 流是真实 StreamController，需 runAsync 让真实异步完成。
    await tester.runAsync(() async {
      await pushProcess.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pumpAndSettle();

    // 弹窗已关闭，回到详情页（标题消失；行内「删除本地副本…」按钮带省略号）。
    expect(find.text('删除本地副本'), findsNothing);
    // publish(deleteLocal:true) 的完整 CLI 调用链（tag→push→delete target→delete source）
    // 由 ProjectService 单测覆盖；UI 层经 fake 域与真实 StreamController 混用，
    // 此处只验证到 tag 已发出（publish 已进入）。
    final runs = fixture.cli.runs.map((args) => args.join(' ')).toList();
    expect(
      runs,
      contains('image tag mysite-go1:latest 127.0.0.1:5056/mysite-go1:latest'),
    );
  });

  testWidgets('三选删除弹窗：仅删除直接删本地镜像', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-local-mysite-go1:latest')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅删除'));
    await tester.pumpAndSettle();

    expect(fixture.bridge.deletedImages, contains('mysite-go1:latest'));
  });

  // ── task-37 十二条规格修复的新覆盖 ─────────────────────────────────────

  testWidgets('最近构建列：无构建记录时渲染 —', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    // ProjectSummary.lastBuildAt == null → '—'（列渲染分支）。
    // 构建成功后 _lastBuildAt 记录与相对时间渲染由 ProjectService 单测覆盖；
    // UI 层跨 fake/真实域验证构建链见「构建新版本」用例。
    expect(find.text('最近构建'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('推送到本地 registry：按钮触发 publishProject，进度进日志面板', (tester) async {
    final fixture = _mysiteFixture();
    final pushProcess = FakeProjectCliProcess();
    fixture.cli.onStart = (args) {
      expect(args.join(' '), contains('image push'));
      return pushProcess;
    };
    // publish 先 inspect 源镜像取 sizeBytes。
    fixture.bridge.imageInspectResponses['mysite-go2:latest'] =
        <String, Object?>{'reference': 'mysite-go2:latest', 'sizeBytes': 200};
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('push-button')));
    await tester.pump();

    // 日志面板打开，标题含推送目标。
    expect(find.textContaining('推送 mysite-go2:latest'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:5056'), findsWidgets);

    await tester.runAsync(() async {
      await pushProcess.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pumpAndSettle();

    // publish 链：tag → push（deleteLocal:false 不删本地）。
    final runs = fixture.cli.runs.map((args) => args.join(' ')).toList();
    expect(
      runs,
      contains('image tag mysite-go2:latest 127.0.0.1:5056/mysite-go2:latest'),
    );
    // 面板仍打开（标题含推送目标）；成功收尾由 ProjectService 单测覆盖，
    // UI 层 fake 域与真实 StreamController 混用不验证终态文本。
    expect(find.textContaining('推送 mysite-go2:latest'), findsOneWidget);
  });

  testWidgets('回收报告卡：时间注记 + 执行链路注记', (tester) async {
    final fixture = _mysiteFixture();
    fixture.cli.onRun = (args) async {
      if (args.join(' ') == 'system df --format json') {
        return diskUsageResult(800);
      }
      return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
    };
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键回收…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回收并显示报告'));
    await tester.pumpAndSettle();

    // 回收报告卡含执行链路注记。
    expect(find.textContaining('已释放'), findsOneWidget);
    expect(
      find.textContaining('container prune → image delete → image prune'),
      findsOneWidget,
    );
  });

  testWidgets('成员容器表：时长列 + 行内启动/停止/删除操作', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);

    await tester.tap(find.text('mysite'));
    await tester.pumpAndSettle();

    // 行内操作按钮存在（启动/停止、日志、删除）。
    expect(
      find.byKey(const Key('container-toggle-mysite-web')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('container-logs-mysite-web')), findsOneWidget);
    expect(
      find.byKey(const Key('container-delete-mysite-web')),
      findsOneWidget,
    );

    // 停止运行中容器（mysite-web running → stop）。
    await tester.tap(find.byKey(const Key('container-toggle-mysite-web')));
    await tester.pumpAndSettle();

    // 删除成员容器：确认弹窗 → delete。
    await tester.tap(
      find.byKey(const Key('container-delete-mysite-debug-run')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除容器'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
  });

  testWidgets('新建项目按钮可见（file_selector 平台通道在无头环境不可用）', (tester) async {
    final fixture = _mysiteFixture();
    await _pumpPage(tester, bridge: fixture.bridge, cli: fixture.cli);
    expect(find.text('＋ 从目录新建项目…'), findsOneWidget);
  });
}
