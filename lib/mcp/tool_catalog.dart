/// MCP 业务工具声明式注册表（单一事实来源，ADR-0001 / issue #29）。
///
/// 精简注册模式（2026-10-26 用户拍板）：MCP 只对外注册 `gcm_help` 与
/// `gcm_call` 两个工具，35 个业务工具不再逐个出现在 tools/list，改由本
/// 注册表描述、`gcm_call` 按名分发。每个工具的名称、域、title、
/// description、inputSchema、outputSchema、五字段注解与 meta 全部在
/// 条目里声明；gcm_help 渲染、gcm_call 分发前校验（ADR-0002）、各域
/// register 函数与测试全部从这里读取——不存在第二份手工目录。
///
/// handler（业务回调）因依赖 Service 层而留在 lib/mcp/tools/*.dart，
/// 经 [registerCatalogTool] 与条目元数据绑定注册。
library;

import 'package:mcp_dart/mcp_dart.dart';

import 'tool_registrar.dart';

const String _prefixPattern = r'^[a-z0-9][a-z0-9.-]{0,126}$';

/// 单个业务工具的注册表条目（gcm_help 输出、gcm_call 分发与校验、
/// register*Tools 注册的共同来源）。
class ToolCatalogEntry {
  const ToolCatalogEntry({
    required this.name,
    required this.domain,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.outputSchema,
    required this.annotations,
    this.meta,
  });

  final String name;
  final String domain;
  final String title;
  final String description;

  /// 业务参数 schema；gcm_call 在调 handler 前用它做分发前校验
  /// （mcp_dart 内建 JsonSchemaValidation，draft 2020-12）。
  final JsonObject inputSchema;

  /// 结构化结果 schema（structuredContent 的对外契约）。
  final JsonObject outputSchema;

  /// 五字段注解（title + readOnly/destructive/idempotent/openWorld
  /// 四个 hint）；规格 §3 约定所有工具 openWorldHint=true。
  final ToolAnnotations annotations;

  /// 透传到 Tool.meta 的扩展元数据；当前所有工具均为 null。
  final Map<String, Object?>? meta;

  /// gcm_help 目录输出形状（精简模式下 schema 不进 tools/list，
  /// 目录条目承载名称/描述/注解）。
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'domain': domain,
    'title': title,
    'description': description,
    'annotations': <String, Object?>{
      'readOnlyHint': annotations.readOnlyHint,
      'destructiveHint': annotations.destructiveHint,
      'idempotentHint': annotations.idempotentHint,
      'openWorldHint': annotations.openWorldHint,
    },
  };
}

/// 把注册表条目的全部声明与 [callback] 绑定注册到 [registrar]。
///
/// 各域 register*Tools 只提供 handler；schema/描述/注解一律取自主注册表。
/// 未知工具名直接抛 [ArgumentError]——注册表与注册代码不允许漂移。
void registerCatalogTool(
  ToolRegistrar registrar,
  String name, {
  required ToolFunction callback,
}) {
  final entry = catalogEntryByName(name);
  if (entry == null) {
    throw ArgumentError.value(name, 'name', '不在工具注册表中的工具名');
  }
  registrar.registerTool(
    entry.name,
    title: entry.title,
    description: entry.description,
    inputSchema: entry.inputSchema,
    outputSchema: entry.outputSchema,
    annotations: entry.annotations,
    meta: entry.meta,
    callback: callback,
  );
}

ToolAnnotations _annotations(
  String title, {
  bool readOnly = false,
  bool destructive = false,
  bool idempotent = false,
}) => ToolAnnotations(
  title: title,
  readOnlyHint: readOnly,
  destructiveHint: destructive,
  idempotentHint: idempotent,
  openWorldHint: true,
);

ToolAnnotations _readOnly(String title) =>
    _annotations(title, readOnly: true, idempotent: true);

/// 项目域定位参数（project 与 path 二选一），与 project_tools 原有声明一致。
JsonObject _selectorInput({
  Map<String, JsonSchema> properties = const <String, JsonSchema>{},
  List<String> required = const <String>[],
}) => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(
      description: '项目 prefix；与 path 二选一',
      pattern: _prefixPattern,
    ),
    'path': const JsonString(description: '项目目录；与 project 二选一'),
    ...properties,
  },
  required: required,
  additionalProperties: false,
);

