#if os(Windows)
import Foundation
import WinSDK

// MARK: - Windows PTY process registry

/// Tracks active `WindowsPTY` sessions so `terminateActiveProcessesForAppShutdown()` can
/// cleanly kill them all.  Uses the same `NSCondition`-based fence pattern as the
/// POSIX `TTYCommandRunnerActiveProcessRegistry`.
private enum WindowsPTYRegistry {
    private static let condition = NSCondition()
    private nonisolated(unsafe) static var ptys: [DWORD: (pty: WindowsPTY, binary: String)] = [:]
    private nonisolated(unsafe) static var isShuttingDown = false
    private nonisolated(unsafe) static var launchesInProgress = 0

    static func beginLaunch() -> Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        guard !self.isShuttingDown else { return false }
        self.launchesInProgress += 1
        return true
    }

    static func endLaunch() {
        self.condition.lock()
        self.launchesInProgress = max(0, self.launchesInProgress - 1)
        if self.launchesInProgress == 0 {
            self.condition.broadcast()
        }
        self.condition.unlock()
    }

    @discardableResult
    static func register(pid: DWORD, pty: WindowsPTY, binary: String) -> Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        guard !self.isShuttingDown else { return false }
        self.ptys[pid] = (pty: pty, binary: binary)
        return true
    }

    static func unregister(pid: DWORD) {
        self.condition.lock()
        self.ptys.removeValue(forKey: pid)
        self.condition.unlock()
    }

    /// Sets the shutdown fence and waits for all in-flight launches to complete,
    /// then drains and returns all registered PTY instances.
    static func drainForShutdown() -> [(pty: WindowsPTY, binary: String)] {
        self.condition.lock()
        self.isShuttingDown = true
        while self.launchesInProgress > 0 {
            self.condition.wait()
        }
        let drained = self.ptys.values.map { (pty: $0.pty, binary: $0.binary) }
        self.ptys.removeAll()
        self.condition.unlock()
        return drained
    }

    static func reset() {
        self.condition.lock()
        self.ptys.removeAll()
        self.isShuttingDown = false
        self.launchesInProgress = 0
        self.condition.broadcast()
        self.condition.unlock()
    }
}

// MARK: - TTYCommandRunner (Windows)

