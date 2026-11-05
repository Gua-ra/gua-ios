//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatrixRustSDK
import SwiftUI

/// Represents an issue with a timeline item's authenticity such as coming from an
/// unsigned session or being sent unencrypted in an encrypted room. See Rust's
/// `ShieldStateCode` for more information about the meaning of the cases.
nonisolated enum EncryptionAuthenticity: Hashable {
    enum Color { case red, gray }
    
    case notGuaranteed(color: Color)
    case unknownDevice(color: Color)
    case unsignedDevice(color: Color)
    case unverifiedIdentity(color: Color)
    case verificationViolation(color: Color)
    case sentInClear(color: Color)
    case mismatchedSender(color: Color)
    
    var message: String {
        switch self {
        case .notGuaranteed:
            L10n.cryptoEventAuthenticityNotGuaranteed
        case .unknownDevice:
            L10n.cryptoEventAuthenticityUnknownDevice
        case .unsignedDevice:
            L10n.cryptoEventAuthenticityUnsignedDevice
        case .unverifiedIdentity:
            L10n.cryptoEventAuthenticityUnverifiedIdentity
        case .verificationViolation:
            L10n.cryptoEventAuthenticityPreviouslyVerified
        case .sentInClear:
            L10n.cryptoEventAuthenticitySentInClear
        case .mismatchedSender:
            L10n.cryptoEventAuthenticityMismatchedSender
        }
    }
    
    var color: Color {
        switch self {
        case .notGuaranteed(let color),
             .unknownDevice(let color),
             .unsignedDevice(let color),
             .unverifiedIdentity(let color),
             .verificationViolation(let color),
             .sentInClear(let color),
             .mismatchedSender(let color):
            color
        }
    }
    
    var icon: KeyPath<CompoundIcons, Image> {
        switch self {
        // GUA FORK: only the two states that mean "this may not be who you think" keep the
        // solid alarm glyph. The rest describe how a message was encrypted, which is context,
        // not a warning, and the solid mark in the send-status slot reads as a delivery failure.
        case .verificationViolation, .mismatchedSender: \.helpSolid
        case .notGuaranteed, .unknownDevice, .unsignedDevice, .unverifiedIdentity: \.info
        case .sentInClear: \.lockOff
        }
    }
    
    /// GUA FORK: whether this state warrants alarm colour.
    ///
    /// Red in the send-status slot means "did not send" in every messenger, so it is reserved
    /// for the states where something is genuinely wrong with who sent the message. An
    /// unsigned or unknown device is a statement about setup, and is shown in neutral text.
    var isAlarming: Bool {
        switch self {
        case .verificationViolation, .mismatchedSender, .sentInClear: true
        case .notGuaranteed, .unknownDevice, .unsignedDevice, .unverifiedIdentity: false
        }
    }
    
    /// GUA FORK: states that describe the *sender's own* setup rather than a risk to the reader.
    ///
    /// On your own message these say nothing you can act on and nothing you did wrong, so they
    /// are suppressed entirely rather than decorating every message you send.
    var describesOwnSetup: Bool {
        switch self {
        case .unsignedDevice, .unknownDevice, .notGuaranteed: true
        case .unverifiedIdentity, .verificationViolation, .mismatchedSender, .sentInClear: false
        }
    }
}

nonisolated extension EncryptionAuthenticity {
    init?(shieldState: ShieldState) {
        switch shieldState {
        case .red(let code):
            self.init(shieldStateCode: code, color: .red)
        case .grey(let code):
            self.init(shieldStateCode: code, color: .gray)
        case .none:
            return nil
        }
    }
    
    init(shieldStateCode: TimelineEventShieldStateCode, color: EncryptionAuthenticity.Color) {
        switch shieldStateCode {
        case .authenticityNotGuaranteed:
            self = .notGuaranteed(color: color)
        case .unknownDevice:
            self = .unknownDevice(color: color)
        case .unsignedDevice:
            self = .unsignedDevice(color: color)
        case .unverifiedIdentity:
            self = .unverifiedIdentity(color: color)
        case .verificationViolation:
            self = .verificationViolation(color: color)
        case .sentInClear:
            self = .sentInClear(color: color)
        case .mismatchedSender:
            self = .mismatchedSender(color: color)
        }
    }
}
