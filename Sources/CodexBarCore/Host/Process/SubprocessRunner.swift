#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if os(Windows)
/// Encapsulates Windows Job Object lifecycle for process-tree management.
///
/// A Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` ensures the entire
/// child process tree is terminated when the job handle is closed or
/// `terminate()` is called — the Windows equivalent of `kill(-pgid, SIGKILL)`.
///
/// Implemented as a class so it can be captured across `@Sendable` closures
/// and async boundaries without copying. Internal locking ensures safe
/// concurrent access from timeout callbacks and task-cancellation handlers.
private final class WindowsProcessTree: @unchecked Sendable {
    private let lock = NSLock()
    private var jobHandle: HANDLE = INVALID_HANDLE_VALUE
    private var isClosed = false

    /// Creates a Job Object and assigns the given process to it.
    /// Returns `nil` when job-object creation or assignment fails (non-fatal:
    /// the process still runs, it just won't be tree-killed on Windows).
    init?(processHandle: HANDLE) {
        guard processHandle != INVALID_HANDLE_VALUE else { return nil }

        // Create an anonymous Job Object.
        guard let handle = CreateJobObjectW(nil, nil) else { return nil }

        // Configure the job so that closing its handle terminates all children.
        var extInfo = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        extInfo.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        let extInfoSize = DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
        withUnsafeMutablePointer(to: &extInfo) { ptr in
            _ = SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                ptr,
                extInfoSize)
        }

        // Assign the child process to the job.
        guard AssignProcessToJobObject(handle, processHandle) else {
            CloseHandle(handle)
            return nil
        }

        self.jobHandle = handle
    }

    deinit {
        self.close()
    }

    /// Terminates all processes in the job tree immediately.
    func terminate() {
        self.lock.lock()
        let handle = self.jobHandle
        self.lock.unlock()
        guard handle != INVALID_HANDLE_VALUE else { return }
        _ = TerminateJobObject(handle, 1)
    }

    /// Releases the job handle. Because `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`
    /// is set, this also kills the process tree if `terminate()` was not
    /// already called.
    func close() {
        self.lock.lock()
        guard !self.isClosed, self.jobHandle != INVALID_HANDLE_VALUE else {
            self.lock.unlock()
            return
        }
        let handle = self.jobHandle
        self.jobHandle = INVALID_HANDLE_VALUE
        self.isClosed = true
        self.lock.unlock()
        CloseHandle(handle)
    }
}
#endif

public enum SubprocessRunnerError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case timedOut(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(binary):
            return "Missing CLI '\(binary)'. Install it and restart CodexBar."
        case let .launchFailed(details):
            return "Failed to launch process: \(details)"
        case let .timedOut(label):
            return "Command timed out: \(label)"
        case let .nonZeroExit(code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed (\(code)): \(trimmed)"
        }
    }
}

public struct SubprocessResult: Sendable {
    public let stdout: String
    public let stderr: String
}

public enum SubprocessRunner {
    private static let log = CodexBarLog.logger(LogCategories.subprocess)
    private static let timeoutQueue = DispatchQueue(
        label: "com.steipete.codexbar.subprocess.timeout",
        qos: .userInitiated,
        attributes: .concurrent)

