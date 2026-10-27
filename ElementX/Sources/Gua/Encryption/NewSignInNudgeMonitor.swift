//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit

/// Delayed and repeating work for `NewSignInNudgeMonitor`, injectable so tests fire it by hand.
@MainActor
protocol NewSignInNudgeScheduling {
    func after(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable
    func every(_ interval: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable
}

struct TaskNewSignInNudgeScheduler: NewSignInNudgeScheduling {
    func after(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            work()
        }
        return AnyCancellable { task.cancel() }
    }

    func every(_ interval: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                work()
            }
        }
        return AnyCancellable { task.cancel() }
    }
}

/// Nudges sent and verification requests received, per account and device. Process-wide because
/// the nudge limit counts from app launch, not from session start.
@MainActor
final class NewSignInNudgeHistory {
    static let shared = NewSignInNudgeHistory()

    private struct Key: Hashable {
        let userID: String
        let deviceID: String
    }

    private var nudges: [Key: [Date]] = [:]
    private var incomingRequests: [Key: Date] = [:]

    func recordNudge(userID: String, deviceID: String, at date: Date) {
        nudges[Key(userID: userID, deviceID: deviceID), default: []].append(date)
    }

    func nudges(userID: String, deviceID: String) -> [Date] {
        nudges[Key(userID: userID, deviceID: deviceID)] ?? []
    }

    func recordIncomingRequest(userID: String, deviceID: String, at date: Date) {
        incomingRequests[Key(userID: userID, deviceID: deviceID)] = date
    }

    func lastIncomingRequest(userID: String, deviceID: String) -> Date? {
        incomingRequests[Key(userID: userID, deviceID: deviceID)]
    }
}

/// Asks a new, unverified sign-in of this account to send its verification request again. The SDK
/// drops a request that arrives with the new device's key change, and it only sends requests to
/// devices that are already cross-signed, so the phone cannot start the verification itself.
@MainActor
final class NewSignInNudgeMonitor {
    @MainActor
    struct Environment {
        var urlSession: URLSession = .shared
        var notificationCenter: NotificationCenter = .default
        var scheduler: NewSignInNudgeScheduling = TaskNewSignInNudgeScheduler()
        var now: () -> Date = { Date() }
        var history: NewSignInNudgeHistory = .shared
    }

    /// Gives the SDK one sync to download keys for changed device lists before a round reads them.
    static let settleDelay: Duration = .seconds(5)
    static let roundInterval: Duration = .seconds(60)
    static let recentSignInWindow: TimeInterval = 10 * 60
    static let nudgeCooldown: TimeInterval = 120
    static let maxNudgesPerDevice = 3
    static let recentRequestWindow: TimeInterval = 10 * 60

    private let clientProxy: ClientProxyProtocol
    private let appSettings: AppSettings
    private let client: OwnDevicesClient
    private let environment: Environment
    private let isAppActive: () -> Bool
    private let isIdle: () -> Bool

    private var cancellables = Set<AnyCancellable>()
    private var settledRound: AnyCancellable?
    private var repeatingRounds: AnyCancellable?
    private var hasSeenVerified = false
    private var roundsStarted = 0

    /// The round in flight, if any.
    private(set) var currentRound: Task<Void, Never>?

    /// - Parameters:
    ///   - isAppActive: whether the app is in the foreground and active.
    ///   - isIdle: whether nothing modal is presented and no flow is running, so the request the
    ///     nudge provokes can be shown straight away.
    init(clientProxy: ClientProxyProtocol,
         appSettings: AppSettings,
         environment: Environment? = nil,
         isAppActive: @escaping () -> Bool,
         isIdle: @escaping () -> Bool) {
        let environment = environment ?? Environment()
        self.clientProxy = clientProxy
        self.appSettings = appSettings
        self.environment = environment
        self.isAppActive = isAppActive
        self.isIdle = isIdle
        client = OwnDevicesClient(session: environment.urlSession)
    }

    func start() {
        guard cancellables.isEmpty else { return }

        clientProxy.verificationStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.verificationStateChanged(state)
            }
            .store(in: &cancellables)

        environment.notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.scheduleSettledRound()
                self?.startRepeatingRounds()
            }
            .store(in: &cancellables)

        environment.notificationCenter.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.cancelRounds()
            }
            .store(in: &cancellables)

        if isAppActive() {
            startRepeatingRounds()
        }
    }

    func stop() {
        cancellables.removeAll()
        cancelRounds()
    }

    /// A verification request arrived from one of this account's devices.
    func recordVerificationRequest(fromDeviceID deviceID: String) {
        environment.history.recordIncomingRequest(userID: clientProxy.userID, deviceID: deviceID, at: environment.now())
    }

    /// The user ignored a verification request from one of this account's devices.
    func recordDismissal(ofDeviceID deviceID: String) {
        appSettings.addDismissedSignInDeviceID(deviceID, forUserID: clientProxy.userID)
    }

    // MARK: - Scheduling

    private func verificationStateChanged(_ state: SessionVerificationState) {
        guard state == .verified, !hasSeenVerified else { return }
        hasSeenVerified = true
        scheduleSettledRound()
    }

    private func scheduleSettledRound() {
        settledRound = environment.scheduler.after(Self.settleDelay) { [weak self] in
            self?.startRound()
        }
    }

    private func startRepeatingRounds() {
        repeatingRounds = environment.scheduler.every(Self.roundInterval) { [weak self] in
            self?.startRound()
        }
    }

    private func cancelRounds() {
        settledRound?.cancel()
        settledRound = nil
        repeatingRounds?.cancel()
        repeatingRounds = nil
        currentRound?.cancel()
        currentRound = nil
    }

    private func startRound() {
        guard currentRound == nil else { return }
        roundsStarted += 1
        let round = roundsStarted
        currentRound = Task { [weak self] in
            await self?.runRound()
            if let self, roundsStarted == round {
                currentRound = nil
            }
        }
    }

    // MARK: - Round

    private func runRound() async {
        guard mayRunRound(), await recoveryLetsThisDeviceSign(), !Task.isCancelled, mayRunRound() else { return }

        let userID = clientProxy.userID
        let homeserver = clientProxy.homeserver
        guard let ownDeviceID = clientProxy.deviceID else { return }

        let devices: [OwnDevice]
        let keys: OwnDeviceKeys
        do {
            guard let accessToken = clientProxy.accessToken else { return }
            devices = try await client.devices(homeserver: homeserver, accessToken: accessToken)
            guard !Task.isCancelled, let accessToken = clientProxy.accessToken else { return }
            keys = try await client.deviceKeys(homeserver: homeserver, accessToken: accessToken, userID: userID)
        } catch {
            MXLog.warning("Skipping the new sign-in check, could not read this account's devices: \(error)")
            return
        }

        guard let target = candidate(devices: devices, keys: keys, userID: userID, ownDeviceID: ownDeviceID) else { return }
        guard !Task.isCancelled, mayRunRound(), let accessToken = clientProxy.accessToken else { return }

        environment.history.recordNudge(userID: userID, deviceID: target.deviceID, at: environment.now())
        MXLog.info("Asking device \(target.deviceID) to send its verification request to \(ownDeviceID) again.")
        do {
            try await client.sendVerificationRetryRequest(homeserver: homeserver,
                                                          accessToken: accessToken,
                                                          userID: userID,
                                                          targetDeviceID: target.deviceID,
                                                          fromDeviceID: ownDeviceID,
                                                          transactionID: "gua-\(UUID().uuidString)")
        } catch {
            MXLog.warning("Could not ask device \(target.deviceID) to send its verification request again: \(error)")
        }
    }

    private func mayRunRound() -> Bool {
        let userID = clientProxy.userID
        let identityResetRunning = IdentityResetPendingStore.isPending(for: userID)
            || IdentityResetMarker.isFresh(startedAt: appSettings.identityResetStartedAt(forUserID: userID), now: environment.now())
        return isAppActive()
            && isIdle()
            && clientProxy.verificationStatePublisher.value == .verified
            && !identityResetRunning
    }

    /// Only a device holding the private cross-signing keys can sign the new one. The published
    /// recovery state is optimistic while recovery is being enabled, so the SDK's own must agree.
    private func recoveryLetsThisDeviceSign() async -> Bool {
        let secureBackupController = clientProxy.secureBackupController
        guard await secureBackupController.settledRecoveryState() == .enabled else { return false }
        return secureBackupController.sdkRecoveryState() == .enabled
    }

    private func candidate(devices: [OwnDevice], keys: OwnDeviceKeys, userID: String, ownDeviceID: String) -> OwnDevice? {
        guard !keys.selfSigningKeyIDs.isEmpty else { return nil }

        let now = environment.now()
        let dismissed = appSettings.dismissedSignInDeviceIDs(forUserID: userID)

        let candidates = devices.filter { device in
            guard device.deviceID != ownDeviceID,
                  let deviceKeys = keys.devices[device.deviceID],
                  !deviceKeys.isDehydrated,
                  deviceKeys.ownerSignatureKeyIDs.isDisjoint(with: keys.selfSigningKeyIDs),
                  let lastSeen = device.lastSeen,
                  now.timeIntervalSince(lastSeen) <= Self.recentSignInWindow,
                  !dismissed.contains(device.deviceID) else {
                return false
            }

            let nudges = environment.history.nudges(userID: userID, deviceID: device.deviceID)
            if nudges.count >= Self.maxNudgesPerDevice {
                return false
            }
            if let lastNudge = nudges.last, now.timeIntervalSince(lastNudge) < Self.nudgeCooldown {
                return false
            }
            if let lastRequest = environment.history.lastIncomingRequest(userID: userID, deviceID: device.deviceID),
               now.timeIntervalSince(lastRequest) < Self.recentRequestWindow {
                return false
            }
            return true
        }

        return candidates.max { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }
}