/// Windows implementation of `TTYCommandRunner`.
///
/// On Windows the POSIX PTY file (`TTYCommandRunner.swift`) is excluded via
/// `#if canImport(Darwin) || os(Linux)`.  This file provides the full public
/// API surface using ConPTY (`WindowsPTY`) for the interactive `run()` path,
/// and stubs for registry/test helpers that test-only POSIX code uses.
public struct TTYCommandRunner: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.ttyRunner)

    public struct Result: Sendable {
        public let text: String
    }

    public struct Options: Sendable {
        public var rows: UInt16 = 50
        public var cols: UInt16 = 160
        public var timeout: TimeInterval = 20.0
        public var idleTimeout: TimeInterval?
        public var workingDirectory: URL?
        public var extraArgs: [String] = []
        public var baseEnvironment: [String: String]?
        public var initialDelay: TimeInterval = 0.4
        public var sendEnterEvery: TimeInterval?
        public var sendOnSubstrings: [String: String]
        public var stopOnURL: Bool
        public var stopOnSubstrings: [String]
        public var settleAfterStop: TimeInterval
        public var forceCodexStatusMode: Bool
        public var useClaudeProbeWorkingDirectory: Bool

        public init(
            rows: UInt16 = 50,
            cols: UInt16 = 160,
            timeout: TimeInterval = 20.0,
            idleTimeout: TimeInterval? = nil,
            workingDirectory: URL? = nil,
            extraArgs: [String] = [],
            baseEnvironment: [String: String]? = nil,
            initialDelay: TimeInterval = 0.4,
            sendEnterEvery: TimeInterval? = nil,
            sendOnSubstrings: [String: String] = [:],
            stopOnURL: Bool = false,
            stopOnSubstrings: [String] = [],
            settleAfterStop: TimeInterval = 0.25,
            forceCodexStatusMode: Bool = false,
            useClaudeProbeWorkingDirectory: Bool = false)
        {
            self.rows = rows
            self.cols = cols
            self.timeout = timeout
            self.idleTimeout = idleTimeout
            self.workingDirectory = workingDirectory
            self.extraArgs = extraArgs
            self.baseEnvironment = baseEnvironment
            self.initialDelay = initialDelay
            self.sendEnterEvery = sendEnterEvery
            self.sendOnSubstrings = sendOnSubstrings
            self.stopOnURL = stopOnURL
            self.stopOnSubstrings = stopOnSubstrings
            self.settleAfterStop = settleAfterStop
            self.forceCodexStatusMode = forceCodexStatusMode
            self.useClaudeProbeWorkingDirectory = useClaudeProbeWorkingDirectory
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case binaryNotFound(String)
        case launchFailed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case let .binaryNotFound(bin):
                "Missing CLI '\(bin)'. Install it (e.g. npm i -g @openai/codex) or add it to PATH."
            case let .launchFailed(msg): "Failed to launch process: \(msg)"
            case .timedOut: "PTY command timed out."
            }
        }
    }

    public init() {}

    // MARK: App-shutdown

    /// Terminates all active ConPTY sessions.  Called on app shutdown from any thread.
    public static func terminateActiveProcessesForAppShutdown() {
        let log = Self.log
        let targets = WindowsPTYRegistry.drainForShutdown()
        guard !targets.isEmpty else { return }
        log.debug("PTY shutdown: terminating \(targets.count) ConPTY session(s)")
        for target in targets {
            log.debug("PTY shutdown: terminating", metadata: ["binary": target.binary])
            target.pty.terminate()
        }
    }

    // MARK: Registry stubs (POSIX-only API; no-ops on Windows)

    public static func updateActiveProcessGroupForAppShutdown(pid: Int32, processGroup: Int32?) {}

    @discardableResult
    static func registerActiveProcessForAppShutdown(pid: pid_t, binary: String) -> Bool { false }

    static func beginActiveProcessLaunchForAppShutdown() -> Bool { false }

    static func endActiveProcessLaunchForAppShutdown() {}

    static func unregisterActiveProcessForAppShutdown(pid: pid_t) {}

    static func _test_resetTrackedProcesses() {}

    static func _test_trackProcess(pid: pid_t, binary: String, processGroup: pid_t?) {}

    @discardableResult
    static func _test_registerTrackedProcess(pid: pid_t, binary: String) -> Bool { false }

    static func _test_trackedProcessCount() -> Int { 0 }

    static func _test_beginTrackedProcessLaunch() -> Bool { false }

    static func _test_endTrackedProcessLaunch() {}

    static func _test_drainTrackedProcessesForShutdown(
        onFenceSet: (() -> Void)? = nil)
        -> [(pid: pid_t, binary: String, processGroup: pid_t?)] { [] }

    static func _test_resolveShutdownTargets(
        _ targets: [(pid: pid_t, binary: String, processGroup: pid_t?)],
        hostProcessGroup: pid_t,
        groupResolver: (pid_t) -> pid_t) -> [(pid: pid_t, binary: String, processGroup: pid_t?)] { [] }

    // MARK: Binary resolution

    /// Locates `tool` on Windows by searching `PATH` with `PATHEXT` extensions,
    /// then falls back to `where.exe`.
    public static func which(_ tool: String) -> String? {
        if tool == "codex", let located = BinaryLocator.resolveCodexBinary() { return located }
        if tool == "claude", let located = BinaryLocator.resolveClaudeBinary() { return located }
        // Fast path: search PATH + PATHEXT manually.
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "").split(separator: ";").map(String.init)
        let exts = (env["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(separator: ";").map(String.init)
        for dir in paths {
            for ext in exts {
                let candidate = "\(dir)\\\(tool)\(ext)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        // Fallback: `where.exe`
        return Self.runWhere(tool)
    }

    private static func runWhere(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\where.exe"#)
        proc.arguments = [tool]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let first = output
            .components(separatedBy: "\r\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? output.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let path = first?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    // MARK: Path / environment helpers

    public static func enrichedPath() -> String {
        PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: ProcessInfo.processInfo.environment)
    }

    static func enrichedEnvironment(
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        home: String = NSHomeDirectory()) -> [String: String]
    {
        var env = baseEnv
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: baseEnv,
            loginPATH: loginPATH,
            home: home)
        if env["HOME"]?.isEmpty ?? true {
            env["HOME"] = home
        }
        if env["TERM"]?.isEmpty ?? true {
            env["TERM"] = "xterm-256color"
        }
        if env["COLORTERM"]?.isEmpty ?? true {
            env["COLORTERM"] = "truecolor"
        }
        if env["LANG"]?.isEmpty ?? true {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["CI"] == nil {
            env["CI"] = "0"
        }
        return env
    }

    static func locateBundledHelper(_ name: String) -> String? { nil }

    // MARK: Main PTY entry point (ConPTY)

    /// Windows ConPTY-backed equivalent of the POSIX `run(binary:send:options:onURLDetected:)`.
    ///
    /// Creates a `WindowsPTY`, spawns the process, drives the read/write loop,
    /// and returns the captured output — matching the contract of the POSIX implementation.
    // swiftlint:disable function_body_length
    public func run(
        binary: String,
        send script: String,
        options: Options = Options(),
        onURLDetected: (@Sendable () -> Void)? = nil) throws -> Result
    {
        let log = Self.log

        let resolved: String
        if FileManager.default.isExecutableFile(atPath: binary) {
            resolved = binary
        } else if let hit = Self.which(binary) {
            resolved = hit
        } else {
            log.warning("PTY binary not found", metadata: ["binary": binary])
            throw Error.binaryNotFound(binary)
        }

        let binaryName = URL(fileURLWithPath: resolved).lastPathComponent
        log.debug(
            "PTY start (ConPTY)",
            metadata: [
                "binary": binaryName,
                "timeout": "\(options.timeout)",
                "rows": "\(options.rows)",
                "cols": "\(options.cols)",
            ])

        let size = WindowsPTY.Size(columns: Int32(options.cols), rows: Int32(options.rows))
        let pty: WindowsPTY
        do {
            pty = try WindowsPTY(size: size)
        } catch {
            log.warning("ConPTY init failed", metadata: ["binary": binaryName, "error": error.localizedDescription])
            throw Error.launchFailed("WindowsPTY init: \(error.localizedDescription)")
        }

        let baseEnv = options.baseEnvironment ?? ProcessInfo.processInfo.environment
        var env = Self.enrichedEnvironment(baseEnv: baseEnv, home: baseEnv["HOME"] ?? NSHomeDirectory())
        let workingDirectory = options.workingDirectory
        if let workingDirectory {
            env["PWD"] = workingDirectory.path
        }

        guard WindowsPTYRegistry.beginLaunch() else {
            pty.close()
            throw Error.launchFailed("App shutdown in progress")
        }
        var launchReservationHeld = true
        defer {
            if launchReservationHeld {
                WindowsPTYRegistry.endLaunch()
            }
        }

        let capturedLog = log
        var cleanedUp = false
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            capturedLog.debug("PTY cleanup (ConPTY)", metadata: ["binary": binaryName])
            pty.terminate()
            let pid = pty.processID
            if pid != 0 {
                WindowsPTYRegistry.unregister(pid: pid)
            }
        }
        defer { cleanup() }

        do {
            try pty.spawn(
                executable: resolved,
                arguments: options.extraArgs,
                environment: env,
                workingDirectory: workingDirectory?.path)
        } catch {
            log.warning(
                "ConPTY spawn failed",
                metadata: ["binary": binaryName, "error": error.localizedDescription])
            throw Error.launchFailed(error.localizedDescription)
        }

        let pid = pty.processID
        guard WindowsPTYRegistry.register(pid: pid, pty: pty, binary: binaryName) else {
            log.debug("PTY launch blocked by shutdown fence", metadata: ["binary": binaryName])
            throw Error.launchFailed("App shutdown in progress")
        }
        WindowsPTYRegistry.endLaunch()
        launchReservationHeld = false
        log.debug("PTY launched (ConPTY)", metadata: ["binary": binaryName, "pid": "\(pid)"])

        // --- I/O helpers ---

        let outputRead = pty.outputReadHandle
        let inputWrite = pty.inputWriteHandle

        func writeTopty(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            data.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress else { return }
                var written: DWORD = 0
                _ = WriteFile(inputWrite, ptr, DWORD(raw.count), &written, nil)
            }
        }

        func readChunk() -> Data {
            var buf = [UInt8](repeating: 0, count: 8192)
            var bytesAvail: DWORD = 0
            guard PeekNamedPipe(outputRead, nil, 0, nil, &bytesAvail, nil),
                  bytesAvail > 0 else {
                return Data()
            }
            let toRead = min(bytesAvail, DWORD(buf.count))
            var bytesRead: DWORD = 0
            guard ReadFile(outputRead, &buf, toRead, &bytesRead, nil), bytesRead > 0 else {
                return Data()
            }
            return Data(buf.prefix(Int(bytesRead)))
        }

        // --- Initial delay ---
        let initialDelayMs = UInt32(max(0, options.initialDelay) * 1000)
        if initialDelayMs > 0 {
            Sleep(initialDelayMs)
        }

        // --- Send the initial script ---
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            writeTopty(trimmed)
            writeTopty("\r\n")
        }

        // --- Read loop ---
        let deadline = Date().addingTimeInterval(options.timeout)
        var buffer = Data()
        var lastOutputAt = Date()
        var urlSeen = false
        var stoppedEarly = false

        let stopNeedles = options.stopOnSubstrings.map { Data($0.utf8) }
        let urlNeedles = [Data("https://".utf8), Data("http://".utf8)]
        let needleLengths = stopNeedles.map(\.count) + urlNeedles.map(\.count)
        let maxNeedle = needleLengths.max() ?? 8
        var scanBuffer = RollingBuffer(maxNeedle: maxNeedle)
        var lastEnter = Date()
        var triggeredSends = Set<Data>()
        var recentText = ""

        let sendNeedles = options.sendOnSubstrings.map { (
            needle: Data($0.key.utf8),
            needleString: $0.key,
            keys: Data($0.value.utf8)) }

        while Date() < deadline {
            let newData = readChunk()
            if !newData.isEmpty {
                buffer.append(newData)
                lastOutputAt = Date()

                if let chunkText = String(bytes: newData, encoding: .utf8) {
                    recentText += chunkText
                    if recentText.count > 8192 {
                        recentText.removeFirst(recentText.count - 8192)
                    }
                }

                let scanData = scanBuffer.append(newData)

                // URL detection
                if urlNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                    if !urlSeen {
                        urlSeen = true
                        onURLDetected?()
                    }
                    if options.stopOnURL {
                        stoppedEarly = true
                        break
                    }
                }

                // Send-on-substring triggers
                for item in sendNeedles where !triggeredSends.contains(item.needle) {
                    let matched = scanData.range(of: item.needle) != nil
                        || recentText.contains(item.needleString)
                    if matched {
                        if let keysString = String(data: item.keys, encoding: .utf8) {
                            writeTopty(keysString)
                        }
                        triggeredSends.insert(item.needle)
                    }
                }

                // Stop-on-substring
                if !stopNeedles.isEmpty, stopNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                    stoppedEarly = true
                    break
                }
            }

            // Idle timeout
            if let idleTimeout = options.idleTimeout,
               !buffer.isEmpty,
               Date().timeIntervalSince(lastOutputAt) >= idleTimeout
            {
                stoppedEarly = true
                break
            }

            // Periodic Enter
            if !urlSeen,
               let every = options.sendEnterEvery,
               Date().timeIntervalSince(lastEnter) >= every
            {
                writeTopty("\r\n")
                lastEnter = Date()
            }

            if !pty.isRunning { break }
            Sleep(60)
        }

        // Settle after early stop
        if stoppedEarly {
            let settle = max(0, min(options.settleAfterStop, deadline.timeIntervalSinceNow))
            if settle > 0 {
                let settleDeadline = Date().addingTimeInterval(settle)
                while Date() < settleDeadline {
                    let extra = readChunk()
                    if !extra.isEmpty { buffer.append(extra) }
                    Sleep(50)
                }
            }
        }

        let text = String(data: buffer, encoding: .utf8) ?? ""
        guard !text.isEmpty else { throw Error.timedOut }
        return Result(text: text)
    }
    // swiftlint:enable function_body_length
}

