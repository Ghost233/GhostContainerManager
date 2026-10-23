/// 挂载页（ui-ia.md D7）：跨容器聚合表，主机路径 → 使用方（容器:容器内路径）
/// + 读写。只读页，无任何写入口（v1 范围红线）。
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/errors.dart';
import '../../services/mount_service.dart';
import '../system/readiness_controller.dart';
import '../../app/placeholders.dart';
import '../../app/section_widgets.dart';

/// 挂载页数据状态（页面级 ChangeNotifier，随页面 State 生命周期）。
class MountsController extends ChangeNotifier {
  MountsController({required MountService service}) : _service = service;

  final MountService _service;

  List<MountInfo> mounts = const [];
  bool loading = false;
  GcmException? lastError;

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    lastError = null;
    notifyListeners();
    try {
      mounts = await _service.listMounts();
    } on GcmException catch (error) {
      lastError = error;
      mounts = const [];
    } catch (error) {
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: error);
      mounts = const [];
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}

class MountsPage extends StatefulWidget {
  const MountsPage({
    super.key,
    required this.service,
    required this.controller,
    required this.onOpenRuntime,
  });

  final MountService service;
  final ReadinessController controller;
  final VoidCallback onOpenRuntime;

  @override
  State<MountsPage> createState() => _MountsPageState();
}

class _MountsPageState extends State<MountsPage> {
  late final MountsController _mounts;

  @override
  void initState() {
    super.initState();
    _mounts = MountsController(service: widget.service);
    if (widget.controller.readiness?.ready ?? false) {
      unawaited(_mounts.refresh());
    }
  }

  @override
  void dispose() {
    _mounts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!(widget.controller.readiness?.ready ?? false)) {
      return PlaceholderSectionPage(
        title: '挂载',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    return ListenableBuilder(
      listenable: _mounts,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: '挂载',
          subtitle: '跨容器聚合视图 · 只读（挂载随容器配置管理）',
          loading: _mounts.loading,
          onRefresh: _mounts.refresh,
        ),
        if (_mounts.lastError case final error?)
          SectionErrorBanner(error: error, onRetry: _mounts.refresh),
        Expanded(
          child: _mounts.loading && _mounts.mounts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _mounts.mounts.isEmpty
              ? Center(
                  child: Text(
                    '当前没有容器配置任何挂载',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    for (final mount in _mounts.mounts) _MountRow(mount: mount),
                  ],
                ),
        ),
      ],
    );
  }
}

class _MountRow extends StatelessWidget {
  const _MountRow({required this.mount});

  final MountInfo mount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                mount.type == 'tmpfs'
                    ? Icons.memory_outlined
                    : Icons.folder_outlined,
                size: 16,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(mount.name, style: theme.textTheme.bodyMedium),
              ),
              Chip(
                label: Text(mount.fullyReadOnly ? '只读' : '可写'),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Text(
                mount.type,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          for (final usage in mount.usedBy)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                '${usage.containerId} : ${usage.destination}'
                '${usage.readOnly ? '（ro）' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}
