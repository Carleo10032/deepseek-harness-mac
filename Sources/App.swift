import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let service = HarnessService()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.start()
        observeMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard service.isProcessRunning else {
            return .terminateNow
        }
        // Kill the child process tree asynchronously so quitting never blocks
        // the main thread, then let termination proceed once it has stopped.
        service.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if flag {
            // A window already exists (including a fullscreen one): let macOS
            // bring it forward and switch to its Space on the first Dock click.
            // Returning true here would swallow that default and make the user
            // click twice when the app lives on a fullscreen Space.
            return false
        }
        let window = mainWindow ?? NSApp.windows.first(where: { isMainContentWindow($0) })
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func observeMainWindow() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureMainWindow(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func captureMainWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isMainContentWindow(window),
              mainWindow !== window
        else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private func isMainContentWindow(_ window: NSWindow) -> Bool {
        // Only capture the app's one titled content window; reject sheets and
        // modal panels (NSAlert, NSSavePanel) so they are never mistaken for it.
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }
}

@main
struct DeepSeekHarnessDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DeepSeek Harness", id: "main") {
            ContentView(service: appDelegate.service)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
