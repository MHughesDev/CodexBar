import Foundation

/// Windows note (§2.3): `readabilityHandler` is a Foundation API that works on Windows via
/// swift-corelibs-foundation.  The underlying mechanism differs from macOS (Dispatch I/O vs.
/// GCD kevent), but the API contract — fire callback when data is available, deliver empty
/// Data on EOF — is maintained.  No platform guard is needed here; validate EOF semantics
/// on Windows pipes if you observe missing output at end-of-process.
package final class ProcessPipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var data = Data()
    private var activeCallbacks = 0
    private var isFinished = false
    private var isStopping = false
    private var continuation: CheckedContinuation<Void, Never>?

    package init(pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
    }

    package func start() {
        self.handle.readabilityHandler = { [weak self] handle in
            self?.handleReadableData(from: handle)
        }
    }

    package func finish(timeout: Duration) async -> Data {
        let drainTask = Task<Void, Error> {
            await self.waitUntilFinished()
        }
        let join = BoundedTaskJoin(sourceTask: drainTask)
        _ = await join.value(joinGrace: timeout)
        return self.stopAndSnapshot()
    }

    package func stop() {
        _ = self.stopAndSnapshot()
    }

    private func handleReadableData(from handle: FileHandle) {
        self.condition.lock()
        guard !self.isStopping else {
            self.condition.unlock()
            return
        }
        self.activeCallbacks += 1
        self.condition.unlock()

        let chunk = handle.availableData
        var continuation: CheckedContinuation<Void, Never>?

        self.condition.lock()
        if chunk.isEmpty {
            self.isFinished = true
            continuation = self.continuation
            self.continuation = nil
        } else {
            self.data.append(chunk)
        }
        self.activeCallbacks -= 1
        if self.activeCallbacks == 0 {
            self.condition.broadcast()
        }
        self.condition.unlock()

        if chunk.isEmpty {
            handle.readabilityHandler = nil
        }
        continuation?.resume()
    }

    private func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            self.condition.lock()
            if self.isFinished || self.isStopping {
                self.condition.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.condition.unlock()
        }
    }

    private func stopAndSnapshot() -> Data {
        self.handle.readabilityHandler = nil

        let continuation: CheckedContinuation<Void, Never>?
        let snapshot: Data
        self.condition.lock()
        self.isStopping = true
        while self.activeCallbacks > 0 {
            self.condition.wait()
        }
        self.isFinished = true
        continuation = self.continuation
        self.continuation = nil
        snapshot = self.data
        self.condition.unlock()

        continuation?.resume()
        return snapshot
    }
}
