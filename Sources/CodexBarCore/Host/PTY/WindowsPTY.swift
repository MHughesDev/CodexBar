#if os(Windows)
import Foundation
import WinSDK

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` is defined as a C preprocessor macro and may
/// not be exported by Swift's WinSDK overlay.  We define the numeric value directly:
/// ProcThreadAttributeValue(ProcThreadAttributePseudoConsole=22, Thread=0, Input=0, Additive=1)
/// = 22 | (0 << 16) | (0 << 17) | (1 << 19) = 22 | 0x00080000 = 0x00080016
/// (Windows SDK headers actually ship this as 0x00020016 — use that well-known value.)
private let kProcThreadAttributePseudoConsole: SIZE_T = 0x0002_0016

/// Windows pseudo-console (ConPTY) wrapper.
///
/// Maps the POSIX `forkpty`/`openpty` API surface used by `TTYCommandRunner`
/// onto `CreatePseudoConsole` + `STARTUPINFOEXW` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
///
/// Lifecycle:
/// 1. `init(size:)` — creates two anonymous pipe pairs and calls `CreatePseudoConsole`.
/// 2. `spawn(executable:arguments:environment:)` — builds a `STARTUPINFOEXW`, calls `CreateProcessW`.
/// 3. `resize(to:)` — calls `ResizePseudoConsole`.
/// 4. `terminate()` — `TerminateProcess` + `ClosePseudoConsole`, closes all handles.
/// 5. `close()` — releases any remaining handles (idempotent).
final class WindowsPTY: @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Public handles (read-only outside)

    /// Write end of the input pipe — caller writes terminal input here.
    private(set) var inputWriteHandle: HANDLE = INVALID_HANDLE_VALUE
    /// Read end of the output pipe — caller reads terminal output from here.
    private(set) var outputReadHandle: HANDLE = INVALID_HANDLE_VALUE

    // MARK: - Private state

    // `HPCON` is `PVOID` (`UnsafeMutableRawPointer?`) in Swift WinSDK.
    // We store it as `HPCON` (which is already Optional) and use nil to mean "not created".
    private var hPC: HPCON = nil
    private var inputReadHandle: HANDLE = INVALID_HANDLE_VALUE // child side of input
    private var outputWriteHandle: HANDLE = INVALID_HANDLE_VALUE // child side of output
    private var processHandle: HANDLE = INVALID_HANDLE_VALUE
    private var threadHandle: HANDLE = INVALID_HANDLE_VALUE
    private var _processID: DWORD = 0
    private var isClosed = false

    // MARK: - Types

    struct Size {
        let columns: Int32
        let rows: Int32
    }

    enum PTYError: Swift.Error, LocalizedError {
        case createPipeFailed(String, DWORD)
        case createPseudoConsoleFailed(DWORD)
        case attributeListFailed(DWORD)
        case createProcessFailed(DWORD)
        case alreadySpawned

        var errorDescription: String? {
            switch self {
            case let .createPipeFailed(which, code):
                "CreatePipe(\(which)) failed with error \(code)"
            case let .createPseudoConsoleFailed(code):
                "CreatePseudoConsole failed with error \(code)"
            case let .attributeListFailed(code):
                "InitializeProcThreadAttributeList failed with error \(code)"
            case let .createProcessFailed(code):
                "CreateProcessW failed with error \(code)"
            case .alreadySpawned:
                "WindowsPTY: spawn() called more than once"
            }
        }
    }

    // MARK: - Init

    /// Creates two anonymous pipe pairs and opens a ConPTY of the given size.
    ///
    /// After `init` succeeds:
    /// - `inputWriteHandle`  — caller writes keystrokes/commands here
    /// - `outputReadHandle`  — caller reads terminal output from here
    init(size: Size) throws {
        // --- Input pipe: caller → child ---
        // inputReadHandle  = child's STDIN (passed to ConPTY)
        // inputWriteHandle = caller writes keystrokes here
        var inputRead: HANDLE = INVALID_HANDLE_VALUE
        var inputWrite: HANDLE = INVALID_HANDLE_VALUE
        guard CreatePipe(&inputRead, &inputWrite, nil, 0) else {
            throw PTYError.createPipeFailed("input", GetLastError())
        }

        // --- Output pipe: child → caller ---
        // outputWriteHandle = child's STDOUT/STDERR (passed to ConPTY)
        // outputReadHandle  = caller reads terminal output here
        var outputRead: HANDLE = INVALID_HANDLE_VALUE
        var outputWrite: HANDLE = INVALID_HANDLE_VALUE
        guard CreatePipe(&outputRead, &outputWrite, nil, 0) else {
            CloseHandle(inputRead)
            CloseHandle(inputWrite)
            throw PTYError.createPipeFailed("output", GetLastError())
        }

        // --- Create the pseudo-console ---
        // `HPCON` = `PVOID` = `UnsafeMutableRawPointer?` in Swift WinSDK.
        // `CreatePseudoConsole` writes a non-nil handle on success.
        var coord = COORD(X: Int16(size.columns), Y: Int16(size.rows))
        var pc: HPCON = nil
        let hr = CreatePseudoConsole(coord, inputRead, outputWrite, 0, &pc)
        // The child-side pipe ends are now owned by the ConPTY; close our copies
        // so we don't hold them open after the ConPTY is created.
        CloseHandle(inputRead)
        CloseHandle(outputWrite)

        guard hr == S_OK, pc != nil else {
            CloseHandle(inputWrite)
            CloseHandle(outputRead)
            // Cast HRESULT (Int32) to UInt32 via bitPattern to preserve error codes.
            throw PTYError.createPseudoConsoleFailed(DWORD(bitPattern: hr))
        }

        self.hPC = pc
        self.inputWriteHandle = inputWrite
        self.outputReadHandle = outputRead
        // Store child-side handles as INVALID since we've closed them above
        self.inputReadHandle = INVALID_HANDLE_VALUE
        self.outputWriteHandle = INVALID_HANDLE_VALUE
    }

    deinit {
        self.close()
    }

    // MARK: - Spawn

    /// Launches `executable` with `arguments` wired to the ConPTY.
    ///
    /// Builds a `STARTUPINFOEXW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`,
    /// then calls `CreateProcessW`.  May only be called once per `WindowsPTY` instance.
    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String? = nil) throws
    {
        self.lock.lock()
        guard !self.isClosed, self.processHandle == INVALID_HANDLE_VALUE else {
            self.lock.unlock()
            throw PTYError.alreadySpawned
        }
        let pc = self.hPC
        self.lock.unlock()

        guard pc != nil else {
            throw PTYError.alreadySpawned
        }

        // Build the command line string: executable + arguments, each quoted.
        let cmdLine = Self.buildCommandLine(executable: executable, arguments: arguments)

        // Build the environment block (null-terminated key=value pairs, double-null terminated).
        let envBlock = Self.buildEnvironmentBlock(environment)

        // --- Allocate a STARTUPINFOEXW with the ConPTY attribute ---
        var siEx = STARTUPINFOEXW()
        siEx.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)

        // `LPPROC_THREAD_ATTRIBUTE_LIST` is an opaque pointer in Swift WinSDK.
        // Allocate raw memory of the required size and use it as an opaque list.
        var attrListSize = 0
        // First call with nil: just measures the required buffer size.
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attrListSize)
        guard attrListSize > 0 else {
            throw PTYError.attributeListFailed(GetLastError())
        }

        let attrListBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: attrListSize,
            alignment: 8)
        defer { attrListBuffer.deallocate() }

        // Reinterpret as the opaque attribute list pointer type.
        let attrListPtr = OpaquePointer(attrListBuffer)

        guard InitializeProcThreadAttributeList(attrListPtr, 1, 0, &attrListSize) else {
            throw PTYError.attributeListFailed(GetLastError())
        }
        defer { DeleteProcThreadAttributeList(attrListPtr) }

        // Register the ConPTY handle as the pseudo-console attribute.
        // `UpdateProcThreadAttribute` requires a pointer to the HPCON value.
        // We hold the HPCON in a local variable and take its address.
        var pcLocal: HPCON = pc
        guard withUnsafeMutablePointer(to: &pcLocal, { pcPtr in
            UpdateProcThreadAttribute(
                attrListPtr,
                0,
                kProcThreadAttributePseudoConsole,
                UnsafeMutableRawPointer(pcPtr),
                MemoryLayout<HPCON>.size,
                nil,
                nil)
        }) else {
            throw PTYError.attributeListFailed(GetLastError())
        }

        siEx.lpAttributeList = attrListPtr

        // --- Launch the process ---
        // Pre-convert all strings to null-terminated UTF-16 arrays so they stay alive
        // across the CreateProcessW call.
        var pi = PROCESS_INFORMATION()
        // EXTENDED_STARTUPINFO_PRESENT: use STARTUPINFOEXW.
        // CREATE_UNICODE_ENVIRONMENT: environment block is UTF-16 encoded (matches buildEnvironmentBlock).
        let creationFlags = DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT)

        // Mutable UTF-16 command line (CreateProcessW requires a mutable lpCommandLine).
        var cmdLineW = Array(cmdLine.utf16) + [0]
        // Optional wide working directory.
        var workDirW: [WCHAR]? = workingDirectory.map { Array($0.utf16) + [0] }

        let launched: Bool = withUnsafeMutablePointer(to: &siEx.StartupInfo) { startupPtr in
            if let envBlock {
                envBlock.withUnsafeBytes { envBytes in
                    let envPtr = envBytes.baseAddress.map { UnsafeMutableRawPointer(mutating: $0) }
                    if var wdBuf = workDirW {
                        CreateProcessW(
                            nil,
                            &cmdLineW,
                            nil,
                            nil,
                            false,
                            creationFlags,
                            envPtr,
                            &wdBuf,
                            startupPtr,
                            &pi)
                    } else {
                        CreateProcessW(
                            nil,
                            &cmdLineW,
                            nil,
                            nil,
                            false,
                            creationFlags,
                            envPtr,
                            nil,
                            startupPtr,
                            &pi)
                    }
                }
            } else {
                if var wdBuf = workDirW {
                    CreateProcessW(
                        nil,
                        &cmdLineW,
                        nil,
                        nil,
                        false,
                        creationFlags,
                        nil,
                        &wdBuf,
                        startupPtr,
                        &pi)
                } else {
                    CreateProcessW(
                        nil,
                        &cmdLineW,
                        nil,
                        nil,
                        false,
                        creationFlags,
                        nil,
                        nil,
                        startupPtr,
                        &pi)
                }
            }
        }

        guard launched else {
            throw PTYError.createProcessFailed(GetLastError())
        }

        self.lock.lock()
        self.processHandle = pi.hProcess
        self.threadHandle = pi.hThread
        self._processID = pi.dwProcessId
        self.lock.unlock()
    }

    // MARK: - Resize

    /// Resizes the pseudo-console. Safe to call from any thread.
    func resize(to size: Size) {
        self.lock.lock()
        let pc = self.hPC
        self.lock.unlock()
        guard let pc else { return }
        let coord = COORD(X: Int16(size.columns), Y: Int16(size.rows))
        _ = ResizePseudoConsole(pc, coord)
    }

    // MARK: - Terminate

    /// Terminates the child process and closes the ConPTY.  Idempotent.
    func terminate() {
        self.lock.lock()
        let ph = self.processHandle
        let pc = self.hPC
        self.hPC = nil
        self.lock.unlock()

        if ph != INVALID_HANDLE_VALUE {
            _ = TerminateProcess(ph, 1)
        }
        if let pc {
            ClosePseudoConsole(pc)
        }
        self.close()
    }

    // MARK: - Close

    /// Releases all handles.  Does NOT terminate the child process.
    /// Call `terminate()` first if you want to kill the child.
    func close() {
        self.lock.lock()
        guard !self.isClosed else {
            self.lock.unlock()
            return
        }
        self.isClosed = true

        let handles: [HANDLE] = [
            self.processHandle,
            self.threadHandle,
            self.inputWriteHandle,
            self.outputReadHandle,
            self.inputReadHandle,
            self.outputWriteHandle,
        ]
        self.processHandle = INVALID_HANDLE_VALUE
        self.threadHandle = INVALID_HANDLE_VALUE
        self.inputWriteHandle = INVALID_HANDLE_VALUE
        self.outputReadHandle = INVALID_HANDLE_VALUE
        self.inputReadHandle = INVALID_HANDLE_VALUE
        self.outputWriteHandle = INVALID_HANDLE_VALUE

        let pc = self.hPC
        self.hPC = nil
        self.lock.unlock()

        for h in handles where h != INVALID_HANDLE_VALUE {
            CloseHandle(h)
        }
        if let pc {
            ClosePseudoConsole(pc)
        }
    }

    // MARK: - Properties

    var processID: DWORD {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._processID
    }

    var isRunning: Bool {
        self.lock.lock()
        let ph = self.processHandle
        self.lock.unlock()
        guard ph != INVALID_HANDLE_VALUE else { return false }
        return WaitForSingleObject(ph, 0) == WAIT_TIMEOUT
    }

    // MARK: - Helpers

    /// Builds a Windows command-line string quoting each argument.
    private static func buildCommandLine(executable: String, arguments: [String]) -> String {
        var parts = [Self.quoteArgument(executable)]
        for arg in arguments {
            parts.append(Self.quoteArgument(arg))
        }
        return parts.joined(separator: " ")
    }

    /// Minimal quoting: wraps the argument in double quotes and escapes internal quotes.
    private static func quoteArgument(_ arg: String) -> String {
        if !arg.contains(" "), !arg.contains("\""), !arg.contains("\t") {
            return arg
        }
        var out = "\""
        for ch in arg {
            if ch == "\"" { out += "\\\"" } else { out.append(ch) }
        }
        out += "\""
        return out
    }

    /// Builds a Windows environment block: null-terminated KEY=VALUE pairs, terminated by an extra null.
    private static func buildEnvironmentBlock(_ env: [String: String]?) -> Data? {
        guard let env else { return nil }
        var block = Data()
        for (key, value) in env {
            let pair = "\(key)=\(value)\0"
            block.append(contentsOf: pair.utf16.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } })
        }
        // Double-null terminator (one extra UTF-16 null)
        block.append(contentsOf: [0, 0])
        return block
    }
}

#endif // os(Windows)
