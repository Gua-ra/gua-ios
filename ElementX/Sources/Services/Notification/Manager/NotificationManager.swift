//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit
import UserNotifications

final class NotificationManager: NSObject, NotificationManagerProtocol {
    private let notificationCenter: UserNotificationCenterProtocol
    private let appSettings: AppSettings
    
    private var userSession: UserSessionProtocol?
    
    private var cancellables = Set<AnyCancellable>()
    private var notificationsEnabled = false
    
    init(notificationCenter: UserNotificationCenterProtocol,
         appSettings: AppSettings) {
        self.notificationCenter = notificationCenter
        self.appSettings = appSettings
        super.init()
    }

    // MARK: NotificationManagerProtocol

    weak var delegate: NotificationManagerDelegate?
    
    func start() {
        let replyAction = UNTextInputNotificationAction(identifier: NotificationConstants.Action.inlineReply,
                                                        title: L10n.actionQuickReply,
                                                        options: [])
        let messageCategory = UNNotificationCategory(identifier: NotificationConstants.Category.message,
                                                     actions: [replyAction],
                                                     intentIdentifiers: [],
                                                     options: [])
        
        let inviteCategory = UNNotificationCategory(identifier: NotificationConstants.Category.invite,
                                                    actions: [],
                                                    intentIdentifiers: [],
                                                    options: [])
        notificationCenter.setNotificationCategories([messageCategory, inviteCategory])
        notificationCenter.delegate = self
        
        notificationsEnabled = appSettings.enableNotifications
        MXLog.info("App setting 'enableNotifications' is '\(notificationsEnabled)'")
        
        // Listen for changes to AppSettings.enableNotifications
        appSettings.$enableNotifications
            .sink { [weak self] newValue in
                self?.enableNotifications(newValue)
            }
            .store(in: &cancellables)
    }
        
    func requestAuthorization() {
        guard appSettings.enableNotifications, !userSession.isNil else { return }
        Task {
            do {
                let permissionGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                MXLog.info("Permission granted: \(permissionGranted)")
                await MainActor.run {
                    if permissionGranted {
                        self.delegate?.registerForRemoteNotifications()
                    }
                }
            } catch {
                MXLog.error("Request authorization failed: \(error)")
            }
        }
    }

    func register(with deviceToken: Data) async -> Bool {
        guard let userSession else {
            return false
        }
        // GUA FORK: the security-notification channel of ADM-009 gate 2 needs this same token for its own
        // destination, and it needs it when the account holder asks for alerts rather than when this
        // callback fires. Behind the feature flag, so a build with it down behaves exactly as before:
        // nothing is stored and nothing reads the store.
        if appSettings.guaAccountAuthorityEnabled {
            await MainActor.run { AuthorityPushTokenStore.shared.store(deviceToken: deviceToken) }
        }
        return await setPusher(with: deviceToken, clientProxy: userSession.clientProxy)
    }

    func setUserSession(_ userSession: UserSessionProtocol?) {
        self.userSession = userSession
        
        // If notification permissions were given previously then attempt re-registering
        // for remote notifications on startup. Otherwise let the onboarding flow handle it
        Task { [weak self] in
            guard let self else { return }
            
            if await notificationCenter.authorizationStatus() == .authorized, appSettings.enableNotifications {
                await MainActor.run { [weak self] in
                    self?.delegate?.registerForRemoteNotifications()
                }
            }
            
            let settings = await notificationCenter.notificationSettings()
            MXLog.info("Notification sound enabled: \(settings.soundSetting == .enabled)")
        }
    }

    func registrationFailed(with error: Error) {
        MXLog.error("Device token registration failed with error: \(error)")
    }

    func showLocalNotification(with title: String, subtitle: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        let request = UNNotificationRequest(identifier: ProcessInfo.processInfo.globallyUniqueString,
                                            content: content,
                                            trigger: nil)
        do {
            try await notificationCenter.add(request)
            MXLog.info("Show local notification succeeded")
        } catch {
            MXLog.error("Show local notification failed: \(error)")
        }
    }
    
    func removeDeliveredMessageNotifications(for roomID: String) async {
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { $0.request.content.roomID == roomID }
            .map(\.request.identifier)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }
    
