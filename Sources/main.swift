import AppKit
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private struct LaunchCommand {
    let executable: URL
    let arguments: [String]
}

@MainActor
final class HarnessService: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case installing
        case running
        case failed(String)
        case stopped
    }

    private static let pinnedDSHVersion = "0.1.0-rc.6"
    private static let defaultPreferredPort = 3080
    private static let dshOverrideDefaultsKey = "DSHBinOverride"
    private static let preferredPortDefaultsKey = "DSHPreferredPort"

    @Published private(set) var state: State = .idle
    @Published private(set) var serverURL: URL?

    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var requestedStop = false
    private var installing = false
    private var attemptedFallbackPort = false

    var statusText: String {
        switch state {
        case .idle: "准备启动"
        case .starting: "正在启动 DeepSeek Harness…"
        case .installing: "正在全局安装 dsh…"
        case .running: "已连接到本地服务"
        case .failed(let message): "启动失败：\(message)"
        case .stopped: "服务已停止"
        }
    }

    func start() {
        guard process == nil, !installing else { return }

        let port = attemptedFallbackPort ? 0 : preferredPort
        let baseArguments = ["web", "--host", "127.0.0.1", "--port", "\(port)"]

        let executableURL: URL
        let arguments: [String]
        if let command = resolveDirectCommand(baseArguments: baseArguments) {
            executableURL = command.executable
            arguments = command.arguments
        } else if let npx = locateExecutable(named: "npx") {
            executableURL = npx
            arguments = ["--yes", "@deepseek-ai/dsh@\(Self.pinnedDSHVersion)"] + baseArguments
        } else {
            state = .failed("找不到 dsh，也未找到 npx。请先安装 Node.js（https://nodejs.org），或点“安装全局 dsh”。")
            return
        }

        requestedStop = false
        outputBuffer = ""
        serverURL = nil
        state = .starting

        let task = Process()
        let pipe = Pipe()
        task.executableURL = executableURL
        task.arguments = arguments
        task.currentDirectoryURL = defaultWorkingDirectory()

        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (requiredPaths + [existingPath]).joined(separator: ":")
        task.environment = environment

        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consumeOutput(text)
            }
        }

        task.terminationHandler = { [weak self] finishedTask in
            DispatchQueue.main.async {
                self?.handleTermination(status: finishedTask.terminationStatus)
            }
        }

        do {
            try task.run()
            process = task
            outputPipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        requestedStop = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        guard let task = process, task.isRunning else {
            process = nil
            outputPipe = nil
            state = .stopped
            return
        }

        stopProcessTree(rootPID: task.processIdentifier)
    }

    func restart() {
        stop()
        process = nil
        outputPipe = nil
        installing = false
        attemptedFallbackPort = false
        state = .idle
        start()
    }

    private func consumeOutput(_ text: String) {
        outputBuffer += text
        if outputBuffer.count > 16_384 {
            outputBuffer = String(outputBuffer.suffix(16_384))
        }

        guard !installing,
              serverURL == nil,
              let range = outputBuffer.range(
                  of: #"http://127\.0\.0\.1:[0-9]+"#,
                  options: .regularExpression
              ),
              let url = URL(string: String(outputBuffer[range]))
        else { return }

        serverURL = url
        state = .running
    }

    private func handleTermination(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil

        if installing {
            installing = false
            if status == 0 {
                attemptedFallbackPort = false
                state = .idle
                start()
            } else {
                let lastLine = outputBuffer
                    .split(whereSeparator: \.isNewline)
                    .last
                    .map(String.init) ?? "退出码 \(status)"
                state = .failed("全局安装失败：\(lastLine)")
            }
            return
        }

        if requestedStop {
            state = .stopped
        } else if serverURL == nil {
            if !attemptedFallbackPort,
               outputBuffer.localizedCaseInsensitiveContains("EADDRINUSE") {
                attemptedFallbackPort = true
                outputBuffer = ""
                start()
                return
            }
            let lastLine = outputBuffer
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? "退出码 \(status)"
            state = .failed(lastLine)
        } else {
            serverURL = nil
            state = .failed("本地服务意外退出（\(status)）")
        }
    }

    func installGlobalDSH() {
        guard process == nil, !installing else { return }
        guard let npm = locateExecutable(named: "npm") else {
            state = .failed("找不到 npm，无法全局安装。请先安装 Node.js（https://nodejs.org）。")
            return
        }

        installing = true
        requestedStop = false
        outputBuffer = ""
        serverURL = nil
        state = .installing

        let task = Process()
        let pipe = Pipe()
        task.executableURL = npm
        task.arguments = ["install", "--global", "@deepseek-ai/dsh@\(Self.pinnedDSHVersion)"]
        task.currentDirectoryURL = defaultWorkingDirectory()

        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            npm.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (requiredPaths + [existingPath]).joined(separator: ":")
        task.environment = environment

        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consumeOutput(text)
            }
        }

        task.terminationHandler = { [weak self] finishedTask in
            DispatchQueue.main.async {
                self?.handleTermination(status: finishedTask.terminationStatus)
            }
        }

        do {
            try task.run()
            process = task
            outputPipe = pipe
        } catch {
            installing = false
            pipe.fileHandleForReading.readabilityHandler = nil
            state = .failed(error.localizedDescription)
        }
    }

    private var preferredPort: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.preferredPortDefaultsKey) != nil else {
            return Self.defaultPreferredPort
        }
        let value = defaults.integer(forKey: Self.preferredPortDefaultsKey)
        return (0...65535).contains(value) ? value : Self.defaultPreferredPort
    }

    private var dshOverridePath: String? {
        let value = UserDefaults.standard
            .string(forKey: Self.dshOverrideDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private func resolveDirectCommand(baseArguments: [String]) -> LaunchCommand? {
        let fileManager = FileManager.default
        if let override = dshOverridePath,
           fileManager.isExecutableFile(atPath: override) {
            return LaunchCommand(
                executable: URL(fileURLWithPath: override),
                arguments: baseArguments
            )
        }
        if let global = locateExecutable(named: "dsh") {
            return LaunchCommand(executable: global, arguments: baseArguments)
        }
        if let cached = locateCachedDSH() {
            return LaunchCommand(executable: cached, arguments: baseArguments)
        }
        return nil
    }

    private func locateExecutable(named name: String) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let fixedDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/Library/pnpm"
        ]

        for directory in fixedDirectories {
            let path = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        if let viaWhich = locateViaWhich(name) {
            return viaWhich
        }

        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func locateViaWhich(_ name: String) -> URL? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["-a", name]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let fileManager = FileManager.default
            for line in output.split(whereSeparator: \.isNewline) {
                let path = String(line)
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func locateCachedDSH() -> URL? {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let cacheDirectories = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let newestFirst = cacheDirectories.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            return left > right
        }

        for directory in newestFirst {
            let packageJSON = directory
                .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
            let executable = directory.appendingPathComponent("node_modules/.bin/dsh")
            guard fileManager.isExecutableFile(atPath: executable.path),
                  let data = try? Data(contentsOf: packageJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["version"] as? String == Self.pinnedDSHVersion
            else { continue }
            return executable
        }

        return nil
    }

    private func defaultWorkingDirectory() -> URL {
        let fileManager = FileManager.default
        let preferred = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Vibe", isDirectory: true)
        return fileManager.fileExists(atPath: preferred.path)
            ? preferred
            : fileManager.homeDirectoryForCurrentUser
    }

    private func stopProcessTree(rootPID: pid_t) {
        let pids = descendantPIDs(of: rootPID) + [rootPID]
        let signals = [SIGINT, SIGTERM, SIGKILL]

        for signal in signals {
            for pid in pids.reversed() where kill(pid, 0) == 0 {
                kill(pid, signal)
            }

            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline && pids.contains(where: { kill($0, 0) == 0 }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }

            if !pids.contains(where: { kill($0, 0) == 0 }) {
                return
            }
        }
    }

    private func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            let pairs: [(pid_t, pid_t)] = output.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      let pid = pid_t(fields[0]),
                      let parentPID = pid_t(fields[1])
                else { return nil }
                return (pid, parentPID)
            }

            var descendants: [pid_t] = []
            var parents: Set<pid_t> = [rootPID]
            while true {
                let children = pairs
                    .filter { parents.contains($0.1) && !descendants.contains($0.0) }
                    .map(\.0)
                guard !children.isEmpty else { break }
                descendants.append(contentsOf: children)
                parents = Set(children)
            }
            return descendants
        } catch {
            return []
        }
    }
}

