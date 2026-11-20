//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@MainActor
class EncryptionResetUITests: XCTestCase {
    var app: XCUIApplication!
    
    @MainActor enum Step {
        static let resetScreen = 0
        static let passwordScreen = 1
        static let awaitingCode = 2
    }
    
    func testPasswordFlow() async throws {
        app = Application.launch(.encryptionReset)
        
        // Starting with the root screen.
        try await app.assertScreenshot(step: Step.resetScreen)
        
        app.buttons[A11yIdentifiers.encryptionResetScreen.continueReset].tap()
        
        try await Task.sleep(for: .seconds(2.0))
        
        try await app.assertScreenshot(step: Step.passwordScreen)
        
        // Gua confirms the account's phone number with a code instead of asking for its password.
        let phoneField = app.textFields[A11yIdentifiers.encryptionResetPasswordScreen.phoneField]
        phoneField.clearAndTypeText("+44 7700 900123", app: app)
        app.buttons[A11yIdentifiers.encryptionResetPasswordScreen.sendCode].tap()
        
        // Sending the code removes the number field, so wait for its keyboard to finish hiding.
        XCTAssertTrue(app.textFields[A11yIdentifiers.encryptionResetPasswordScreen.codeField].waitForExistence(timeout: 10))
        try await app.assertScreenshot(step: Step.awaitingCode, delay: .seconds(1))
    }
}
