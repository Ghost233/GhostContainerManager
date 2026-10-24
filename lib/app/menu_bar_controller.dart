/// Native menu-bar state and preferences, backed by the shared container
/// Service. Swift renders this state and sends user actions back over the same
/// channel; it never invokes container lifecycle operations itself.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/container_models.dart';
import '../services/container_service.dart';

const List<String> kDefaultStartPages = <String>['容器', '镜像', '设置'];

class MenuBarPreferences {
  const MenuBarPreferences({this.visible = true, this.defaultStartPage = '容器'});

  final bool visible;
  final String defaultStartPage;
}

class MenuBarContainer {
  const MenuBarContainer({required this.id, required this.image});

  factory MenuBarContainer.fromSnapshot(ContainerSnapshotInfo snapshot) =>
      MenuBarContainer(id: snapshot.id, image: snapshot.image);

  final String id;
  final String image;

  Map<String, Object?> toMap() => <String, Object?>{'id': id, 'image': image};
}

enum MenuBarActionType {
  openMainWindow,
  openSettings,
  showContainers,
  stopContainer,
}

class MenuBarAction {
  const MenuBarAction(this.type, {this.containerId});

  final MenuBarActionType type;
  final String? containerId;
}

abstract interface class MenuBarChannel {
  Stream<MenuBarAction> get actions;

  Future<MenuBarPreferences> loadPreferences();

  Future<void> setVisible(bool visible);

  Future<void> setDefaultStartPage(String page);

  Future<void> updateContainers(
    List<MenuBarContainer> containers,
    int totalRunning,
  );

  void dispose();
}

final class MethodChannelMenuBarChannel implements MenuBarChannel {
  MethodChannelMenuBarChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('gcm/menu_bar') {
    _channel.setMethodCallHandler(_handleAction);
  }

  final MethodChannel _channel;
  final StreamController<MenuBarAction> _actions =
      StreamController<MenuBarAction>.broadcast();

  @override
  Stream<MenuBarAction> get actions => _actions.stream;

  @override
  Future<MenuBarPreferences> loadPreferences() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'getPreferences',
    );
    final page = result?['defaultStartPage'];
    return MenuBarPreferences(
      visible: result?['visible'] as bool? ?? true,
      defaultStartPage: page is String && kDefaultStartPages.contains(page)
          ? page
          : '容器',
    );
  }

  @override
  Future<void> setVisible(bool visible) {
    return _channel.invokeMethod<void>('setVisible', <String, Object?>{
      'visible': visible,
    });
  }

  @override
  Future<void> setDefaultStartPage(String page) {
    return _channel.invokeMethod<void>('setDefaultStartPage', <String, Object?>{
      'page': page,
    });
  }

  @override
  Future<void> updateContainers(
    List<MenuBarContainer> containers,
    int totalRunning,
  ) {
    return _channel.invokeMethod<void>('updateContainers', <String, Object?>{
      'containers': containers.map((item) => item.toMap()).toList(),
      'totalRunning': totalRunning,
    });
  }

  Future<void> _handleAction(MethodCall call) async {
    final arguments = call.arguments;
    final id = arguments is Map ? arguments['id'] as String? : null;
    final type = switch (call.method) {
      'openMainWindow' => MenuBarActionType.openMainWindow,
      'openSettings' => MenuBarActionType.openSettings,
      'showContainers' => MenuBarActionType.showContainers,
      'stopContainer' when id != null && id.isNotEmpty =>
        MenuBarActionType.stopContainer,
      _ => null,
    };
    if (type != null && !_actions.isClosed) {
      _actions.add(MenuBarAction(type, containerId: id));
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_actions.close());
  }
}

class MenuBarController extends ChangeNotifier {
  factory MenuBarController({
    required ContainerService containers,
    MenuBarChannel? channel,
  }) {
    return MenuBarController._(
      containers,
      channel ?? MethodChannelMenuBarChannel(),
    );
  }

  MenuBarController._(this._containers, this._channel);

  static const int maxVisibleContainers = 5;

