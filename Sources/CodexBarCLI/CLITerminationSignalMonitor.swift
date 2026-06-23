import CodexBarCore
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || os(Linux)
private func handleCLITerminationSignal(_: Int32) {}
#endif

final class CLITerminationSignalMonitor: @unchecked Sendable {
    #if canImport(Darwin) || os(Linux)
    static let signalNumbers = [SIGINT, SIGTERM, SIGHUP]
    private let sources: [DispatchSourceSignal]
    #endif

    private let lock = NSLock()
    private var isCancelled = false

    init(onSignal: @escaping @Sendable (Int32) -> Void) {
        #if canImport(Darwin) || os(Linux)
        self.sources = Self.signalNumbers.map { signalNumber in
            Self.installCaptureHandler(for: signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
            source.setEventHandler {
                onSignal(signalNumber)
            }
            source.resume()
            return source
        }
        #endif
    }

    func cancel() {
        self.lock.lock()
        guard !self.isCancelled else {
            self.lock.unlock()
            return
        }
        self.isCancelled = true
        self.lock.unlock()

        #if canImport(Darwin) || os(Linux)
        for source in self.sources {
            source.cancel()
        }
        for signalNumber in Self.signalNumbers {
            Self.restoreDefaultHandler(for: signalNumber)
        }
        #endif
    }

    deinit {
        self.cancel()
    }

    static func terminateActiveHelpersAndReraise(_ signalNumber: Int32) {
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
        #if canImport(Darwin) || os(Linux)
        restoreDefaultHandler(for: signalNumber)
        _ = kill(getpid(), signalNumber)
        #endif
    }

    #if canImport(Darwin) || os(Linux)
    private static func installCaptureHandler(for signalNumber: Int32) {
        #if canImport(Darwin)
        _ = Darwin.signal(signalNumber, handleCLITerminationSignal)
        #else
        _ = Glibc.signal(signalNumber, handleCLITerminationSignal)
        #endif
    }

    private static func restoreDefaultHandler(for signalNumber: Int32) {
        #if canImport(Darwin)
        _ = Darwin.signal(signalNumber, SIG_DFL)
        #else
        _ = Glibc.signal(signalNumber, SIG_DFL)
        #endif
    }
    #endif
}
