/// Confirmation and create dialogs for container lifecycle actions.
library;

import 'package:flutter/material.dart' hide ImageInfo;

import '../../services/container_models.dart';
import '../../services/image_models.dart';

class ContainerCreateDraft {
  const ContainerCreateDraft({
    required this.id,
    required this.image,
    required this.command,
    required this.env,
    required this.ports,
    required this.network,
    required this.mounts,
    required this.labels,
    required this.start,
  });

  final String? id;
  final String image;
  final List<String> command;
  final List<String> env;
  final List<String> ports;
  final String? network;
  final List<Map<String, Object?>> mounts;
  final Map<String, String> labels;
  final bool start;
}

Future<ContainerCreateDraft?> showContainerCreateDialog(
  BuildContext context, {
  required Future<List<ImageInfo>> Function() loadLocalImages,
}) {
  return showDialog<ContainerCreateDraft>(
    context: context,
    builder: (context) =>
        _CreateContainerDialog(loadLocalImages: loadLocalImages),
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
          content: SizedBox(width: 480, child: Text(message)),
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
        width: 480,
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
  const _CreateContainerDialog({required this.loadLocalImages});

  final Future<List<ImageInfo>> Function() loadLocalImages;

  @override
  State<_CreateContainerDialog> createState() => _CreateContainerDialogState();
}

class _CreateContainerDialogState extends State<_CreateContainerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _env = TextEditingController();
  final _ports = TextEditingController();
  final _network = TextEditingController();
  final _mounts = TextEditingController();
  final _labels = TextEditingController();
  late Future<List<ImageInfo>> _localImages;
  String? _imageReference;
  bool _start = false;

  @override
  void initState() {
    super.initState();
    _localImages = widget.loadLocalImages();
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _env.dispose();
    _ports.dispose();
    _network.dispose();
    _mounts.dispose();
    _labels.dispose();
    super.dispose();
  }

  List<String> _lines(String value) => value
      .split('\n')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  List<String> _portEntries(String value) => value
      .split(RegExp(r'[\n,]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  bool _validPort(String value) {
    final match = RegExp(
      r'^(\d{1,5}):(\d{1,5})(?:/(tcp|udp))?$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return false;
    final host = int.tryParse(match.group(1)!);
    final container = int.tryParse(match.group(2)!);
    return host != null &&
        container != null &&
        host >= 1 &&
        host <= 65535 &&
        container >= 1 &&
        container <= 65535;
  }

  String? _validatePorts(String? value) {
    final entries = _portEntries(value ?? '');
    for (var index = 0; index < entries.length; index += 1) {
      if (!_validPort(entries[index])) {
        return '第 ${index + 1} 个端口无效：须为 host:container[/tcp|udp]，'
            '范围 1–65535';
      }
    }
    return null;
  }

  List<String> _parseCommand(String value) {
    final result = <String>[];
    final current = StringBuffer();
    String? quote;
    var escaping = false;
    var tokenStarted = false;

    for (final character in value.characters) {
      if (escaping) {
        current.write(character);
        escaping = false;
        tokenStarted = true;
        continue;
      }
      if (character == '\\' && quote != "'") {
        escaping = true;
        tokenStarted = true;
        continue;
      }
      if (quote != null) {
        if (character == quote) {
          quote = null;
        } else {
          current.write(character);
        }
        continue;
      }
      if (character == '"' || character == "'") {
        quote = character;
        tokenStarted = true;
      } else if (character.trim().isEmpty) {
        if (tokenStarted) {
          result.add(current.toString());
          current.clear();
          tokenStarted = false;
        }
      } else {
        current.write(character);
        tokenStarted = true;
      }
    }
    if (escaping) current.write('\\');
    if (quote != null) throw const FormatException('命令存在未闭合引号');
    if (tokenStarted) result.add(current.toString());
    return result;
  }

  List<Map<String, Object?>> _parseMounts(String value) {
    final result = <Map<String, Object?>>[];
    final entries = _lines(value);
    for (var index = 0; index < entries.length; index += 1) {
      final parts = entries[index].split(':');
      final readonly = parts.length == 3 && parts[2].trim() == 'ro';
      if (parts.length < 2 ||
          parts.length > 3 ||
          (parts.length == 3 && !readonly) ||
          parts[0].trim().isEmpty ||
          !parts[1].trim().startsWith('/')) {
        throw FormatException(
          '第 ${index + 1} 个挂载无效：须为 source:/absolute/target[:ro]',
        );
      }
      result.add(<String, Object?>{
        'source': parts[0].trim(),
        'target': parts[1].trim(),
        'readonly': readonly,
      });
    }
    return result;
  }

  Map<String, String> _parseLabels(String value) {
    final result = <String, String>{};
    final entries = _lines(value);
    for (var index = 0; index < entries.length; index += 1) {
      final separator = entries[index].indexOf('=');
      if (separator <= 0) {
        throw FormatException('第 ${index + 1} 个标签无效：须为 KEY=VALUE');
      }
      final key = entries[index].substring(0, separator).trim();
      if (key.isEmpty) {
        throw FormatException('第 ${index + 1} 个标签的 KEY 不能为空');
      }
      result[key] = entries[index].substring(separator + 1).trim();
    }
    return result;
  }

  String? _validateCommand(String? value) {
    try {
      _parseCommand(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  String? _validateMounts(String? value) {
    try {
      _parseMounts(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  String? _validateLabels(String? value) {
    try {
      _parseLabels(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _name.text.trim();
    final network = _network.text.trim();
    Navigator.of(context).pop(
      ContainerCreateDraft(
        id: name.isEmpty ? null : name,
        image: _imageReference!,
        command: _parseCommand(_command.text),
        env: _lines(_env.text),
        ports: _portEntries(_ports.text),
        network: network.isEmpty ? null : network,
        mounts: _parseMounts(_mounts.text),
        labels: _parseLabels(_labels.text),
        start: _start,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 10),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _imagePicker() {
    return FutureBuilder<List<ImageInfo>>(
      future: _localImages,
      builder: (context, snapshot) {
        final images = snapshot.data ?? const <ImageInfo>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('create-image-field'),
              initialValue: _imageReference,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '本地镜像',
                hintText: '选择已拉取的镜像',
              ),
              items: images
                  .map(
                    (image) => DropdownMenuItem<String>(
                      value: image.reference,
                      child: Text(
                        image.reference,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: images.isEmpty
                  ? null
                  : (value) => setState(() => _imageReference = value),
              validator: (_) => _imageReference == null ? '请选择本地镜像' : null,
              autovalidateMode: AutovalidateMode.onUserInteraction,
            ),
            if (snapshot.connectionState == ConnectionState.waiting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('正在读取本地镜像…'),
              )
            else if (snapshot.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('本地镜像加载失败，请重试。')),
                    TextButton(
                      onPressed: () => setState(
                        () => _localImages = widget.loadLocalImages(),
                      ),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            else if (images.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('暂无本地镜像，请先在镜像页拉取或调用 image_pull。'),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建容器'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionTitle('镜像与名称'),
                _imagePicker(),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('create-name-field'),
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '名称（可选）',
                    hintText: '省略时自动生成；最长 63 字符',
                  ),
                ),
                _sectionTitle('网络与挂载'),
                TextFormField(
                  key: const Key('create-ports-field'),
                  controller: _ports,
                  maxLines: 2,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: _validatePorts,
                  decoration: const InputDecoration(
                    labelText: '端口映射（逗号或每行分隔）',
                    hintText: '8080:80/tcp',
                    helperText: '仅 host:container[/tcp|udp]，范围 1–65535',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('create-network-field'),
                  controller: _network,
                  decoration: const InputDecoration(labelText: '网络（可选）'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('create-mounts-field'),
                  controller: _mounts,
                  maxLines: 3,
                  minLines: 2,
                  validator: _validateMounts,
                  decoration: const InputDecoration(
                    labelText: '挂载（每行 source:target[:ro]）',
                    hintText: '/tmp/data:/data:ro',
                  ),
                ),
                _sectionTitle('进程与环境'),
                TextFormField(
                  key: const Key('create-env-field'),
                  controller: _env,
                  maxLines: 3,
                  minLines: 2,
                  decoration: const InputDecoration(
                    labelText: '环境变量（每行 KEY=VALUE）',
                    hintText: 'MODE=production',
                    helperText: '仅按行分隔；值中的逗号会保留',
                  ),
                ),
                ExpansionTile(
                  title: const Text('高级'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  children: [
                    TextFormField(
                      key: const Key('create-command-field'),
                      controller: _command,
                      validator: _validateCommand,
                      decoration: const InputDecoration(
                        labelText: '启动命令（支持单引号和双引号）',
                        hintText: '留空使用镜像默认命令',
                      ),
                    ),
                  ],
                ),
                _sectionTitle('标签与启动'),
                TextFormField(
                  key: const Key('create-labels-field'),
                  controller: _labels,
                  maxLines: 3,
                  minLines: 2,
                  validator: _validateLabels,
                  decoration: const InputDecoration(
                    labelText: '标签（每行 KEY=VALUE）',
                    hintText: 'com.example.role=web',
                  ),
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