// MARK: - RollingBuffer (Windows copy)
// On Windows, TTYCommandRunner.swift is excluded by #if canImport(Darwin) || os(Linux).
// RollingBuffer is a pure-Swift utility needed by the run() loop above.

extension TTYCommandRunner {
    struct RollingBuffer {
        private let maxNeedle: Int
        private var tail = Data()

        init(maxNeedle: Int) {
            self.maxNeedle = max(0, maxNeedle)
        }

        mutating func append(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            var combined = Data()
            combined.reserveCapacity(self.tail.count + data.count)
            combined.append(self.tail)
            combined.append(data)
            if self.maxNeedle > 1 {
                if combined.count >= self.maxNeedle - 1 {
                    self.tail = combined.suffix(self.maxNeedle - 1)
                } else {
                    self.tail = combined
                }
            } else {
                self.tail.removeAll(keepingCapacity: true)
            }
            return combined
        }

        mutating func reset() {
            self.tail.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - TTYProcessTreeTerminator stub

enum TTYProcessTreeTerminator {
    static func descendantPIDs(
        of rootPID: pid_t,
        childResolver: (pid_t) -> [pid_t] = Self.currentChildPIDs(of:)) -> [pid_t] { [] }

    static func currentChildPIDs(of parentPID: pid_t) -> [pid_t] { [] }

    static func terminateProcessTree(
        rootPID: pid_t,
        processGroup: pid_t?,
        signal: Int32,
        knownDescendants: [pid_t] = [],
        childResolver: (pid_t) -> [pid_t] = Self.currentChildPIDs(of:),
        signalSender: (pid_t, Int32) -> Void = { _, _ in }) {}
}

#endif // os(Windows)
