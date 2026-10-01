//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

// sourcery: AutoMockable
protocol IdentityResetGuardProtocol: AnyObject {
    var inFlightReset: Task<Result<Void, Error>, Never>? { get }

    /// Releases the guard when the call returns, even if no one awaits the task. A call while one
    /// is running returns the running task.
    func runReset(_ handle: IdentityResetHandle, auth: AuthData?) -> Task<Result<Void, Error>, Never>

    func releaseIfIdle() async
}

/// Keeps the encryption sync stopped during an identity reset: an own-user `/keys/query` answered
/// with the old identity makes the SDK clear the new private keys (matrix-rust-sdk#4728).
/// The marker is written before the sync stops and cleared only after it restarts.
final class IdentityResetGuard: IdentityResetGuardProtocol, @unchecked Sendable {
    struct Dependencies {
        let stopSync: () async -> Void
        let startSync: () async -> Void
        let isSyncRunning: () -> Bool
        let writeMarker: (Date?) -> Void
        let resetLanded: () -> Void
        let provisionAfterReset: () async -> Void
        let onReleased: () -> Void
    }

    private let dependencies: Dependencies
    private let refreshInterval: Duration
    private let lock = NSLock()
    private var isReleased = false
    private var inFlight: Task<Result<Void, Error>, Never>?
    private var refreshTask: Task<Void, Never>?

    init(dependencies: Dependencies, refreshInterval: Duration = IdentityResetMarker.refreshInterval) {
        self.dependencies = dependencies
        self.refreshInterval = refreshInterval
    }

    deinit {
        refreshTask?.cancel()
        if !isReleased {
            MXLog.error("GUA-KEYSTORE: identity reset guard deallocated while held; clearing the shared marker.")
            dependencies.writeMarker(nil)
        }
    }

    var inFlightReset: Task<Result<Void, Error>, Never>? {
        lock.withLock { inFlight }
    }

    var isHeld: Bool {
        lock.withLock { !isReleased }
    }

    func acquire(establishHold: () -> Void) async {
        dependencies.writeMarker(.now)
        establishHold()
        await dependencies.stopSync()
        // A start already inside the SDK when the hold went up runs after the first stop, so stop again.
        try? await Task.sleep(for: .milliseconds(100))
        if dependencies.isSyncRunning() {
            MXLog.warning("GUA-KEYSTORE: sync started again during identity reset acquisition; stopping it once more.")
        }
        await dependencies.stopSync()
        startRefreshingMarker()
    }

    func runReset(_ handle: IdentityResetHandle, auth: AuthData?) -> Task<Result<Void, Error>, Never> {
        lock.lock()
        if let inFlight {
            lock.unlock()
            return inFlight
        }

        let task = Task<Result<Void, Error>, Never> { [self] in
            let result: Result<Void, Error>
            do {
                try await handle.reset(auth: auth)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            if case .success = result {
                dependencies.resetLanded()
            }

            await release()

            if case .success = result {
                Task { await dependencies.provisionAfterReset() }
            }

            return result
        }
        inFlight = task
        lock.unlock()
        return task
    }

    func releaseIfIdle() async {
        guard inFlightReset == nil else { return }
        await release()
    }

    private func release() async {
        let alreadyReleased: Bool = lock.withLock {
            defer { isReleased = true }
            return isReleased
        }
        guard !alreadyReleased else { return }

        refreshTask?.cancel()
        dependencies.onReleased()
        await dependencies.startSync()
        dependencies.writeMarker(nil)
    }

    private func startRefreshingMarker() {
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, isHeld, !Task.isCancelled else { return }
                dependencies.writeMarker(.now)
            }
        }
    }
}
