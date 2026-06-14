#if os(Windows)
import Foundation

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
                "Missing CLI '\(bin)'. PTY is not supported on Windows."
            case let .launchFailed(msg): "Failed to launch process: \(msg)"
            case .timedOut: "PTY command timed out."
            }
        }
    }

    public init() {}

    public static func terminateActiveProcessesForAppShutdown() {}

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

    public static func which(_ tool: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "").split(separator: ";").map(String.init)
        let exts = (env["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(separator: ";").map(String.init)
        for dir in paths {
            for ext in exts {
                let candidate = "\(dir)\\\(tool)\(ext)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    public static func enrichedPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? ""
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
        return env
    }

    static func locateBundledHelper(_ name: String) -> String? { nil }

    public func run(
        binary: String,
        send _: String,
        options _: Options = Options(),
        onURLDetected _: (@Sendable () -> Void)? = nil) throws -> Result
    {
        throw Error.launchFailed("PTY is not available on Windows; use OAuth or API-key source instead")
    }
}

enum TTYProcessTreeTerminator {
    static func descendantPIDs(of rootPID: pid_t, childResolver: (pid_t) -> [pid_t] = Self.currentChildPIDs(of:)) -> [pid_t] { [] }

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
