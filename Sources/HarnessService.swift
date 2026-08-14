import Combine
import Darwin
import Foundation

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

    private static let defaultDSHVersion = "0.1.0-rc.6"
    private static let latestDSHVersion = "latest"
    private static let defaultPreferredPort = 3080
    private static let dshOverrideDefaultsKey = "DSHBinOverride"
    private static let preferredPortDefaultsKey = "DSHPreferredPort"
    private static let pinnedVersionDefaultsKey = "DSHPinnedVersion"

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

    var isProcessRunning: Bool {
        process?.isRunning ?? false
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
            arguments = ["--yes", dshPackageSpecifier] + baseArguments
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
                self?.handleTermination(of: finishedTask, status: finishedTask.terminationStatus)
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

    func stop(completion: (() -> Void)? = nil) {
        requestedStop = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        guard let task = process, task.isRunning else {
            process = nil
            outputPipe = nil
            state = .stopped
            completion?()
            return
        }

        stopProcessTree(rootPID: task.processIdentifier, completion: completion)
    }

    func restart() {
        // Wait for the old process tree to actually exit before launching the
        // replacement, so the new instance never races the dying one for the
        // preferred port (which would silently fall back to a random port).
        stop { [weak self] in
            guard let self else { return }
            self.process = nil
            self.outputPipe = nil
            self.installing = false
            self.attemptedFallbackPort = false
            self.state = .idle
            self.start()
        }
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

    private func handleTermination(of finishedTask: Process, status: Int32) {
        // Guard against a stale task's termination racing a restart: after
        // `restart()` has spawned a new process, the old task's handler would
        // otherwise tear down the new pipe and clobber the new state.
        guard finishedTask === process else { return }

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
        task.arguments = ["install", "--global", dshPackageSpecifier]
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
                self?.handleTermination(of: finishedTask, status: finishedTask.terminationStatus)
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

    /// The dsh version the app should resolve, install, and pin to.
    /// Read from the `DSHPinnedVersion` preference; defaults to
    /// `defaultDSHVersion`, and `latest` means "follow the newest release".
    private var pinnedDSHVersion: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.pinnedVersionDefaultsKey) != nil,
              let value = defaults.string(forKey: Self.pinnedVersionDefaultsKey)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return Self.defaultDSHVersion }
        return value
    }

    private var usesLatestVersion: Bool {
        pinnedDSHVersion.caseInsensitiveCompare(Self.latestDSHVersion) == .orderedSame
    }

    /// The npm package specifier passed to `npx` / `npm install`.
    private var dshPackageSpecifier: String {
        usesLatestVersion
            ? "@deepseek-ai/dsh"
            : "@deepseek-ai/dsh@\(pinnedDSHVersion)"
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
            guard fileManager.isExecutableFile(atPath: executable.path) else { continue }
            // In "latest" mode, accept the newest cached dsh regardless of
            // version; otherwise require an exact version match.
            if !usesLatestVersion {
                guard let data = try? Data(contentsOf: packageJSON),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["version"] as? String == pinnedDSHVersion
                else { continue }
            }
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

    private func stopProcessTree(rootPID: pid_t, completion: (() -> Void)?) {
        let pids = descendantPIDs(of: rootPID) + [rootPID]
        let signals: [Int32] = [SIGINT, SIGTERM, SIGKILL]
        var signalIndex = 0

        func escalateOrFinish() {
            guard signalIndex < signals.count else {
                completion?()
                return
            }

            let signal = signals[signalIndex]
            signalIndex += 1
            for pid in pids.reversed() where kill(pid, 0) == 0 {
                kill(pid, signal)
            }

            // Give the tree 0.5s to exit on the current signal; escalate to the
            // next (SIGINT → SIGTERM → SIGKILL) if it is still alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pids.contains(where: { kill($0, 0) == 0 }) {
                    escalateOrFinish()
                } else {
                    completion?()
                }
            }
        }

        escalateOrFinish()
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
