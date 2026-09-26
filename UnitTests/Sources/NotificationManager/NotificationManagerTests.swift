//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import NotificationCenter
import XCTest

@MainActor
final class NotificationManagerTests: XCTestCase {
    var notificationManager: NotificationManager!
    private let clientProxy = ClientProxyMock(.init(userID: "@test:user.net"))
    private lazy var mockUserSession = UserSessionMock(.init(clientProxy: clientProxy))
    private var notificationCenter: UserNotificationCenterMock!
    private var authorizationStatusWasGranted = false
    private var shouldDisplayInAppNotificationReturnValue = false
    private var handleInlineReplyDelegateCalled = false
    private var notificationTappedDelegateCalled = false
    private var registerForRemoteNotificationsDelegateCalled: (() -> Void)?
    
    private var appSettings: AppSettings {
        ServiceLocator.shared.settings
    }

    override func setUp() {
        AppSettings.resetAllSettings()
        notificationCenter = UserNotificationCenterMock()
        notificationCenter.requestAuthorizationOptionsReturnValue = true
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationCenter.notificationSettingsClosure = { await UNUserNotificationCenter.current().notificationSettings() }
        
        notificationManager = NotificationManager(notificationCenter: notificationCenter, appSettings: appSettings)
        notificationManager.start()
        notificationManager.setUserSession(mockUserSession)
    }
    
    override func tearDown() {
        notificationCenter = nil
        notificationManager = nil
    }
    
    func test_whenRegistered_pusherIsCalled() async {
        _ = await notificationManager.register(with: Data())
        
        XCTAssertTrue(clientProxy.setPusherWithCalled)
    }
    
    func test_whenRegisteredSuccess_completionSuccessIsCalled() async {
        let success = await notificationManager.register(with: Data())
        XCTAssertTrue(success)
    }

    func test_whenRegisteredAndPusherThrowsError_completionFalseIsCalled() async {
        enum TestError: Error {
            case someError
        }
        
        clientProxy.setPusherWithThrowableError = TestError.someError
        let success = await notificationManager.register(with: Data())
        XCTAssertFalse(success)
    }