    func removeDeliveredNotificationsForFullyReadRooms(_ rooms: [RoomSummary]) async {
        let roomsToLastMessageDates = rooms
            .filter { $0.hasUnreadMessages == false }
            .reduce(into: [:]) { partialResult, roomSummary in
                partialResult[roomSummary.id] = roomSummary.lastMessageDate
            }
        
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { notification in
                guard let roomID = notification.request.content.roomID,
                      let lastMessageDate = roomsToLastMessageDates[roomID] else {
                    return false
                }
                    
                return notification.date <= lastMessageDate
            }
            .map(\.request.identifier)
        
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }

    private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        do {
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "Notification",
                                                                          locArgs: [])),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: deviceToken.base64EncodedString(),
                                                                                 appId: appSettings.pusherAppID),
                                                              kind: .http(data: .init(url: appSettings.pushGatewayNotifyEndpoint.absoluteString,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: pusherProfileTag(),
                                                              lang: Bundle.app.preferredLocalizations.first ?? "en")
            try await clientProxy.setPusher(with: configuration)
            MXLog.info("Set pusher succeeded")
            return true
        } catch {
            MXLog.error("Set pusher failed: \(error)")
            return false
        }
    }

    private func pusherProfileTag() -> String {
        if let currentTag = appSettings.pusherProfileTag {
            return currentTag
        }
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let newTag = (0..<16).map { _ in
            let offset = Int.random(in: 0..<chars.count)
            return String(chars[chars.index(chars.startIndex, offsetBy: offset)])
        }.joined()

        appSettings.pusherProfileTag = newTag
        return newTag
    }
    
    private func enableNotifications(_ enable: Bool) {
        guard notificationsEnabled != enable else { return }
        notificationsEnabled = enable
        MXLog.info("App setting 'enableNotifications' changed to '\(enable)'")
        if enable {
            requestAuthorization()
        } else {
            delegate?.unregisterForRemoteNotifications()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // GUA FORK: an account-authority security alert is presented even when in-app notifications are
        // switched off. Exactly one gate below would ever have dropped it, `enableInAppNotifications`, which
        // is a preference about chats and not about the one alert ADM-009 gate 2 exists to deliver, in the
        // case the owner is most able to act on it, which is while they are looking at the screen. The room
        // check is not load-bearing here and never was: `shouldDisplayInAppNotification` returns true for
        // content that carries no room id (AppCoordinator), so an alert with no room already passed it.
        //
        // The value has to be exactly the "1" identity-service sends
        // (AuthorityPushTransport.ALERT_MARKER), which screens an accidental or stale marker rather
        // than a hostile one: nothing here authenticates it, and a gateway that wanted to force a
        // banner would simply send "1". What that gateway is, is the account's own push path, and
        // the worst it buys is an unwanted banner, not a way past any decision about the account.
        //
        // Deliberately NOT behind guaAccountAuthorityEnabled, although an earlier revision of this
        // put it there. That flag is a local preference the server cannot observe, it defaults to
        // off, and gating on it re-creates the defect this whole branch exists to fix one layer up:
        // a device enrolled from another platform, or one where the flag was turned off after
        // enrolment, is still a registered destination, and the server still sends. With the gate
        // in place such a device drops a real alert to [] in the foreground, withholding even .list,
        // so it is not recoverable from Notification Center afterwards. A rollout switch has no
        // business deciding whether a warning the account holder was sent is shown to them.
        if notification.request.content.userInfo[NotificationConstants.UserInfoKey.guaAuthorityAlert] as? String == "1" {
            return [.badge, .sound, .list, .banner]
        }
        guard appSettings.enableInAppNotifications else {
            return []
        }
        guard let delegate else {
            return [.badge, .sound, .list, .banner]
        }

        guard delegate.shouldDisplayInAppNotification(content: notification.request.content) else {
            return []
        }

        return [.badge, .sound, .list, .banner]
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case NotificationConstants.Action.inlineReply:
            guard let response = response as? UNTextInputNotificationResponse else {
                return
            }
            await delegate?.handleInlineReply(self,
                                              content: response.notification.request.content,
                                              replyText: response.userText)
        case UNNotificationDefaultActionIdentifier:
            await delegate?.notificationTapped(content: response.notification.request.content)
        default:
            break
        }
    }
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol { }
