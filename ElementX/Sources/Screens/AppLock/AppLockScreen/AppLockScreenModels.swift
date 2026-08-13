//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import LocalAuthentication
import SFSafeSymbols

enum AppLockScreenViewModelAction {
    /// The user has successfully unlocked the app.
    case appUnlocked
    /// The user failed to unlock the app (or forgot their PIN).
    case forceLogout
}

struct AppLockScreenViewState: BindableState {
    /// The number of attempts allowed to unlock the app.
    let maximumAttempts = 3

    /// The number of times the user attempted to enter their PIN.
    var numberOfPINAttempts = 0
    /// An overlay indicator shown when the user is being logged out.
    var forcedLogoutIndicator: UserIndicator?
    /// GUA FORK: the biometry the user can retry with, or `.none` when biometric unlock is off,
    /// untrusted or unavailable. Biometrics are attempted before this screen is ever shown, so
    /// this is the way back after cancelling that prompt rather than the first thing on offer.
    var retryableBiometryType: LABiometryType = .none

    var bindings: AppLockScreenViewStateBindings

    /// GUA FORK: whether to offer a second run at Face ID/Touch ID alongside the keypad.
    var canRetryBiometricUnlock: Bool {
        retryableBiometryType != .none
    }

    /// GUA FORK: the icon for the biometric retry button.
    var biometricUnlockIcon: SFSymbol {
        retryableBiometryType.systemSymbol
    }

    /// GUA FORK: the title of the biometric retry button, e.g. "Unlock with Face ID".
    var biometricUnlockTitle: String {
        L10n.screenAppLockUnlockWithBiometricsIos(retryableBiometryType.localizedString)
    }

    /// The number of digits the user has entered so far.
    var numberOfDigitsEntered: Int {
        bindings.pinCode.count
    }

    /// Whether the subtitle is in a warning state or not.
    var isSubtitleWarning: Bool {
        numberOfPINAttempts > 0
    }

    /// The string shown in the screen's subtitle.
    var subtitle: String {
        if !isSubtitleWarning {
            return L10n.screenAppLockSubtitle(maximumAttempts)
        } else {
            return L10n.screenAppLockSubtitleWrongPin(maximumAttempts - numberOfPINAttempts)
        }
    }
}

struct AppLockScreenViewStateBindings {
    /// The PIN code entered by the user.
    var pinCode = ""
    var alertInfo: AlertInfo<AppLockScreenAlertType>?
}

enum AppLockScreenAlertType {
    /// The user has failed too many times, they're being logged out.
    case forcedLogout
    /// The user has forgotten their PIN, confirm they're happy to sign out.
    case confirmResetPIN
}

enum AppLockScreenViewAction {
    /// Clears the PIN code after a failure animation.
    case clearPINCode
    /// The user didn't heed the warnings and can't remember their PIN.
    case forgotPIN
    /// GUA FORK: the user would rather unlock with Face ID/Touch ID than type their PIN.
    case unlockWithBiometrics
}
