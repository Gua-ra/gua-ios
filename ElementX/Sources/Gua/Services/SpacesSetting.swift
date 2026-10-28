//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// The account-wide Spaces switch. It is stored in account data so it follows the account to every phone;
/// `AppSettings.spacesEnabled` is this device's copy, which the UI observes.
@MainActor
struct SpacesSetting {
    static let accountDataType = "global.gua.spaces"
    
    private struct Content: Decodable {
        let enabled: Bool
    }
    
    let clientProxy: ClientProxyProtocol
    let appSettings: AppSettings
    
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Result<Void, ClientProxyError> {
        let previous = appSettings.spacesEnabled
        appSettings.spacesEnabled = enabled
        
        let result = await clientProxy.setAccountData(type: Self.accountDataType, content: "{\"enabled\":\(enabled)}")
        if case .failure = result {
            appSettings.spacesEnabled = previous
        }
        return result
    }
    
    /// Copies the account's value to this device. An account already in a space with no stored value starts with Spaces on.
    func refresh(isInSpace: Bool) async {
        guard case let .success(content) = await clientProxy.accountData(type: Self.accountDataType) else {
            return
        }
        
        if let content {
            appSettings.spacesEnabled = Self.isEnabled(content)
        } else if isInSpace {
            await setEnabled(true)
        } else {
            appSettings.spacesEnabled = false
        }
    }
    
    static func isEnabled(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(Content.self, from: data))?.enabled ?? false
    }
}
