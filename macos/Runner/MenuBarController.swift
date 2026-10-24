import Cocoa
import FlutterMacOS

/// AppKit status item and native actions. Container mutations are sent back to
/// Dart so every lifecycle operation still goes through ContainerService.
final class RunnerMenuBarController: NSObject {
  private static let visibleKey = "menuBarVisible"
  private static let startPageKey = "defaultStartPage"
  private static let allowedStartPages: Set<String> = ["容器", "镜像", "设置"]

  private struct MenuContainer {
    let id: String
    let image: String
  }

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private let defaults: UserDefaults
  private var statusItem: NSStatusItem?
  private var containers: [MenuContainer] = []
  private var totalRunning = 0

  init(messenger: FlutterBinaryMessenger, window: NSWindow, defaults: UserDefaults = .standard) {
    self.window = window
    self.defaults = defaults
    self.channel = FlutterMethodChannel(name: "gcm/menu_bar", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    applyVisibility()
  }

  private var visible: Bool {
    defaults.object(forKey: Self.visibleKey) as? Bool ?? true
  }

  private var defaultStartPage: String {
    let page = defaults.string(forKey: Self.startPageKey) ?? "容器"
    return Self.allowedStartPages.contains(page) ? page : "容器"
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPreferences":
      result(["visible": visible, "defaultStartPage": defaultStartPage])
    case "setVisible":
      guard let arguments = call.arguments as? [String: Any],
        let visible = arguments["visible"] as? Bool
      else {
        result(invalidArguments("setVisible requires a visible Boolean"))
        return
      }
      defaults.set(visible, forKey: Self.visibleKey)
      applyVisibility()
      result(nil)
    case "setDefaultStartPage":
      guard let arguments = call.arguments as? [String: Any],
        let page = arguments["page"] as? String,
        Self.allowedStartPages.contains(page)
      else {
        result(invalidArguments("setDefaultStartPage received an unsupported page"))
        return
      }
      defaults.set(page, forKey: Self.startPageKey)
      result(nil)
    case "updateContainers":
      guard let arguments = call.arguments as? [String: Any],
        let rawContainers = arguments["containers"] as? [[String: Any]],
        let total = arguments["totalRunning"] as? Int
      else {
        result(invalidArguments("updateContainers requires containers and totalRunning"))
        return
      }
      containers = rawContainers.prefix(5).compactMap { item in
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        return MenuContainer(id: id, image: item["image"] as? String ?? "")
      }
      totalRunning = max(total, containers.count)
      rebuildMenu()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalidArgument", message: message, details: nil)
  }

  private func applyVisibility() {
    if visible {
      if statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
          systemSymbolName: "shippingbox",
          accessibilityDescription: "Ghost Container Manager"
        )
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Ghost Container Manager"
        if item.button?.image == nil { item.button?.title = "GCM" }
        statusItem = item
      }
      rebuildMenu()
    } else if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  private func rebuildMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    if containers.isEmpty {
      menu.addItem(NSMenuItem(title: "暂无运行中容器", action: nil, keyEquivalent: ""))
    } else {
      menu.addItem(
        NSMenuItem(title: "运行中容器（\(totalRunning)）", action: nil, keyEquivalent: "")
      )
      for container in containers {
        let item = NSMenuItem(
          title: "停止 \(container.id)",
          action: #selector(stopContainer(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = container.id
        item.toolTip = container.image.isEmpty ? container.id : container.image
        menu.addItem(item)
      }
      if totalRunning > containers.count {
        let all = NSMenuItem(
          title: "查看全部（共 \(totalRunning) 个）",
          action: #selector(showContainers),
          keyEquivalent: ""
        )
        all.target = self
        menu.addItem(all)
      }
    }
    menu.addItem(.separator())
    addAction(menu, title: "打开主窗口", action: #selector(openMainWindow))
    addAction(menu, title: "设置…", action: #selector(openSettings))
    menu.addItem(.separator())
    addAction(menu, title: "退出 Ghost Container Manager", action: #selector(quit))
    statusItem.menu = menu
  }

  private func addAction(_ menu: NSMenu, title: String, action: Selector) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    menu.addItem(item)
  }

  private func showWindow() {
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  @objc private func openMainWindow() {
    showWindow()
    channel.invokeMethod("openMainWindow", arguments: nil)
  }

  @objc private func openSettings() {
    showWindow()
    channel.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func showContainers() {
    showWindow()
    channel.invokeMethod("showContainers", arguments: nil)
  }

  @objc private func stopContainer(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("stopContainer", arguments: ["id": id])
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