  final ContainerService _containers;
  final MenuBarChannel _channel;
  final StreamController<String> _navigation =
      StreamController<String>.broadcast();

  StreamSubscription<List<ContainerSnapshotInfo>>? _snapshotSubscription;
  StreamSubscription<Map<String, ContainerActivity>>? _activitySubscription;
  StreamSubscription<MenuBarAction>? _actionSubscription;
  List<MenuBarContainer> _runningContainers = const <MenuBarContainer>[];
  int _totalRunning = 0;
  bool _visible = true;
  String _defaultStartPage = '容器';
  String? _lastError;
  bool _initialized = false;

  List<MenuBarContainer> get runningContainers => _runningContainers;
  int get totalRunning => _totalRunning;
  bool get visible => _visible;
  String get defaultStartPage => _defaultStartPage;
  String? get lastError => _lastError;
  Stream<String> get navigationRequests => _navigation.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _snapshotSubscription = _containers.snapshots.listen(
      (_) => _syncContainers(),
    );
    _activitySubscription = _containers.activityChanges.listen(
      (_) => _syncContainers(),
    );
    _actionSubscription = _channel.actions.listen(_handleAction);
    try {
      final preferences = await _channel.loadPreferences();
      _visible = preferences.visible;
      _defaultStartPage = preferences.defaultStartPage;
    } on PlatformException catch (error) {
      _lastError = error.message;
    } on MissingPluginException {
      // Widget tests and non-macOS hosts have no status-item implementation.
    }
    try {
      await _containers.refresh();
    } catch (error) {
      _lastError = '$error';
    }
    _syncContainers();
  }

  Future<void> setVisible(bool value) async {
    if (_visible == value) return;
    final previous = _visible;
    _visible = value;
    notifyListeners();
    try {
      await _channel.setVisible(value);
    } catch (error) {
      _visible = previous;
      _lastError = '$error';
      notifyListeners();
    }
  }

  Future<void> setDefaultStartPage(String value) async {
    if (!kDefaultStartPages.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported start page');
    }
    if (_defaultStartPage == value) return;
    final previous = _defaultStartPage;
    _defaultStartPage = value;
    notifyListeners();
    try {
      await _channel.setDefaultStartPage(value);
    } catch (error) {
      _defaultStartPage = previous;
      _lastError = '$error';
      notifyListeners();
    }
  }

  Future<void> stopContainer(String id) async {
    try {
      await _containers.stop(id);
      _lastError = null;
    } catch (error) {
      _lastError = '$error';
      notifyListeners();
    }
  }

  void _syncContainers() {
    final running = _containers.currentContainers
        .where(
          (container) =>
              container.state == ContainerState.running &&
              _containers.activityFor(container.id) == null,
        )
        .toList(growable: false);
    _totalRunning = running.length;
    _runningContainers = List<MenuBarContainer>.unmodifiable(
      running.take(maxVisibleContainers).map(MenuBarContainer.fromSnapshot),
    );
    notifyListeners();
    unawaited(_pushContainers());
  }

  Future<void> _pushContainers() async {
    try {
      await _channel.updateContainers(_runningContainers, _totalRunning);
    } on MissingPluginException {
      // See initialize(): the Dart state remains testable without AppKit.
    } on PlatformException catch (error) {
      _lastError = error.message;
    }
  }

  void _handleAction(MenuBarAction action) {
    switch (action.type) {
      case MenuBarActionType.openMainWindow:
        break; // AppKit has already activated and ordered the window front.
      case MenuBarActionType.openSettings:
        _navigation.add('设置');
      case MenuBarActionType.showContainers:
        _navigation.add('容器');
      case MenuBarActionType.stopContainer:
        final id = action.containerId;
        if (id != null) unawaited(stopContainer(id));
    }
  }

  @override
  void dispose() {
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_activitySubscription?.cancel());
    unawaited(_actionSubscription?.cancel());
    _channel.dispose();
    unawaited(_navigation.close());
    super.dispose();
  }
}
