//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

@MainActor
final class SpacesSetting {
    static let accountDataType = "global.gua.spaces"

    private struct Content: Decodable {
        let enabled: Bool
    }

    private let clientProxy: ClientProxyProtocol
    private let appSettings: AppSettings
    private let echoTimeout: TimeInterval

    private var pendingValue: Bool?
    private var fallbackValue = false
    private var echoDeadline: Date?
    private var latestRequest = 0
    private var writeTask: Task<Result<Void, ClientProxyError>, Never>?
    private var hasConfirmedWrite = false
    private var isInvalidated = false

    private var isRefreshing = false
    private var needsRefresh = false
    private var hasSynced = false

    init(clientProxy: ClientProxyProtocol, appSettings: AppSettings, echoTimeout: TimeInterval = 30) {
        self.clientProxy = clientProxy
        self.appSettings = appSettings
        self.echoTimeout = echoTimeout
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, updatesDeviceCopyFirst: Bool = true) async -> Result<Void, ClientProxyError> {
        await requestWrite(enabled, updatesDeviceCopyFirst: updatesDeviceCopyFirst)
    }

    func refresh(afterSync: Bool = false) async {
        guard !isInvalidated else { return }
        hasSynced = hasSynced || afterSync
        guard !isRefreshing else {
            needsRefresh = true
            return
        }

        isRefreshing = true
        repeat {
            needsRefresh = false
            // hasSynced is captured before the read, so a sync landing mid-read reruns it.
            await applyStoredValue(canDecideDefault: hasSynced)
        } while needsRefresh && !isInvalidated
        isRefreshing = false
    }

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

    private func applyStoredValue(canDecideDefault: Bool) async {
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
            // Nil here only means the confirmed write has not synced back yet.
            return
        } else if canDecideDefault {
            let joinedSpaces = await clientProxy.spaceService.topLevelJoinedSpaces()
            guard !isInvalidated, pendingValue == nil, !hasConfirmedWrite else { return }
            // Stored so a space joined later never turns Spaces on by itself.
            _ = await requestWrite(!joinedSpaces.isEmpty, updatesDeviceCopyFirst: false)
        }
    }
}
