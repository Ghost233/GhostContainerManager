/// 网络页（ui-ia.md D7）：网络表（名称/子网/模式/容器数），行展开显示
/// 接入的成员容器。只读页，无写入口（网络创建于 v2）。
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/errors.dart';
import '../../services/network_service.dart';
import '../../ui/colors.dart';
import '../../ui/components.dart';
import '../../ui/text.dart';
import '../system/readiness_controller.dart';
import '../../app/placeholders.dart';
import '../../app/section_widgets.dart';

/// 网络页数据状态（页面级 ChangeNotifier）。
class NetworksController extends ChangeNotifier {
  NetworksController({required NetworkService service}) : _service = service;

  final NetworkService _service;

  List<NetworkInfo> networks = const [];

  /// 已展开网络的成员（按需加载，network_get）。
  final Map<String, List<NetworkMember>> members = {};
  bool loading = false;
  GcmException? lastError;

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    lastError = null;
    members.clear();
    notifyListeners();
    try {
      networks = await _service.listNetworks();
    } on GcmException catch (error) {
      lastError = error;
      networks = const [];
    } catch (error) {
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: error);
      networks = const [];
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 展开某网络时加载成员容器。
  Future<void> expand(String id) async {
    if (members.containsKey(id)) return;
    try {
      final detail = await _service.getNetwork(id);
      members[id] = detail.containers;
    } on GcmException catch (error) {
      lastError = error;
    } catch (error) {
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: error);
    }
    notifyListeners();
  }
}

class NetworksPage extends StatefulWidget {
  const NetworksPage({
    super.key,
    required this.service,
    required this.controller,
    required this.onOpenRuntime,
  });

  final NetworkService service;
  final ReadinessController controller;
  final VoidCallback onOpenRuntime;

  @override
  State<NetworksPage> createState() => _NetworksPageState();
}

class _NetworksPageState extends State<NetworksPage> {
  late final NetworksController _networks;

  @override
  void initState() {
    super.initState();
    _networks = NetworksController(service: widget.service);
    if (widget.controller.readiness?.ready ?? false) {
      unawaited(_networks.refresh());
    }
  }

  @override
  void dispose() {
    _networks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!(widget.controller.readiness?.ready ?? false)) {
      return PlaceholderSectionPage(
        title: '网络',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    return ListenableBuilder(
      listenable: _networks,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: '网络',
              subtitle: '只读视图（网络创建于后续版本）',
              loading: _networks.loading,
              onRefresh: _networks.refresh,
            ),
            if (_networks.lastError case final error?)
              SectionErrorBanner(error: error, onRetry: _networks.refresh),
            Expanded(
              child: _networks.loading && _networks.networks.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _networks.networks.isEmpty
                  ? Center(
                      child: Text('没有任何网络', style: theme.textTheme.bodyMedium),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final network in _networks.networks)
                          _NetworkTile(
                            network: network,
                            members: _networks.members[network.id],
                            onExpand: () =>
                                unawaited(_networks.expand(network.id)),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _NetworkTile extends StatelessWidget {
  const _NetworkTile({
    required this.network,
    required this.members,
    required this.onExpand,
  });

  final NetworkInfo network;
  final List<NetworkMember>? members;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        title: network.id,
        actions: [
          if (network.builtin)
            Text(
              '内建',
              style: theme.textTheme.bodySmall?.copyWith(
                color: GcmColors.textSecondary(context),
              ),
            ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _KvRow('模式', network.mode),
            _KvRow('子网', network.subnet ?? '无子网', mono: true),
            if (network.gateway != null)
              _KvRow('网关', network.gateway!, mono: true),
            _KvRow('容器数', '${network.containerCount} 个容器'),
            const SizedBox(height: 8),
            _MembersSection(members: members, onExpand: onExpand),
          ],
        ),
      ),
    );
  }
}

/// 成员容器区：展开加载 + 列表。
class _MembersSection extends StatefulWidget {
  const _MembersSection({required this.members, required this.onExpand});

  final List<NetworkMember>? members;
  final VoidCallback onExpand;

  @override
  State<_MembersSection> createState() => _MembersSectionState();
}

class _MembersSectionState extends State<_MembersSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = widget.members;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const Key('network-members-toggle'),
          onTap: () {
            if (!_expanded) widget.onExpand();
            setState(() => _expanded = !_expanded);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: GcmColors.textSecondary(context),
                ),
                const SizedBox(width: 4),
                Text(
                  '成员容器',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: GcmColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          if (members == null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '无容器接入',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: GcmColors.textSecondary(context),
                ),
              ),
            )
          else
            for (final member in members)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 14,
                      color: GcmColors.textSecondary(context),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 3,
                      child: CopyValue(value: member.containerId),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        member.hostname,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: member.address.isEmpty
                          ? Text('无 IP', style: theme.textTheme.bodySmall)
                          : CopyValue(value: member.address),
                    ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}

/// label 灰 + value 两列行。
class _KvRow extends StatelessWidget {
  const _KvRow(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: GcmColors.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: mono ? monoTextStyle(context) : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
