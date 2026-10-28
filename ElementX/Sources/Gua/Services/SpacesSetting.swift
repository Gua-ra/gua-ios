//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// The account-wide Spaces switch. It is stored in account data so it follows the account to every phone;
/// `AppSettings.spacesEnabled` is this device's copy, which the UI observes. One instance per user session.
@MainActor
final class SpacesSetting {
    static let accountDataType = "global.gua.spaces"

    private struct Content: Decodable {
        let enabled: Bool
    }

    private let clientProxy: ClientProxyProtocol
    private let appSettings: AppSettings
    /// How long a written value may wait for sync to bring it back before a disagreeing stored value wins.
    private let echoTimeout: TimeInterval

    /// The latest value this phone asked for, until the store reads it back or its write fails.
    private var pendingValue: Bool?
    /// Restored when the latest write fails: the last value known to be stored, or the device copy before `pendingValue`.
    private var fallbackValue = false
    private var echoDeadline: Date?
    private var latestRequest = 0
    private var writeTask: Task<Result<Void, ClientProxyError>, Never>?
    /// Set once a write from this phone succeeds, after which the account always has a stored value.
    private var hasConfirmedWrite = false
    private var isInvalidated = false

    private var isRefreshing = false
    private var needsRefresh = false
    private var isInSpace = false

    init(clientProxy: ClientProxyProtocol, appSettings: AppSettings, echoTimeout: TimeInterval = 30) {
        self.clientProxy = clientProxy
        self.appSettings = appSettings
        self.echoTimeout = echoTimeout
    }

    /// Writes run one at a time; a write that a newer request supersedes before it starts is skipped.
    /// With `updatesDeviceCopyFirst` false, the device copy changes only once the account data write succeeds.
    @discardableResult
    func setEnabled(_ enabled: Bool, updatesDeviceCopyFirst: Bool = true) async -> Result<Void, ClientProxyError> {
        await requestWrite(enabled, updatesDeviceCopyFirst: updatesDeviceCopyFirst)
    }

    /// Copies the account's value to this device. An account already in a space with no stored value starts with Spaces on.
    func refresh(isInSpace: Bool) async {
        guard !isInvalidated else { return }
        self.isInSpace = isInSpace
        guard !isRefreshing else {
            needsRefresh = true
            return
        }

        isRefreshing = true
        repeat {
            needsRefresh = false
            await applyStoredValue()
        } while needsRefresh && !isInvalidated
        isRefreshing = false
    }

    /// Ends the session: later writes and refreshes, and those still running, no longer touch the device copy.
    func invalidate() {
        isInvalidated = true
        latestRequest += 1
        pendingValue = nil
        echoDeadline = nil
    }

    static func isEnabled(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(Content.self, from: data))?.enabled ?? false
    }

    // MARK: - Private

    private func requestWrite(_ enabled: Bool, updatesDeviceCopyFirst: Bool) async -> Result<Void, ClientProxyError> {
        guard !isInvalidated else { return .success(()) }

        if pendingValue == nil {
            fallbackValue = appSettings.spacesEnabled
        }
        pendingValue = enabled
        echoDeadline = nil
        latestRequest += 1
        if updatesDeviceCopyFirst {
            appSettings.spacesEnabled = enabled
        }

        let request = latestRequest
        let previousWrite = writeTask
        let task = Task { [weak self] () -> Result<Void, ClientProxyError> in
            _ = await previousWrite?.value
            guard let self else { return .success(()) }
            return await write(enabled, request: request, updatesDeviceCopy: !updatesDeviceCopyFirst)
        }
        writeTask = task

        let result = await task.value
        if writeTask == task {
            writeTask = nil
        }
        return result
    }

    private func write(_ enabled: Bool, request: Int, updatesDeviceCopy: Bool) async -> Result<Void, ClientProxyError> {
        guard request == latestRequest else { return .success(()) }

        let result = await clientProxy.setAccountData(type: Self.accountDataType, content: "{\"enabled\":\(enabled)}")
        guard !isInvalidated else { return result }
        if case .success = result {
            fallbackValue = enabled
            hasConfirmedWrite = true
        }
        guard request == latestRequest else { return result }

        switch result {
        case .success:
            echoDeadline = Date.now.addingTimeInterval(echoTimeout)
            if updatesDeviceCopy {
                appSettings.spacesEnabled = enabled
            }
        case .failure:
            pendingValue = nil
            if appSettings.spacesEnabled != fallbackValue {
                appSettings.spacesEnabled = fallbackValue
            }
        }
        return result
    }

    private func applyStoredValue() async {
        guard case let .success(content) = await clientProxy.accountData(type: Self.accountDataType), !isInvalidated else {
            return
        }
        let storedValue = content.map(Self.isEnabled)

        if let pendingValue {
            guard writeTask == nil, let echoDeadline else { return }
            guard storedValue == pendingValue || echoDeadline <= Date.now else { return }
            self.pendingValue = nil
            self.echoDeadline = nil
        }

        if let storedValue {
            appSettings.spacesEnabled = storedValue
        } else if hasConfirmedWrite {
            // The written value has not synced yet; the device copy already holds it.
            return
        } else if isInSpace {
            // The device copy changes only once the account holds the value, so repeated failures do not flap it.
            _ = await requestWrite(true, updatesDeviceCopyFirst: false)
        } else {
            appSettings.spacesEnabled = false
        }
    }
}
