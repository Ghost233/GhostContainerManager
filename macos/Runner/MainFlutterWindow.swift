import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuBarController: RunnerMenuBarController?

  var isMenuBarVisible: Bool { menuBarController?.hasVisibleStatusItem == true }

  func showMainWindow() { menuBarController?.showWindow() }

  override func awakeFromNib() {
    isReleasedWhenClosed = false
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    menuBarController = RunnerMenuBarController(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )

    super.awakeFromNib()
  }
}