    /// Thread-safe flag for communicating between concurrent tasks (e.g. timeout → caller).
    private final class KillFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.withLock { self.value = true }
        }

        var isSet: Bool {
            self.lock.withLock { self.value }
        }
    }

    private final class TimeoutTimer: @unchecked Sendable {
        private let timer: any DispatchSourceTimer

        init(timer: any DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            self.timer.cancel()
        }
    }

    private static func timeoutInterval(_ timeout: TimeInterval) -> DispatchTimeInterval {
        guard timeout.isFinite else {
            return .seconds(Int.max)
        }
        let nanoseconds = max(0, min(timeout * 1_000_000_000, Double(Int.max)))
        return .nanoseconds(Int(nanoseconds))
    }

    private final class ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuation: CheckedContinuation<Int32, Never>?

        func resolve(_ status: Int32) {
            let continuation: CheckedContinuation<Int32, Never>?
            self.lock.lock()
            self.status = status
            continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: status)
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                let status: Int32?
                self.lock.lock()
                status = self.status
                if status == nil {
                    self.continuation = continuation
                }
                self.lock.unlock()

                if let status {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    #if os(Windows)
    /// Terminates a process using Job Object tree-kill (Windows).
    /// Returns `true` if the process was running and termination was initiated.
    @discardableResult
    private static func terminateProcess(
        _ process: Process,
        windowsProcessTree: WindowsProcessTree? = nil) -> Bool
    {
        guard process.isRunning else { return false }
        // Foundation's Process.terminate() sends WM_CLOSE; for CLI tools we escalate
        // to TerminateJobObject which kills the entire process tree.
        process.terminate()
        if let tree = windowsProcessTree {
            tree.terminate()
            tree.close()
        }
        let killDeadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Force-terminate the root process if it's still alive after the job kill.
        if process.isRunning {
            process.terminate()
        }
        return true
    }
    #else
    /// Terminates a process and its process group, escalating from SIGTERM to SIGKILL (POSIX).
    /// Returns `true` if the process was actually killed, `false` if it had already exited.
    @discardableResult
    private static func terminateProcess(_ process: Process, processGroup: pid_t?) -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        if let pgid = processGroup {
            kill(-pgid, SIGTERM)
        }
        let killDeadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < killDeadline {
            usleep(50000)
        }
        if process.isRunning {
            if let pgid = processGroup {
                kill(-pgid, SIGKILL)
            }
            kill(process.processIdentifier, SIGKILL)
        }
        return true
    }
    #endif

    // MARK: - Public API

    public static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        standardInput: Any? = nil,
        currentDirectoryURL: URL? = nil,
        label: String) async throws -> SubprocessResult
    {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SubprocessRunnerError.binaryNotFound(binary)
        }

        let start = Date()
        let binaryName = URL(fileURLWithPath: binary).lastPathComponent
        self.log.debug(
            "Subprocess start",
            metadata: ["label": label, "binary": binaryName, "timeout": "\(timeout)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = standardInput
        let stdoutCapture = ProcessPipeCapture(pipe: stdoutPipe)
        let stderrCapture = ProcessPipeCapture(pipe: stderrPipe)

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.resolve(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutCapture.stop()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrCapture.stop()
            stderrPipe.fileHandleForWriting.closeFile()
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }
        stdoutCapture.start()
        stderrCapture.start()

        let pid = process.processIdentifier

        // --- Process-tree management (platform-specific) ---
        // On Windows: Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE kills the
        // entire child tree when the job handle is closed or TerminateJobObject is called.
        // On POSIX: setpgid promotes the child into its own process group so kill(-pgid,…)
        // reaches every descendant.
        #if os(Windows)
        let winTree: WindowsProcessTree? = {
            guard let procHandle = OpenProcess(
                DWORD(PROCESS_ALL_ACCESS), false, DWORD(pid))
            else { return nil }
            // WindowsProcessTree takes ownership of the job handle; close our
            // temporary process handle immediately after assigning to the job.
            defer { CloseHandle(procHandle) }
            return WindowsProcessTree(processHandle: procHandle)
        }()
        #else
        let processGroup: pid_t? = setpgid(pid, pid) == 0 ? pid : nil
        #endif

        let exitCodeTask = Task<Int32, Never> {
            await termination.wait()
        }

        let killedByTimeout = KillFlag()
        let timeoutTimer = DispatchSource.makeTimerSource(queue: self.timeoutQueue)
        timeoutTimer.schedule(deadline: .now() + self.timeoutInterval(timeout))
        timeoutTimer.setEventHandler {
            guard process.isRunning else { return }
            killedByTimeout.set()
            #if os(Windows)
            self.terminateProcess(process, windowsProcessTree: winTree)
            #else
            self.terminateProcess(process, processGroup: processGroup)
            #endif
        }
        timeoutTimer.resume()
        let timeoutTimerBox = TimeoutTimer(timer: timeoutTimer)

        do {
            let exitCode = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let code = await exitCodeTask.value
                try Task.checkCancellation()
                return code
            } onCancel: {
                timeoutTimerBox.cancel()
                #if os(Windows)
                self.terminateProcess(process, windowsProcessTree: winTree)
                #else
                self.terminateProcess(process, processGroup: processGroup)
                #endif
            }
            timeoutTimerBox.cancel()

            let duration = Date().timeIntervalSince(start)
            // Race guard: the timeout timer may kill the process just before the
            // exit code arrives. Key off the explicit kill flag so a completed
            // process is not misclassified when the awaiting task resumes late.
            if killedByTimeout.isSet {
                self.log.warning(
                    "Subprocess timed out",
                    metadata: [
                        "label": label,
                        "binary": binaryName,
                        "duration_ms": "\(Int(duration * 1000))",
                    ])
                throw SubprocessRunnerError.timedOut(label)
            }

            async let stdoutData = stdoutCapture.finish(timeout: .seconds(1))
            async let stderrData = stderrCapture.finish(timeout: .seconds(1))
            let stdout = await String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = await String(data: stderrData, encoding: .utf8) ?? ""

            if exitCode != 0 {
                let duration = Date().timeIntervalSince(start)
                self.log.warning(
                    "Subprocess failed",
                    metadata: [
                        "label": label,
                        "binary": binaryName,
                        "status": "\(exitCode)",
                        "duration_ms": "\(Int(duration * 1000))",
                    ])
                throw SubprocessRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }

            self.log.debug(
                "Subprocess exit",
                metadata: [
                    "label": label,
                    "binary": binaryName,
                    "status": "\(exitCode)",
                    "duration_ms": "\(Int(duration * 1000))",
                ])
            return SubprocessResult(stdout: stdout, stderr: stderr)
        } catch {
            let duration = Date().timeIntervalSince(start)
            self.log.warning(
                "Subprocess error",
                metadata: [
                    "label": label,
                    "binary": binaryName,
                    "duration_ms": "\(Int(duration * 1000))",
                ])
            // Safety net: ensure the process is dead (may already be killed by timeout timer).
            #if os(Windows)
            self.terminateProcess(process, windowsProcessTree: winTree)
            #else
            self.terminateProcess(process, processGroup: processGroup)
            #endif
            exitCodeTask.cancel()
            stdoutCapture.stop()
            stderrCapture.stop()
            throw error
        }
    }
}