struct HarnessWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> DownloadCoordinator {
        DownloadCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: DownloadCoordinator.sessionDownloadDialogSuppressionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    @MainActor
    final class DownloadCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        static let sessionDownloadDialogSuppressionScript = #"""
        (() => {
          const style = document.createElement("style");
          style.textContent = `
            [role="presentation"]:has(> [role="dialog"][aria-label="正在导出 Session"]),
            [role="presentation"]:has(> [role="dialog"][aria-label="Exporting Session"]),
            [role="presentation"]:has(> [role="dialog"][aria-label="Session 导出已开始下载"]),
            [role="presentation"]:has(> [role="dialog"][aria-label="Session download started"]) {
              display: none !important;
            }
          `;
          document.head.appendChild(style);

          const messages = [
            "浏览器正在下载 Session ZIP 文件。",
            "The browser is downloading the Session ZIP."
          ];
          const dismiss = () => {
            for (const dialog of document.querySelectorAll('[role="dialog"]')) {
              if (!messages.some((message) => dialog.textContent?.includes(message))) continue;
              const closeLabels = new Set(["关闭", "Close"]);
              const button = [...dialog.querySelectorAll('button')].find((node) =>
                closeLabels.has(node.textContent?.trim() ?? "")
              );
              button?.click();
            }
          };
          dismiss();
          new MutationObserver(dismiss).observe(document.documentElement, {
            childList: true,
            subtree: true
          });
        })();
        """#

        private var activeDownloads: [WKDownload] = []
        private var destinations: [ObjectIdentifier: URL] = [:]
        private var userCancelledDownloads: Set<ObjectIdentifier> = []
        private weak var webView: WKWebView?

        func attach(to webView: WKWebView) {
            self.webView = webView
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }

            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  isExternalURL(url, relativeTo: webView.url)
            else {
                decisionHandler(.allow, preferences)
                return
            }

            openExternally(url)
            decisionHandler(.cancel, preferences)
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // `target="_blank"` and `window.open`: open in the default browser
            // instead of creating a second in-app window.
            if let url = navigationAction.request.url {
                openExternally(url)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "DeepSeek Harness"
            alert.informativeText = message
            presentAlert(alert) { _ in
                completionHandler()
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "DeepSeek Harness"
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            presentAlert(alert) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "DeepSeek Harness"
            alert.informativeText = prompt
            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            inputField.stringValue = defaultText ?? ""
            alert.accessoryView = inputField
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            presentAlert(alert) { response in
                completionHandler(response == .alertFirstButtonReturn ? inputField.stringValue : nil)
            }
        }

        // MARK: External links

        private func isExternalURL(_ url: URL, relativeTo localURL: URL?) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            switch scheme {
            case "http", "https":
                guard let local = localURL else { return true }
                return url.host != local.host || url.port != local.port
            case "mailto", "tel", "file":
                return true
            default:
                // blob:, data:, about:, javascript:, … — let WebKit handle them.
                return false
            }
        }

        private func openExternally(_ url: URL) {
            NSWorkspace.shared.open(url)
        }

        private func presentAlert(
            _ alert: NSAlert,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let policy: WKNavigationResponsePolicy = navigationResponse.canShowMIMEType
                ? .allow
                : .download
            decisionHandler(policy)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            begin(download)
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            begin(download)
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let panel = NSSavePanel()
            let contentType = response.mimeType.flatMap {
                UTType.types(tag: $0, tagClass: .mimeType, conformingTo: nil).first
            }
            panel.canCreateDirectories = true
            if let contentType {
                panel.allowedContentTypes = [contentType]
                panel.isExtensionHidden = false
            }
            panel.nameFieldStringValue = safeFilename(
                suggestedFilename,
                contentType: contentType
            )

            let handleResult: (NSApplication.ModalResponse) -> Void = { [weak self, weak download] result in
                guard let download else {
                    completionHandler(nil)
                    return
                }
                if result == .OK {
                    if let destination = panel.url {
                        self?.destinations[ObjectIdentifier(download)] = destination
                        completionHandler(destination)
                    } else {
                        completionHandler(nil)
                    }
                } else {
                    self?.userCancelledDownloads.insert(ObjectIdentifier(download))
                    self?.dismissSessionDownloadDialog()
                    completionHandler(nil)
                }
            }

            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: handleResult)
            } else {
                panel.begin(completionHandler: handleResult)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            let destination = destinations.removeValue(forKey: ObjectIdentifier(download))
            finish(download)
            showDownloadSucceeded(destination: destination)
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            let userCancelled = userCancelledDownloads.remove(ObjectIdentifier(download)) != nil
            destinations.removeValue(forKey: ObjectIdentifier(download))
            finish(download)
            guard !userCancelled, !isSystemCancellation(error) else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "下载失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        private func begin(_ download: WKDownload) {
            activeDownloads.append(download)
            download.delegate = self
            dismissSessionDownloadDialog()
        }

        private func finish(_ download: WKDownload) {
            activeDownloads.removeAll { $0 === download }
        }

        private func isSystemCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                return true
            }
            if nsError.domain == NSURLErrorDomain,
               nsError.code == URLError.cancelled.rawValue {
                return true
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isSystemCancellation(underlying)
            }
            return false
        }

        private func showDownloadSucceeded(destination: URL?) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Session 日志下载成功"
            alert.informativeText = destination?.path ?? "文件已保存到你选择的位置。"
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        private func dismissSessionDownloadDialog() {
            let script = #"""
            (() => {
              const messages = [
                "浏览器正在下载 Session ZIP 文件。",
                "The browser is downloading the Session ZIP."
              ];
              const dialog = [...document.querySelectorAll('[role="dialog"]')].find((node) =>
                messages.some((message) => node.textContent?.includes(message))
              );
              if (!dialog) return false;
              const closeLabels = new Set(["关闭", "Close"]);
              const button = [...dialog.querySelectorAll('button')].find((node) =>
                closeLabels.has(node.textContent?.trim() ?? "")
              );
              if (!button) return false;
              button.click();
              return true;
            })();
            """#
            webView?.evaluateJavaScript(script)
        }

        private func safeFilename(
            _ suggestedFilename: String,
            contentType: UTType?
        ) -> String {
            var filename = suggestedFilename
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if filename.isEmpty {
                filename = "session-log"
            }
            if URL(fileURLWithPath: filename).pathExtension.isEmpty,
               let fileExtension = contentType?.preferredFilenameExtension {
                filename += ".\(fileExtension)"
            }
            return filename
        }
    }
}

struct ContentView: View {
    @ObservedObject var service: HarnessService

    var body: some View {
        Group {
            if let url = service.serverURL {
                HarnessWebView(url: url)
            } else {
                VStack(spacing: 16) {
                    if service.state == .starting || service.state == .installing {
                        ProgressView()
                            .controlSize(.large)
                    }

                    Text("DeepSeek Harness")
                        .font(.title2.weight(.semibold))
                    Text(service.statusText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                    if case .failed = service.state {
                        HStack(spacing: 12) {
                            Button("重新启动") {
                                service.restart()
                            }
                            .keyboardShortcut(.defaultAction)

                            Button("安装全局 dsh") {
                                service.installGlobalDSH()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let service = HarnessService()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.start()
        attachMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stop()
    }

    private func attachMainWindow(attemptsRemaining: Int = 10) {
        if let window = NSApp.windows.first(where: { $0.title == "DeepSeek Harness" }) {
            mainWindow = window
            window.isReleasedWhenClosed = false
            window.delegate = self
            return
        }

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachMainWindow(attemptsRemaining: attemptsRemaining - 1)
        }
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
