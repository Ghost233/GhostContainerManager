/// 网络页（ui-ia.md D7）：网络表（名称/子网/模式/容器数），行展开显示
/// 接入的成员容器。只读页，无写入口（网络创建于 v2）。
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/errors.dart';
import '../../services/network_service.dart';
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
    return ExpansionTile(
      onExpansionChanged: (expanded) {
        if (expanded) onExpand();
      },
      title: Row(
        children: [
          Expanded(child: Text(network.id, style: theme.textTheme.bodyMedium)),
          if (network.builtin)
            Text(
              '内建',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
      subtitle: Text(
        '${network.subnet ?? '无子网'} · ${network.mode} · '
        '${network.containerCount} 个容器',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        if (members == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (members!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('无容器接入', style: theme.textTheme.bodySmall),
          )
        else
          for (final member in members!)
            ListTile(
              dense: true,
              leading: const Icon(Icons.dns_outlined, size: 16),
              title: Text(member.containerId, style: theme.textTheme.bodySmall),
              subtitle: Text(
                '${member.hostname} · ${member.address.isEmpty ? '无 IP' : member.address}',
                style: theme.textTheme.bodySmall,
              ),
            ),
      ],
    );
  }
}
