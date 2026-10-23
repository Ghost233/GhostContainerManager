/// Confirmation and create dialogs for container lifecycle actions.
library;

import 'package:flutter/material.dart';

import '../../services/container_models.dart';

class ContainerCreateDraft {
  const ContainerCreateDraft({
    required this.id,
    required this.image,
    required this.command,
    required this.env,
    required this.ports,
    required this.network,
    required this.start,
  });

  final String? id;
  final String image;
  final List<String> command;
  final List<String> env;
  final List<String> ports;
  final String? network;
  final bool start;
}

Future<ContainerCreateDraft?> showContainerCreateDialog(BuildContext context) {
  return showDialog<ContainerCreateDraft>(
    context: context,
    builder: (context) => const _CreateContainerDialog(),
  );
}

Future<bool> showContainerConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmText,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 432, child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmText),
            ),
          ],
        ),
      ) ??
      false;
}

/// Returns null on cancel; otherwise the requested force value.
Future<bool?> showContainerDeleteConfirmation(
  BuildContext context,
  ContainerSnapshotInfo container,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _DeleteContainerDialog(container: container),
  );
}

class _DeleteContainerDialog extends StatefulWidget {
  const _DeleteContainerDialog({required this.container});

  final ContainerSnapshotInfo container;

  @override
  State<_DeleteContainerDialog> createState() => _DeleteContainerDialogState();
}

class _DeleteContainerDialogState extends State<_DeleteContainerDialog> {
  bool _force = false;

  @override
  Widget build(BuildContext context) {
    final running = widget.container.state == ContainerState.running;
    return AlertDialog(
      title: const Text('删除容器'),
      content: SizedBox(
        width: 432,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('确定删除容器「${widget.container.id}」吗？此操作不可撤销。'),
            if (running) ...[
              const SizedBox(height: 12),
              const Text('容器正在运行，必须显式允许强制删除。'),
              CheckboxListTile(
                value: _force,
                onChanged: (value) => setState(() => _force = value ?? false),
                title: const Text('强制停止并删除'),
                subtitle: const Text('默认不勾选；停止中的容器仍不能删除'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: running && !_force
              ? null
              : () => Navigator.of(context).pop(_force),
          child: const Text('删除'),
        ),
      ],
    );
  }
}

class _CreateContainerDialog extends StatefulWidget {
  const _CreateContainerDialog();

  @override
  State<_CreateContainerDialog> createState() => _CreateContainerDialogState();
}

class _CreateContainerDialogState extends State<_CreateContainerDialog> {
  final _name = TextEditingController();
  final _image = TextEditingController();
  final _command = TextEditingController();
  final _env = TextEditingController();
  final _ports = TextEditingController();
  final _network = TextEditingController();
  bool _start = false;
  bool _validateImage = false;

  @override
  void dispose() {
    _name.dispose();
    _image.dispose();
    _command.dispose();
    _env.dispose();
    _ports.dispose();
    _network.dispose();
    super.dispose();
  }

  List<String> _lines(String value) => value
      .split(RegExp(r'[\n,]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  void _submit() {
    final image = _image.text.trim();
    setState(() => _validateImage = image.isEmpty);
    if (image.isEmpty) return;
    final name = _name.text.trim();
    final network = _network.text.trim();
    Navigator.of(context).pop(
      ContainerCreateDraft(
        id: name.isEmpty ? null : name,
        image: image,
        command: _command.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((part) => part.isNotEmpty)
            .toList(growable: false),
        env: _lines(_env.text),
        ports: _ports.text
            .split(RegExp(r'[\s,]+'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList(growable: false),
        network: network.isEmpty ? null : network,
        start: _start,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建容器'),
      content: SizedBox(
        width: 432,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('create-name-field'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称（可选）',
                  hintText: '省略时自动生成',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-image-field'),
                controller: _image,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '镜像',
                  hintText: 'nginx:latest（仅本地镜像）',
                  errorText: _validateImage ? '请输入本地镜像引用' : null,
                ),
                onChanged: (_) {
                  if (_validateImage) setState(() => _validateImage = false);
                },
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-command-field'),
                controller: _command,
                decoration: const InputDecoration(
                  labelText: '命令（空格分隔）',
                  hintText: '覆盖镜像默认命令',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-env-field'),
                controller: _env,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '环境变量（每行 KEY=VALUE）',
                  hintText: 'MODE=production',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-ports-field'),
                controller: _ports,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '端口映射（每行 host:container/proto）',
                  hintText: '8080:80/tcp',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-network-field'),
                controller: _network,
                decoration: const InputDecoration(labelText: '网络（可选）'),
              ),
              CheckboxListTile(
                value: _start,
                onChanged: (value) => setState(() => _start = value ?? false),
                title: const Text('创建后立即启动'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}
