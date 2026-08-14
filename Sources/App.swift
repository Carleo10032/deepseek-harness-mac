import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    enum IconStyle: String, CaseIterable {
        case black
        case blue

        var label: String {
            switch self {
            case .black: "黑色"
            case .blue: "蓝色"
            }
        }
    }

    private static let iconStyleDefaultsKey = "DSHIconStyle"

    @Published var iconStyle: IconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: Self.iconStyleDefaultsKey)
            apply()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.iconStyleDefaultsKey)
        iconStyle = stored.flatMap(IconStyle.init(rawValue:)) ?? .black
    }

    /// Updates the Dock icon to match the current style. `.black` reverts to
    /// the bundled icon (black whale on white); `.blue` uses the bundled
    /// blue whale variant on the same white background.
    func apply() {
        switch iconStyle {
        case .black:
            NSApp.applicationIconImage = nil
        case .blue:
            if let url = Bundle.main.url(forResource: "AppIcon-blue", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let service = HarnessService()
    let settings = AppSettings()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.start()
        settings.apply()
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
        // Explicitly activate the app and bring the main window forward. The
        // explicit activation also switches to the app's fullscreen Space on
        // the first Dock click — the implicit reopen activation alone only
        // flips the menu bar, which is why fullscreen used to need two clicks.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let window = mainWindow ?? NSApp.windows.first(where: { isMainContentWindow($0) })
        window?.makeKeyAndOrderFront(nil)
        return false
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
        .commands {
            CommandMenu("图标颜色") {
                Picker("图标颜色", selection: Binding(
                    get: { appDelegate.settings.iconStyle },
                    set: { appDelegate.settings.iconStyle = $0 }
                )) {
                    ForEach(AppSettings.IconStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
        }
    }
}