    func test_whenRegistered_pusherIsCalledWithCorrectValues() async throws {
        let pushkeyData = Data("1234".utf8)
        _ = await notificationManager.register(with: pushkeyData)
        
        guard let configuration = clientProxy.setPusherWithReceivedInvocations.first else {
            XCTFail("Invalid pusher configuration sent")
            return
        }
        
        XCTAssertEqual(configuration.identifiers.pushkey, pushkeyData.base64EncodedString())
        XCTAssertEqual(configuration.identifiers.appId, appSettings.pusherAppID)
        XCTAssertEqual(configuration.appDisplayName, "\(InfoPlistReader.main.bundleDisplayName) (iOS)")
        XCTAssertEqual(configuration.deviceDisplayName, UIDevice.current.name)
        XCTAssertNotNil(configuration.profileTag)
        XCTAssertEqual(configuration.lang, Bundle.app.preferredLocalizations.first)
        guard case let .http(data) = configuration.kind else {
            XCTFail("Http kind expected")
            return
        }
        XCTAssertEqual(data.url, appSettings.pushGatewayNotifyEndpoint.absoluteString)
        XCTAssertEqual(data.format, .eventIdOnly)
        let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                      alert: APSAlert(locKey: "Notification",
                                                                      locArgs: [])),
                                         pusherNotificationClientIdentifier: nil)
        XCTAssertEqual(data.defaultPayload, try defaultPayload.toJsonString())
    }

    func test_whenRegisteredAndPusherTagNotSetInSettings_tagGeneratedAndSavedInSettings() async {
        appSettings.pusherProfileTag = nil
        _ = await notificationManager.register(with: Data())
        XCTAssertNotNil(appSettings.pusherProfileTag)
    }

    func test_whenRegisteredAndPusherTagIsSetInSettings_tagNotGenerated() async {
        appSettings.pusherProfileTag = "12345"
        _ = await notificationManager.register(with: Data())
        XCTAssertEqual(appSettings.pusherProfileTag, "12345")
    }

    func test_whenShowLocalNotification_notificationRequestGetsAdded() async throws {
        await notificationManager.showLocalNotification(with: "Title", subtitle: "Subtitle")
        let request = try XCTUnwrap(notificationCenter.addReceivedRequest)
        XCTAssertEqual(request.content.title, "Title")
        XCTAssertEqual(request.content.subtitle, "Subtitle")
    }
    
    func test_whenStart_notificationCategoriesAreSet() {
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
        XCTAssertEqual(notificationCenter.setNotificationCategoriesReceivedCategories, [messageCategory, inviteCategory])
    }

    func test_whenStart_delegateIsSet() throws {
        let delegate = try XCTUnwrap(notificationCenter.delegate)
        XCTAssertTrue(delegate.isEqual(notificationManager))
    }

    func test_whenStart_requestAuthorizationCalledWithCorrectParams() async {
        let expectation = expectation(description: "requestAuthorization should be called")
        notificationCenter.requestAuthorizationOptionsClosure = { _ in
            expectation.fulfill()
            return true
        }
        notificationManager.requestAuthorization()
        await fulfillment(of: [expectation])
        XCTAssertEqual(notificationCenter.requestAuthorizationOptionsReceivedOptions, [.alert, .sound, .badge])
    }

    func test_whenStartAndAuthorizationGranted_delegateCalled() async {
        authorizationStatusWasGranted = false
        notificationManager.delegate = self
        let expectation: XCTestExpectation = expectation(description: "registerForRemoteNotifications delegate function should be called")
        expectation.assertForOverFulfill = false
        registerForRemoteNotificationsDelegateCalled = {
            expectation.fulfill()
        }
        notificationManager.requestAuthorization()
        await fulfillment(of: [expectation])
        XCTAssertTrue(authorizationStatusWasGranted)
    }
    
    func test_whenStartAndAuthorizedAndNotificationDisabled_registerForRemoteNotificationsNotCalled() async throws {
        appSettings.enableNotifications = false
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationManager.delegate = self
        
        notificationManager.setUserSession(UserSessionMock(.init()))
        try await Task.sleep(for: .seconds(1))
        
        XCTAssertFalse(authorizationStatusWasGranted)
    }
    
    func test_whenStartAndAuthorized_registerForRemoteNotificationsCalled() async {
        appSettings.enableNotifications = true
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationManager.delegate = self
        
        let expectation: XCTestExpectation = expectation(description: "registerForRemoteNotifications delegate function should be called")
        expectation.assertForOverFulfill = false
        registerForRemoteNotificationsDelegateCalled = {
            expectation.fulfill()
        }
        
        notificationManager.setUserSession(UserSessionMock(.init()))
        await fulfillment(of: [expectation])
        
        XCTAssertTrue(authorizationStatusWasGranted)
    }

    func test_whenWillPresentNotificationsDelegateNotSet_CorrectPresentationOptionsReturned() async throws {
        // GUA FORK: built with the same helper every other willPresent test uses, rather than through
        // MockCoder. That coder answers every decodeObject with "", so the notification it produces carries
        // an empty String where its UNNotificationRequest should be, and any code that reads
        // notification.request throws an unrecognized selector. Nothing in production can be handed such a
        // notification: the system always passes a real one. It only ever passed here because the first
        // statement in willPresent used to be a settings read, so it is a landmine for whatever is written
        // first rather than a fact about the code under test.
        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [.badge, .sound, .list, .banner])
    }

    func test_whenWillPresentNotificationsDelegateSetAndNotificationsShoudNotBeDisplayed_CorrectPresentationOptionsReturned() async throws {
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [])
    }

    func test_whenWillPresentNotificationsDelegateSetAndNotificationsShoudBeDisplayed_CorrectPresentationOptionsReturned() async throws {
        shouldDisplayInAppNotificationReturnValue = true
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [.badge, .sound, .list, .banner])
    }

    /// GUA FORK: an account-authority alert is presented with every gate hostile, because the chat
    /// preference is not a preference about a security alert.
    func test_whenWillPresentAuthorityAlertAndEveryGateHostile_CorrectPresentationOptionsReturned() async throws {
        appSettings.enableInAppNotifications = false
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [NotificationConstants.UserInfoKey.guaAuthorityAlert: "1"])
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [.badge, .sound, .list, .banner])
    }

    /// GUA FORK: the other half of the differential above. It is insensitive on its own, and would pass
    /// with the carve-out deleted; what it establishes is that the settings the test above defeats really
    /// do drop a notification, so the pair together say the marker is what made the difference.
    func test_whenWillPresentWithoutAuthorityAlertAndEveryGateHostile_CorrectPresentationOptionsReturned() async throws {
        appSettings.enableInAppNotifications = false
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [])
    }

    /// GUA FORK: the value has to be the one identity-service sends. This is what stops the exact-value
    /// check being reverted to a presence check without a test noticing; a marker carrying anything else is
    /// an accident or a stale build, and the chat preference still decides.
    func test_whenWillPresentAuthorityAlertWithAnotherMarkerValue_CorrectPresentationOptionsReturned() async throws {
        appSettings.enableInAppNotifications = false
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        for value in ["0", "", "true", "yes"] {
            let notification = try UNNotification.with(userInfo: [NotificationConstants.UserInfoKey.guaAuthorityAlert: value])
            let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
            XCTAssertEqual(options, [], "a marker of \(value) should not present")
        }
    }

    /// GUA FORK: and the alert is presented whatever the account-authority feature flag says. That flag is a
    /// local preference the server cannot observe: a device enrolled from another platform, or one where it
    /// was turned off after enrolment, is still a destination the server sends to, and a rollout switch has
    /// no business deciding whether a warning the account holder was sent is shown to them.
    func test_whenWillPresentAuthorityAlertAndFeatureFlagOff_alertIsStillPresented() async throws {
        appSettings.guaAccountAuthorityEnabled = false
        appSettings.enableInAppNotifications = false
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [NotificationConstants.UserInfoKey.guaAuthorityAlert: "1"])
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        XCTAssertEqual(options, [.badge, .sound, .list, .banner])
    }

    /// GUA FORK: a tap on an account-authority alert is forwarded like any other tap. `didReceive` switches
    /// on the action identifier alone and reads neither the marker nor any flag, so this is a regression
    /// guard on that staying true and nothing more: it does not exercise the carve-out above. What the tap
    /// then reaches is AppCoordinator, where a notification with no room id is a no-op today.
    func test_whenNotificationCenterReceivedResponseForAuthorityAlert_delegateIsCalled() async throws {
        notificationTappedDelegateCalled = false
        notificationManager.delegate = self
        let response = try UNTextInputNotificationResponse.with(userInfo: [NotificationConstants.UserInfoKey.guaAuthorityAlert: "1"],
                                                                actionIdentifier: UNNotificationDefaultActionIdentifier)
        await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), didReceive: response)
        XCTAssertTrue(notificationTappedDelegateCalled)
    }

    func test_whenNotificationCenterReceivedResponseInLineReply_delegateIsCalled() async throws {
        handleInlineReplyDelegateCalled = false
        notificationManager.delegate = self
        let response = try UNTextInputNotificationResponse.with(userInfo: [AnyHashable: Any](), actionIdentifier: NotificationConstants.Action.inlineReply)
        await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), didReceive: response)
        XCTAssertTrue(handleInlineReplyDelegateCalled)
    }

    func test_whenNotificationCenterReceivedResponseWithActionIdentifier_delegateIsCalled() async throws {
        notificationTappedDelegateCalled = false
        notificationManager.delegate = self
        let response = try UNTextInputNotificationResponse.with(userInfo: [AnyHashable: Any](), actionIdentifier: UNNotificationDefaultActionIdentifier)
        await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), didReceive: response)
        XCTAssertTrue(notificationTappedDelegateCalled)
    }
}

extension NotificationManagerTests: NotificationManagerDelegate {
    func registerForRemoteNotifications() {
        authorizationStatusWasGranted = true
        registerForRemoteNotificationsDelegateCalled?()
    }
    
    func unregisterForRemoteNotifications() {
        authorizationStatusWasGranted = false
    }
    
    func shouldDisplayInAppNotification(content: UNNotificationContent) -> Bool {
        shouldDisplayInAppNotificationReturnValue
    }
    
    func notificationTapped(content: UNNotificationContent) async {
        notificationTappedDelegateCalled = true
    }
    
    func handleInlineReply(_ service: ElementX.NotificationManagerProtocol, content: UNNotificationContent, replyText: String) async {
        handleInlineReplyDelegateCalled = true
    }
}
