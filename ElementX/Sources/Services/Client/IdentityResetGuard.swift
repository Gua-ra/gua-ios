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
    /// The `reset(auth:)` call running under this guard, if one was started.
    var inFlightReset: Task<Result<Void, Error>, Never>? { get }

    /// Runs `reset(auth:)` under the guard's ownership and returns the task to wait on. The guard
    /// is released when the call returns, whether or not anyone is still waiting for it. A second
    /// call while one is running returns the running task.
    func runReset(_ handle: IdentityResetHandle, auth: AuthData?) -> Task<Result<Void, Error>, Never>

    /// Releases the guard if no reset call is in flight. A no-op otherwise, and after any release.
    func releaseIfIdle() async
}

/// Keeps own-user `/keys/query` traffic away from an identity reset.
///
/// Between `resetIdentity()` creating a new private cross-signing identity locally and the
/// authenticated upload landing, a `/keys/query` answered with the old identity makes the SDK clear
/// the new private keys, and the upload then succeeds anyway (matrix-rust-sdk#4728). The guard holds
/// three things for the whole reset: a per-account marker in the App Group defaults that the
/// notification extension respects, the in-process suppression of every sync start, and the
/// stopped encryption sync.
///
/// Invariants:
/// - the marker is written before the sync is stopped and cleared only after it was restarted, so
///   the sync is never stopped without the marker being present;
/// - `release()` is idempotent and is the only place that restarts the sync;
/// - a `reset(auth:)` started through `runReset` keeps the guard held until it returns. The
///   bindings cannot cancel that call, and a cancelled handle still lets an upload already in
///   flight land, so no UI timeout may release the guard early.
final class IdentityResetGuard: IdentityResetGuardProtocol, @unchecked Sendable {
    struct Dependencies {
        let stopSync: () async -> Void
        let startSync: () async -> Void
        let isSyncRunning: () -> Bool
        let writeMarker: (Date?) -> Void
        /// The reset has landed on the server; the pending marker may go.
        let resetLanded: () -> Void
        let provisionAfterReset: () async -> Void
        /// Drops the owner's reference, which lifts the in-process suppression.
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

    /// Acquires the guard: marker, then hold, then the stopped sync.
    ///
    /// `establishHold` is the owner's chance to set its reference (which gates every start) and to
    /// drop a pending restart. The sync is stopped twice: `SyncService.start()` and `stop()` serialise
    /// on one lock inside the SDK, so a start that was already inside the SDK when the hold went up
    /// runs after the first stop and is caught by the second.
    func acquire(establishHold: () -> Void) async {
        dependencies.writeMarker(.now)
        establishHold()
        await dependencies.stopSync()
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

    /// The one terminal ordering: suppression off, sync restarted, marker cleared.
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