JsonObject _composeRunOutput() => const JsonObject(
  properties: <String, JsonSchema>{
    'exitCode': JsonInteger(),
    'output': JsonString(),
    'truncated': JsonBoolean(),
  },
  required: ['exitCode', 'output', 'truncated'],
  additionalProperties: false,
);

JsonObject _projectDetailsOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'path': const JsonString(),
    'images': const JsonArray(items: JsonObject()),
    'containers': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'images', 'containers'],
);

JsonObject _projectBuildOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'image': const JsonString(),
    'testsPassed': const JsonBoolean(),
    'exitCode': const JsonInteger(),
    'durationMs': const JsonInteger(),
    'output': const JsonString(),
    'failureLogPath': const JsonString(),
  },
  required: ['project', 'image', 'exitCode', 'durationMs'],
);

JsonObject _projectReclaimOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'containers': const JsonObject(),
    'images': const JsonObject(),
    'disk': const JsonObject(),
    'errors': const JsonArray(items: JsonString()),
  },
  required: ['project', 'containers', 'images', 'disk', 'errors'],
);

JsonObject _projectPublishOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'pushed': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'pushed'],
);

JsonObject _projectRestoreOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'restored': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'restored'],
);

JsonObject _registryStatusOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'running': const JsonBoolean(),
    'port': const JsonInteger(),
    'containerId': const JsonString(),
    'diskBytes': const JsonInteger(),
  },
  required: ['running', 'port'],
);

const String _referenceDescription =
    '镜像引用，必须 name:tag（如 alpine:3.19，省略 tag 默认 :latest）。'
    '不支持 digest 寻址（apple/container#1962）。';

/// issue #31：全部列表工具统一的分页入参。limit 默认 50、上限 500；
/// 超出 [1, 500] 由 gcm_call 分发前的 schema 校验拒绝（INVALID_ARGUMENT），
/// 不做静默 clamp。offset 默认 0。
const Map<String, JsonSchema> _listPageInputProperties = <String, JsonSchema>{
  'limit': JsonInteger(
    description: '每页条数：默认 50，上限 500；超出 [1, 500] 报错（INVALID_ARGUMENT）',
    defaultValue: 50,
    minimum: 1,
    maximum: 500,
  ),
  'offset': JsonInteger(
    description: '跳过的条数（从 0 起）；翻页时传上一页响应的 nextOffset',
    defaultValue: 0,
    minimum: 0,
  ),
};

/// issue #31：全部列表工具统一的分页输出信封（列表键之外）。
const Map<String, JsonSchema> _listPageOutputProperties = <String, JsonSchema>{
  'total': JsonInteger(description: '过滤后的总条数'),
  'returned': JsonInteger(description: '本页实际返回的条数'),
  'hasMore': JsonBoolean(description: '是否还有下一页'),
  'nextOffset': JsonUnion([
    JsonInteger(),
    JsonNull(),
  ], description: '下一页的 offset；没有下一页时为 null'),
};

const List<String> _listPageRequired = <String>[
  'total',
  'returned',
  'hasMore',
  'nextOffset',
];

