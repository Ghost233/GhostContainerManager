import Cocoa
import FlutterMacOS
import XCTest
@testable import Ghost_Container_Manager

class RunnerTests: XCTestCase {
  @MainActor
  func testClosingWindowHidesDockKeepsMenuBarAndSupportsReopening() throws {
    let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
    let window = try XCTUnwrap(delegate.mainFlutterWindow as? MainFlutterWindow)
    window.showMainWindow()
    XCTAssertEqual(NSApp.activationPolicy(), .regular)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    XCTAssertTrue(window.isMenuBarVisible)
    XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(NSApp.activationPolicy(), .regular)
  }
}
