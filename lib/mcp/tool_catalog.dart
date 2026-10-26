/// MCP 工具目录（精简注册模式的单一事实来源）。
///
/// 精简模式（2026-10-26 用户拍板）：MCP 只对外注册 `gcm_help` 与
/// `gcm_call` 两个工具，35 个业务工具不再逐个出现在 tools/list，
/// 改由本目录描述、`gcm_call` 按名分发。本文件是唯一需要与
/// docs/spec/mcp-tools.md §3 保持同步的清单。
library;

/// 单个业务工具的目录条目（供 gcm_help 输出与 gcm_call 校验）。
class ToolCatalogEntry {
  const ToolCatalogEntry({
    required this.name,
    required this.domain,
    required this.title,
    required this.description,
    required this.readOnly,
    required this.destructive,
    required this.idempotent,
  });

  final String name;
  final String domain;
  final String title;
  final String description;
  final bool readOnly;
  final bool destructive;
  final bool idempotent;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'domain': domain,
    'title': title,
    'description': description,
    'annotations': <String, Object?>{
      'readOnlyHint': readOnly,
      'destructiveHint': destructive,
      'idempotentHint': idempotent,
      'openWorldHint': true,
    },
  };
}

/// v1 业务工具目录（35 个，与 docs/spec/mcp-tools.md §3 一一对应）。
const List<ToolCatalogEntry> kToolCatalog = [
  // ---- system（3）----
  ToolCatalogEntry(
    name: 'system_status',
    domain: 'system',
    title: 'Runtime Status',
    description: '运行时状态：五级就绪级别、CLI/apiserver 版本、资源计数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'system_start',
    domain: 'system',
    title: 'Start Runtime',
    description: '启动运行时。参数 installKernel?: bool（默认 true）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'system_stop',
    domain: 'system',
    title: 'Stop Runtime',
    description: '停止运行时（连带停止所有运行中容器）。参数 timeoutSeconds?: int（默认 20）。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  // ---- container（10）----
  ToolCatalogEntry(
    name: 'container_list',
    domain: 'container',
    title: 'List Containers',
    description: '列出容器。参数 all?: bool（默认 true）、label?: string、status?: enum。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_inspect',
    domain: 'container',
    title: 'Inspect Container',
    description: '单容器完整详情。参数 id: string（必）。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_stats',
    domain: 'container',
    title: 'Container Stats',
    description: '运行中容器的一次性资源快照。参数 id: string（必）。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_create',
    domain: 'container',
    title: 'Create Container',
    description: '创建容器（镜像须本地已有）。参数 image: string（必）；name?/command?/env?/ports?/mounts?/labels?/network?/start?: bool（默认 false）。',
    readOnly: false,
    destructive: false,
    idempotent: false,
  ),
  ToolCatalogEntry(
    name: 'container_start',
    domain: 'container',
    title: 'Start Container',
    description: '启动容器。参数 id: string（必）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_stop',
    domain: 'container',
    title: 'Stop Container',
    description: '优雅停止。参数 id（必）；timeoutSeconds?: int（默认 5）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_restart',
    domain: 'container',
    title: 'Restart Container',
    description: '重启（stop+start）。参数 id（必）；timeoutSeconds?。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_kill',
    domain: 'container',
    title: 'Kill Container',
    description: '发送信号。参数 id（必）；signal?: string（默认 "KILL"）。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_delete',
    domain: 'container',
    title: 'Delete Container',
    description: '删除容器。参数 id（必）；force?: bool（默认 false）。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'container_exec',
    domain: 'container',
    title: 'Execute Container Command',
    description: '容器内执行命令，一次性返回。参数 id、command: string[]（必）；timeoutSeconds?: int（默认 60，上限 600）；workdir?/env?。',
    readOnly: false,
    destructive: false,
    idempotent: false,
  ),
  // ---- image（4）----
  ToolCatalogEntry(
    name: 'image_list',
    domain: 'image',
    title: 'List Images',
    description: '列出镜像。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'image_inspect',
    domain: 'image',
    title: 'Inspect Image',
    description:
        '镜像详情（config/layers/platforms）。参数 reference: string（必，name:tag）。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'image_delete',
    domain: 'image',
    title: 'Delete Image',
    description: '删除镜像。参数 reference: string（必）。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'image_pull',
    domain: 'image',
    title: 'Pull Image',
    description: '拉取镜像（长操作）。参数 reference（必）；platform?: string。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  // ---- mount（2）----
  ToolCatalogEntry(
    name: 'mount_list',
    domain: 'mount',
    title: 'List Mounts',
    description: '列出挂载（上游 volume）。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'mount_inspect',
    domain: 'mount',
    title: 'Inspect Mount',
    description: '挂载详情。参数 name: string（必）。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  // ---- network（2）----
  ToolCatalogEntry(
    name: 'network_list',
    domain: 'network',
    title: 'List Networks',
    description: '列出网络。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'network_get',
    domain: 'network',
    title: 'Get Network',
    description: '网络详情。参数 id: string（必）。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  // ---- compose（3）----
  ToolCatalogEntry(
    name: 'compose_list',
    domain: 'compose',
    title: 'List Compose Projects',
    description: '按 label 聚合列出 Compose 项目。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'compose_up',
    domain: 'compose',
    title: 'Compose Up',
    description: '起 compose 项目（长操作）。参数 file: string（必）；projectName?/dryRun?/forceRecreate?/pull?: "missing"|"always"|"never"。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'compose_down',
    domain: 'compose',
    title: 'Compose Down',
    description:
        '停并删 compose 项目容器。参数 file 与 projectName 至少一项；keepNetworks?: bool。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  // ---- project（8）----
  ToolCatalogEntry(
    name: 'project_list',
    domain: 'project',
    title: 'List Projects',
    description: '列出项目。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'project_get',
    domain: 'project',
    title: 'Get Project',
    description: '项目详情。参数 project 与 path 二选一。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'project_init',
    domain: 'project',
    title: 'Init Project',
    description: '在项目目录生成 ghostcontainer.toml。参数 path: string（必）；prefix?。',
    readOnly: false,
    destructive: false,
    idempotent: false,
  ),
  ToolCatalogEntry(
    name: 'project_build',
    domain: 'project',
    title: 'Build Project Image',
    description: '单步构建链（长操作）。参数 project/path 二选一；name: string（必）；dockerfile?/context?/buildArgs?/skipTests?: bool（默认 true）/noCache?。',
    readOnly: false,
    destructive: false,
    idempotent: false,
  ),
  ToolCatalogEntry(
    name: 'project_test',
    domain: 'project',
    title: 'Test Project Image',
    description: '对指定镜像跑测试容器。参数 project/path 二选一；name（必）；command: string[]（必）。',
    readOnly: false,
    destructive: false,
    idempotent: false,
  ),
  ToolCatalogEntry(
    name: 'project_reclaim',
    domain: 'project',
    title: 'Reclaim Project',
    description: '项目回收：停删成员容器+释放未引用镜像，返回销毁清单。参数 project/path 二选一；dryRun?: bool（默认 false）；force?: bool（默认 true）。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'project_publish',
    domain: 'project',
    title: 'Publish Project Image',
    description: '推送项目镜像到本地 registry（长操作）。参数 project/path 二选一；name（必）；deleteLocal?: bool（默认 false）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'project_restore',
    domain: 'project',
    title: 'Restore Project Image',
    description: '从本地 registry 拉回镜像并 tag 回项目规约名。参数 project/path 二选一；name（必）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  // ---- registry（3）----
  ToolCatalogEntry(
    name: 'registry_status',
    domain: 'registry',
    title: 'Get Registry Status',
    description: '本地 registry 容器与健康状态。无参数。',
    readOnly: true,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'registry_start',
    domain: 'registry',
    title: 'Start Local Registry',
    description: '一键启动本地 registry（幂等）。参数 port?: int（默认 5056）。',
    readOnly: false,
    destructive: false,
    idempotent: true,
  ),
  ToolCatalogEntry(
    name: 'registry_stop',
    domain: 'registry',
    title: 'Stop Local Registry',
    description: '停止 registry（数据保留，会中断在途 push/pull）。无参数。',
    readOnly: false,
    destructive: true,
    idempotent: true,
  ),
];

/// 按域名分组（保持目录声明顺序）。
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