/// v1 业务工具注册表（35 个，与 docs/spec/mcp-tools.md §3 一一对应；
/// 域顺序即 gcm_help 目录顺序）。
final List<ToolCatalogEntry> kToolCatalog = [
  // ---- system（3）----
  ToolCatalogEntry(
    name: 'system_status',
    domain: 'system',
    title: 'Runtime Status',
    description:
        '返回 Apple container 运行时状态：五级就绪级别（未安装/版本低/主版本不兼容/'
        '服务未起/内核缺失/就绪）、CLI 与 apiserver 版本、版本是否受支持、'
        '服务状态与资源计数。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'level': const JsonString(
          description: '就绪级别',
          enumValues: [
            'notInstalled',
            'versionTooLow',
            'unsupportedMajor',
            'serviceNotRunning',
            'kernelMissing',
            'ready',
          ],
        ),
        'ready': const JsonBoolean(),
        'versionSupported': const JsonBoolean(
          description: '运行时版本是否通过基线（≥1.6.0）与大版本（1.x）门槛',
        ),
        'cliVersion': const JsonString(),
        'apiServerVersion': const JsonString(),
        'installPath': const JsonString(),
        'detail': const JsonString(),
        'debugBypass': const JsonBoolean(),
        'status': const JsonString(description: 'apiserver 状态，如 running'),
        'appRoot': const JsonString(),
        'installRoot': const JsonString(),
        'resources': const JsonObject(),
      },
      required: ['level', 'ready', 'versionSupported'],
    ),
    annotations: _readOnly('Runtime Status'),
  ),
  ToolCatalogEntry(
    name: 'system_start',
    domain: 'system',
    title: 'Start Runtime',
    description:
        '启动 Apple container 运行时（container system start，内核安装标志始终显式传递），'
        '随后轮询健康检查直到 apiserver 应答，并返回最新就绪级别。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'installKernel': JsonBoolean(
          description: '是否同时安装/更新默认内核（对应 --enable-kernel-install）',
          defaultValue: true,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'status': const JsonString(description: '启动后守护进程状态，如 running'),
        'kernelInstalled': const JsonBoolean(
          description: '请求安装内核时的安装结果；installKernel=false 时不返回',
        ),
        'startupMs': const JsonInteger(
          description: '从 CLI 调用到 apiserver 应答的耗时（毫秒）',
        ),
        'level': const JsonString(),
        'ready': const JsonBoolean(),
        'detail': const JsonString(),
      },
      required: ['status', 'level', 'ready'],
    ),
    annotations: _annotations('Start Runtime', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'system_stop',
    domain: 'system',
    title: 'Stop Runtime',
    description:
        '停止 Apple container 运行时（container system stop），'
        '运行中的容器随守护进程一并停止。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'status': const JsonString(description: '停止后守护进程状态，如 stopped'),
        'containersStopped': const JsonInteger(
          description: '随停止一并停下的运行中容器数（尽力统计）',
        ),
      },
      required: ['status', 'containersStopped'],
    ),
    annotations: _annotations(
      'Stop Runtime',
      destructive: true,
      idempotent: true,
    ),
  ),
  // ---- container（10）----
  ToolCatalogEntry(
    name: 'container_list',
    domain: 'container',
    title: 'List Containers',
    description:
        '列出 Apple container 容器（id/镜像/状态/标签/网络）。'
        'label 参数为精确 key=value 过滤（如 com.ghost233.compose.project=web）；'
        'all=false 时只返回运行中的容器。'
        '结果按 id 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'all': const JsonBoolean(description: '是否包含已停止的容器', defaultValue: true),
        'label': const JsonString(description: '精确标签过滤，格式 key=value'),
        'status': const JsonString(
          description: '按生命周期状态过滤',
          enumValues: ['unknown', 'stopped', 'running', 'stopping'],
        ),
        ..._listPageInputProperties,
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'containers': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'id': const JsonString(),
              'name': const JsonString(),
              'image': const JsonString(),
              'status': const JsonString(),
              'labels': const JsonObject(),
              'createdAt': const JsonString(),
              'networks': const JsonArray(),
            },
            required: ['id', 'name', 'image', 'status'],
          ),
        ),
        ..._listPageOutputProperties,
      },
      required: ['containers', ..._listPageRequired],
    ),
    annotations: _readOnly('List Containers'),
  ),
  ToolCatalogEntry(
    name: 'container_inspect',
    domain: 'container',
    title: 'Inspect Container',
    description:
        '返回单个容器的完整详情：状态、镜像、标签、网络、入口命令、环境变量、'
        '端口映射、停止信号与原始 configuration。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'container': const JsonObject()},
      required: ['container'],
    ),
    annotations: _readOnly('Inspect Container'),
  ),
  ToolCatalogEntry(
    name: 'container_stats',
    domain: 'container',
    title: 'Container Stats',
    description:
        '返回单个运行中容器的一次性资源快照（内存/CPU 微秒/网络/块设备/进程数）。'
        '需要速率时请自行轮询本工具（建议 2 秒间隔）。容器未运行时返回 CONFLICT 错误。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'stats': JsonObject(
          properties: <String, JsonSchema>{
            'id': const JsonString(),
            'memoryUsageBytes': const JsonInteger(),
            'memoryLimitBytes': const JsonInteger(),
            'memoryUtilization': const JsonNumber(),
            'cpuUsageUsec': const JsonInteger(),
            'networkRxBytes': const JsonInteger(),
            'networkTxBytes': const JsonInteger(),
            'blockReadBytes': const JsonInteger(),
            'blockWriteBytes': const JsonInteger(),
            'numProcesses': const JsonInteger(),
          },
          required: ['id'],
        ),
      },
      required: ['stats'],
    ),
    annotations: _readOnly('Container Stats'),
  ),
  ToolCatalogEntry(
    name: 'container_create',
    domain: 'container',
    title: 'Create Container',
    description:
        '从本地镜像创建容器，默认只创建不启动。镜像不存在时不会自动拉取；'
        'name 重名会返回 CONFLICT。env 是键值对象，ports 是 host/container 端口对象数组。'
        'mounts 定义主机目录挂载，labels 是字符串标签对象。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'name': const JsonString(description: '容器名称；省略时生成名称'),
        'image': const JsonString(description: '本地镜像引用，必填'),
        'command': const JsonArray(
          description: '覆盖镜像入口命令的参数数组',
          items: JsonString(),
        ),
        'env': const JsonObject(
          description: '环境变量键值对象，值会转换为 KEY=VALUE',
          additionalProperties: JsonString(),
        ),
        'ports': const JsonArray(
          description: '端口映射；proto 缺省为 tcp',
          items: JsonObject(
            properties: <String, JsonSchema>{
              'host': JsonInteger(minimum: 1, maximum: 65535),
              'container': JsonInteger(minimum: 1, maximum: 65535),
              'proto': JsonString(enumValues: ['tcp', 'udp']),
            },
            required: ['host', 'container'],
            additionalProperties: false,
          ),
        ),
        'network': const JsonString(description: '目标网络名称'),
        'mounts': const JsonArray(
          description: '主机目录挂载；target 必须是容器内绝对路径',
          items: JsonObject(
            properties: <String, JsonSchema>{
              'source': JsonString(description: '主机目录绝对路径'),
              'target': JsonString(description: '容器内挂载点绝对路径'),
              'readonly': JsonBoolean(
                description: '是否只读挂载',
                defaultValue: false,
              ),
            },
            required: ['source', 'target'],
            additionalProperties: false,
          ),
        ),
        'labels': const JsonObject(
          description: '容器标签；键和值均为字符串',
          additionalProperties: JsonString(),
        ),
        'start': const JsonBoolean(description: '创建后立即启动', defaultValue: false),
      },
      required: ['image'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'name': const JsonString(),
        'status': const JsonString(),
        'warnings': const JsonArray(items: JsonString()),
      },
      required: ['id', 'name', 'status', 'warnings'],
    ),
    annotations: _annotations('Create Container'),
  ),
  ToolCatalogEntry(
    name: 'container_start',
    domain: 'container',
    title: 'Start Container',
    description: '启动容器；已经处于 running 时幂等成功。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'status'],
    ),
    annotations: _annotations('Start Container', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'container_stop',
    domain: 'container',
    title: 'Stop Container',
    description:
        '优雅停止容器；默认等待 5 秒，超时由 runtime 发送 SIGKILL。'
        'stoppedGracefully 按已停止状态或停止调用是否短于 timeout 保守推导，'
        'runtime 不直接报告实际是否发生 SIGKILL 升级。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'timeoutSeconds': const JsonInteger(
          description: '优雅停止等待秒数，0 表示立即升级',
          defaultValue: 5,
          minimum: 0,
          maximum: 2147483647,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
        'stoppedGracefully': const JsonBoolean(),
      },
      required: ['id', 'status', 'stoppedGracefully'],
    ),
    annotations: _annotations('Stop Container', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'container_restart',
    domain: 'container',
    title: 'Restart Container',
    description: '按 stop 后 start 合成重启，非原子操作；停止超时时由 runtime 发送 SIGKILL。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'timeoutSeconds': const JsonInteger(
          description: '停止阶段的优雅等待秒数',
          defaultValue: 5,
          minimum: 0,
          maximum: 2147483647,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'status'],
    ),
    // issue #32：restart 标非幂等。MCP idempotentHint 的语义是「重复调用
    // 无额外效果」，而 restart 每次执行都是一个完整的 stop+start 周期
    // （合成、非原子），重复调用有额外效果（多一个重启周期）。失败后
    // 安全重试 ≠ 幂等。文档侧漂移（mcp-tools.md §3.1 标 I=✓、§5 幂等集
    // 含 restart、container-lifecycle.md §2 矩阵写「可安全重试」）已在
    // #32 交付回报记录，由 Lead 统一改文档。
    annotations: _annotations('Restart Container', idempotent: false),
  ),
  ToolCatalogEntry(
    name: 'container_kill',
    domain: 'container',
    title: 'Kill Container',
    description: '向容器主进程发送信号；signal 默认 KILL，也可为 TERM、INT、HUP 等。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'signal': const JsonString(
          description: 'Unix 信号名称',
          defaultValue: 'KILL',
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'signal': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'signal', 'status'],
    ),
    annotations: _annotations(
      'Kill Container',
      destructive: true,
      idempotent: true,
    ),
  ),
  ToolCatalogEntry(
    name: 'container_delete',
    domain: 'container',
    title: 'Delete Container',
    description:
        '删除容器。running 容器必须显式 force=true；stopping 容器即使 force 也会返回 CONFLICT，'
        '必须等待停止完成。重复删除不存在的容器按幂等成功处理。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'force': const JsonBoolean(
          description: '允许强制删除 running 容器，不绕过 stopping',
          defaultValue: false,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'deleted': const JsonBoolean(),
      },
      required: ['id', 'deleted'],
    ),
    annotations: _annotations(
      'Delete Container',
      destructive: true,
      idempotent: true,
    ),
  ),
  ToolCatalogEntry(
    name: 'container_exec',
    domain: 'container',
    title: 'Execute Container Command',
    description:
        '在运行中的容器内执行一次性非 TTY 命令。command 为 argv 数组，不经过 shell；'
        '分别返回 stdout/stderr（各最多 64 KiB）、退出码与截断标记。'
        '非零退出码是命令结果而非工具错误。timeoutSeconds 默认 60，最大 600。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '运行中容器 id'),
        'command': const JsonArray(
          description: '可执行文件及参数的 argv 数组',
          items: JsonString(),
        ),
        'timeoutSeconds': const JsonInteger(
          description: '等待命令退出的秒数',
          defaultValue: 60,
          minimum: 1,
          maximum: 600,
        ),
        'workdir': const JsonString(description: '容器内工作目录'),
        'env': const JsonObject(
          description: '覆盖容器环境变量的键值对象',
          additionalProperties: JsonString(),
        ),
      },
      required: ['id', 'command'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'exitCode': const JsonInteger(),
        'stdout': const JsonString(),
        'stderr': const JsonString(),
        'truncated': const JsonBoolean(),
      },
      required: ['exitCode', 'stdout', 'stderr', 'truncated'],
      additionalProperties: false,
    ),
    annotations: _annotations('Execute Container Command'),
  ),
  // ---- image（4）----
  ToolCatalogEntry(
    name: 'image_list',
    domain: 'image',
    title: 'List Images',
    description:
        '列出全部镜像（reference/digest/大小/创建时间）。tag 为 null 且 '
        'dangling=true 的是未被引用的悬空镜像（同名替换构建后的旧镜像）。'
        '结果按 reference 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: const JsonObject(
      properties: _listPageInputProperties,
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'images': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'reference': const JsonString(),
              'name': const JsonString(),
              'tag': const JsonString(),
              'digest': const JsonString(),
              'sizeBytes': const JsonInteger(),
              'createdAt': const JsonString(),
              'dangling': const JsonBoolean(),
            },
            required: ['reference', 'dangling'],
          ),
        ),
        ..._listPageOutputProperties,
      },
      required: ['images', ..._listPageRequired],
    ),
    annotations: _readOnly('List Images'),
  ),
  ToolCatalogEntry(
    name: 'image_inspect',
    domain: 'image',
    title: 'Inspect Image',
    description:
        '返回镜像的配置摘要：环境变量、入口命令、暴露端口、标签、层数、'
        '支持的平台与完整磁盘大小（非 descriptor 大小）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'image': JsonObject(
          properties: <String, JsonSchema>{
            'reference': const JsonString(),
            'digest': const JsonString(),
            'sizeBytes': const JsonInteger(),
            'layers': const JsonInteger(),
            'platforms': const JsonArray(),
            'config': const JsonObject(),
          },
          required: ['reference'],
        ),
      },
      required: ['image'],
    ),
    annotations: _readOnly('Inspect Image'),
  ),
  ToolCatalogEntry(
    name: 'image_delete',
    domain: 'image',
    title: 'Delete Image',
    description:
        '删除镜像（移除 tag；未被引用的层由运行时 GC 回收）。正被容器引用的'
        '镜像会被拒绝并列出引用它的容器（CONFLICT）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(),
        'deleted': const JsonBoolean(),
      },
      required: ['reference', 'deleted'],
    ),
    annotations: _annotations(
      'Delete Image',
      destructive: true,
      idempotent: true,
    ),
  ),
  ToolCatalogEntry(
    name: 'image_pull',
    domain: 'image',
    title: 'Pull Image',
    description:
        '拉取镜像到本地。长任务：通过 progress notification 汇报百分比/字节'
        '（桥接侧已折叠到 ~10Hz）；客户端取消会停止本地等待（上游无服务端'
        '取消路由，运行时可能在后台完成拉取）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
        'platform': const JsonString(
          description: '目标平台（如 linux/arm64、linux/amd64），缺省为本机架构',
        ),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(),
        'digest': const JsonString(),
        'sizeBytes': const JsonInteger(),
      },
      required: ['reference'],
    ),
    annotations: _annotations('Pull Image', idempotent: true),
  ),
  // ---- mount（2）----
  ToolCatalogEntry(
    name: 'mount_list',
    domain: 'mount',
    title: 'List Mounts',
    description:
        '聚合所有容器（含已停止）的挂载配置，按主机源路径归组。'
        '每个挂载给出类型（virtiofs/tmpfs）、主机路径与使用它的容器及容器内目标路径。'
        '结果按 name 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: const JsonObject(
      properties: _listPageInputProperties,
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'mounts': const JsonArray(),
        ..._listPageOutputProperties,
      },
      required: ['mounts', ..._listPageRequired],
    ),
    annotations: _readOnly('List Mounts'),
  ),
  ToolCatalogEntry(
    name: 'mount_inspect',
    domain: 'mount',
    title: 'Inspect Mount',
    description:
        '查看单个挂载的详情（按 mount_list 返回的 name，即主机源路径'
        '或 tmpfs:<目标路径>）。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'name': JsonString(description: '挂载名（主机源路径或 tmpfs:<目标路径>）'),
      },
      required: ['name'],
      additionalProperties: false,
    ),
    outputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'name': JsonString(),
        'type': JsonString(),
        'source': JsonString(),
        'readOnly': JsonBoolean(),
        'usedBy': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'containerId': JsonString(),
              'destination': JsonString(),
              'readOnly': JsonBoolean(),
            },
            required: ['containerId', 'destination', 'readOnly'],
            additionalProperties: false,
          ),
        ),
      },
      required: ['name', 'type', 'readOnly', 'usedBy'],
      additionalProperties: false,
    ),
    annotations: _readOnly('Inspect Mount'),
  ),
  // ---- network（2）----
  ToolCatalogEntry(
    name: 'network_list',
    domain: 'network',
    title: 'List Networks',
    description:
        '列出所有 container 网络（名称、子网、模式、是否内建、当前接入的容器数）。'
        '结果按 id 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: const JsonObject(
      properties: _listPageInputProperties,
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'networks': const JsonArray(),
        ..._listPageOutputProperties,
      },
      required: ['networks', ..._listPageRequired],
    ),
    annotations: _readOnly('List Networks'),
  ),
  ToolCatalogEntry(
    name: 'network_get',
    domain: 'network',
    title: 'Get Network',
    description:
        '查看单个网络的详情与接入的容器（id、IP、hostname）。'
        '参数 id 为 network_list 返回的网络 id。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'id': JsonString(description: '网络 id（如 default）'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'id': JsonString(),
        'plugin': JsonString(),
        'mode': JsonString(),
        'subnet': JsonString(),
        'gateway': JsonString(),
        'builtin': JsonBoolean(),
        'containerCount': JsonInteger(),
        'containers': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'id': JsonString(),
              'hostname': JsonString(),
              'ip': JsonString(),
            },
            required: ['id', 'hostname', 'ip'],
            additionalProperties: false,
          ),
        ),
      },
      required: [
        'id',
        'plugin',
        'mode',
        'builtin',
        'containerCount',
        'containers',
      ],
      additionalProperties: false,
    ),
    annotations: _readOnly('Get Network'),
  ),
  // ---- compose（3）----
  ToolCatalogEntry(
    name: 'compose_list',
    domain: 'compose',
    title: 'List Compose Projects',
    description:
        '按容器 label（com.compose.project / com.compose.service）聚合当前存在的 '
        'Compose 项目：项目名、服务清单、各服务对应容器与状态。'
        '插件只提供 up/down，项目发现走 label 聚合（不需要插件也可工作）。'
        '结果按 name 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: const JsonObject(
      properties: _listPageInputProperties,
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'projects': const JsonArray(),
        ..._listPageOutputProperties,
      },
      required: ['projects', ..._listPageRequired],
    ),
    annotations: _readOnly('List Compose Projects'),
  ),
  ToolCatalogEntry(
    name: 'compose_up',
    domain: 'compose',
    title: 'Compose Up',
    description:
        '运行 container compose up（需要本机已安装 compose 插件；未安装时返回'
        ' NOT_FOUND 与安装指引）。file 必须是绝对路径。输出为插件的人类可读文本'
        '原样透传（超长时保留尾部并标记 truncated）。'
        '可用 dryRun 只打印计划不改动任何资源。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'file': JsonString(description: 'compose 文件绝对路径'),
        'projectName': JsonString(description: '项目名（缺省取文件 name 或目录名）'),
        'dryRun': JsonBoolean(
          description: '只计算并打印计划，不创建/修改资源',
          defaultValue: false,
        ),
        'forceRecreate': JsonBoolean(
          description: '强制重建所有服务容器',
          defaultValue: false,
        ),
        'pull': JsonString(
          description: '镜像拉取策略',
          enumValues: ['missing', 'always', 'never'],
          defaultValue: 'missing',
        ),
      },
      required: ['file'],
      additionalProperties: false,
    ),
    outputSchema: _composeRunOutput(),
    annotations: _annotations('Compose Up', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'compose_down',
    domain: 'compose',
    title: 'Compose Down',
    description:
        '运行 container compose down，停止并移除项目的容器与其创建的网络'
        '（keepNetworks 可保留网络）。file 与 projectName 至少提供一项；'
        '输出为人类可读文本原样透传。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'file': JsonString(description: 'compose 文件绝对路径（与 projectName 至少一项）'),
        'projectName': JsonString(description: '项目名（与 file 至少一项）'),
        'keepNetworks': JsonBoolean(
          description: '保留项目创建的网络',
          defaultValue: false,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: _composeRunOutput(),
    annotations: _annotations(
      'Compose Down',
      destructive: true,
      idempotent: true,
    ),
  ),
  // ---- project（8）----
  ToolCatalogEntry(
    name: 'project_list',
    domain: 'project',
    title: 'List Projects',
    description:
        '列出容器 label 与 ghostcontainer.toml 发现的项目。'
        '结果按 project 升序；分页：limit（默认 50，上限 500，超限报错）+ '
        'offset（默认 0），响应带 total/returned/hasMore/nextOffset。',
    inputSchema: const JsonObject(
      properties: _listPageInputProperties,
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'projects': const JsonArray(items: JsonObject()),
        ..._listPageOutputProperties,
      },
      required: ['projects', ..._listPageRequired],
    ),
    annotations: _readOnly('List Projects'),
  ),
  ToolCatalogEntry(
    name: 'project_get',
    domain: 'project',
    title: 'Get Project',
    description: '返回项目镜像、容器与使用状态；project 与 path 二选一。',
    inputSchema: _selectorInput(),
    outputSchema: _projectDetailsOutput(),
    annotations: _readOnly('Get Project'),
  ),
  ToolCatalogEntry(
    name: 'project_init',
    domain: 'project',
    title: 'Init Project',
    description: '在项目目录创建仅含 prefix 的 ghostcontainer.toml。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'path': const JsonString(description: '项目目录'),
        'prefix': const JsonString(
          description: '项目前缀；默认使用目录名',
          pattern: _prefixPattern,
        ),
      },
      required: ['path'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'path': const JsonString(),
        'prefix': const JsonString(),
      },
      required: ['path', 'prefix'],
    ),
    annotations: _annotations('Init Project'),
  ),
  ToolCatalogEntry(
    name: 'project_build',
    domain: 'project',
    title: 'Build Project Image',
    description:
        '构建 {prefix}-{name}:latest。MCP 默认跳过测试；'
        '显式测试使用 project_test 的 command。失败返回末50行与持久日志路径。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(
          description: '镜像自定义名，不含项目前缀或 tag',
          pattern: _prefixPattern,
        ),
        'dockerfile': const JsonString(),
        'context': const JsonString(),
        'buildArgs': const JsonObject(additionalProperties: JsonString()),
        'skipTests': const JsonBoolean(defaultValue: true),
        'noCache': const JsonBoolean(defaultValue: false),
      },
      required: ['name'],
    ),
    outputSchema: _projectBuildOutput(),
    annotations: _annotations('Build Project Image'),
  ),
  ToolCatalogEntry(
    name: 'project_test',
    domain: 'project',
    title: 'Test Project Image',
    description: '用必传 command 运行一次性测试容器；非零退出是结果数据。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
        'command': const JsonArray(
          description: '测试命令及参数，必须是非空字符串数组',
          items: JsonString(),
        ),
      },
      required: ['name', 'command'],
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'project': const JsonString(),
        'image': const JsonString(),
        'exitCode': const JsonInteger(),
        'stdout': const JsonString(),
        'stderr': const JsonString(),
        'truncated': const JsonBoolean(),
        'durationMs': const JsonInteger(),
      },
      required: [
        'project',
        'image',
        'exitCode',
        'stdout',
        'stderr',
        'truncated',
        'durationMs',
      ],
    ),
    annotations: _annotations('Test Project Image'),
  ),
  ToolCatalogEntry(
    name: 'project_reclaim',
    domain: 'project',
    title: 'Reclaim Project',
    description: '停删项目容器并仅释放无引用项目镜像；dryRun 返回同构预演。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'dryRun': const JsonBoolean(defaultValue: false),
        'force': const JsonBoolean(defaultValue: true),
      },
    ),
    outputSchema: _projectReclaimOutput(),
    annotations: _annotations(
      'Reclaim Project',
      destructive: true,
      idempotent: true,
    ),
  ),
  ToolCatalogEntry(
    name: 'project_publish',
    domain: 'project',
    title: 'Publish Project Image',
    description: 'tag 并 plain-HTTP 推送到 127.0.0.1:5056，可选删除两个本地 tag。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
        'deleteLocal': const JsonBoolean(defaultValue: false),
      },
      required: ['name'],
    ),
    outputSchema: _projectPublishOutput(),
    annotations: _annotations('Publish Project Image', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'project_restore',
    domain: 'project',
    title: 'Restore Project Image',
    description: '从本地 plain-HTTP registry 拉回并 tag 回项目镜像名。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
      },
      required: ['name'],
    ),
    outputSchema: _projectRestoreOutput(),
    annotations: _annotations('Restore Project Image', idempotent: true),
  ),
  // ---- registry（3）----
  ToolCatalogEntry(
    name: 'registry_status',
    domain: 'registry',
    title: 'Get Registry Status',
    description: '读取本地 registry 容器、HTTP 健康、端口与数据目录占用。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: _registryStatusOutput(),
    annotations: _readOnly('Get Registry Status'),
  ),
  ToolCatalogEntry(
    name: 'registry_start',
    domain: 'registry',
    title: 'Start Local Registry',
    description: '幂等启动 127.0.0.1 上的 registry；首次会拉取并创建容器，保留已有数据。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'port': const JsonInteger(
          description: '宿主机 loopback 端口',
          defaultValue: 5056,
          minimum: 1,
          maximum: 65535,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'running': const JsonBoolean(),
        'port': const JsonInteger(),
        'containerId': const JsonString(),
      },
      required: ['running', 'port', 'containerId'],
    ),
    annotations: _annotations('Start Local Registry', idempotent: true),
  ),
  ToolCatalogEntry(
    name: 'registry_stop',
    domain: 'registry',
    title: 'Stop Local Registry',
    description: '停止 registry 容器，不删除容器或其持久化数据。',
    inputSchema: JsonObject(additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'running': const JsonBoolean()},
      required: ['running'],
    ),
    annotations: _annotations(
      'Stop Local Registry',
      destructive: true,
      idempotent: true,
    ),
  ),
];

/// 按域名分组（保持注册表声明顺序）。
Map<String, List<ToolCatalogEntry>> catalogByDomain() {
  final grouped = <String, List<ToolCatalogEntry>>{};
  for (final entry in kToolCatalog) {
    grouped.putIfAbsent(entry.domain, () => <ToolCatalogEntry>[]).add(entry);
  }
  return grouped;
}

/// 按名查找；未知名返回 null。
ToolCatalogEntry? catalogEntryByName(String name) {
  for (final entry in kToolCatalog) {
    if (entry.name == name) return entry;
  }
  return null;
}
