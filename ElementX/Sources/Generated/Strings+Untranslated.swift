// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum UntranslatedL10n {
  /// Use my other device
  internal static var guaEncryptionRecoverFromOtherDeviceAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_action") }
  /// Couldn’t get your messages from the other device. Make sure it’s open and try again, or reset.
  internal static var guaEncryptionRecoverFromOtherDeviceFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_failed") }
  /// Your other device still has the keys for these messages. Verify it to copy them over. Resetting instead finishes setup right away, but messages stored only in the backup will be lost.
  internal static var guaEncryptionRecoverFromOtherDeviceMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_message") }
  /// Finish setup
  internal static var guaEncryptionRepairAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_action") }
  /// Setting up…
  internal static var guaEncryptionRepairActionInProgress: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_action_in_progress") }
  /// Complete setup to access encrypted chats and message history available on this device.
  internal static var guaEncryptionRepairMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_message") }
  /// Finish setting up this device
  internal static var guaEncryptionRepairTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_title") }
  /// Couldn’t finish setup. Tap Reset and finish setup to try again.
  internal static var guaEncryptionResetFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_failed") }
  /// Finishing setup…
  internal static var guaEncryptionResetFinishing: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_finishing") }
  /// Setup wasn’t approved. Tap Reset and finish setup to try again.
  internal static var guaEncryptionResetNotApproved: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_not_approved") }
  /// Reset and finish setup
  internal static var guaEncryptionResetRequiredAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_action") }
  /// To finish setting up encrypted chats on this device, your encrypted backup needs to be reset. Messages stored only in that backup will be lost. Messages already on your devices won’t be affected.
  internal static var guaEncryptionResetRequiredMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_message") }
  /// Some previous messages can’t be recovered
  internal static var guaEncryptionResetRequiredTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_title") }
  /// %1$@’s security details changed. This can happen when they reinstall Gua or get a new phone. %2$@
  internal static func guaIdentityChangeBannerDescription(_ p1: Any, _ p2: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_identity_change_banner_description", String(describing: p1), String(describing: p2))
  }
  /// %1$@’s security details changed. This can happen when they reinstall Gua or get a new phone.
  internal static func guaIdentityChangeProfile(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_identity_change_profile", String(describing: p1))
  }
  /// This message can’t be opened because the sender’s security details changed.
  internal static var guaIdentityChangeUndecryptable: String { return UntranslatedL10n.tr("Untranslated", "gua_identity_change_undecryptable") }
  /// Paste the room address you were given.
  internal static var guaJoinRoomByAddressHint: String { return UntranslatedL10n.tr("Untranslated", "gua_join_room_by_address_hint") }
  /// Messages kept only here will not be available when you sign back in.
  internal static var guaSignoutLastDeviceMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_signout_last_device_message") }
  /// Signing out will remove your messages from this device
  internal static var guaSignoutLastDeviceTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_signout_last_device_title") }
  /// Make sure the emojis below match the ones on your other device.
  internal static var guaVerificationCompareEmojisSubtitle: String { return UntranslatedL10n.tr("Untranslated", "gua_verification_compare_emojis_subtitle") }
  /// Your messages will now show up on this device.
  internal static var guaVerificationCompleteSubtitle: String { return UntranslatedL10n.tr("Untranslated", "gua_verification_complete_subtitle") }
  /// Keep it open. You’ll compare a few emojis on both devices to confirm it’s you.
  internal static var guaVerificationOtherDeviceSubtitle: String { return UntranslatedL10n.tr("Untranslated", "gua_verification_other_device_subtitle") }
  /// Open Gua on your other device
  internal static var guaVerificationOtherDeviceTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_verification_other_device_title") }
  /// Waiting for your other device
  internal static var guaVerificationWaitingOtherDeviceTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_verification_waiting_other_device_title") }
  /// Clear all data currently stored on this device?
  /// Sign in again to access your account data and messages.
  internal static var softLogoutClearDataDialogContent: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_dialog_content") }
  /// Clear data
  internal static var softLogoutClearDataDialogTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_dialog_title") }
  /// Warning: Your personal data (including encryption keys) is still stored on this device.
  /// 
  /// Clear it if you’re finished using this device, or want to sign in to another account.
  internal static var softLogoutClearDataNotice: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_notice") }
  /// Clear all data
  internal static var softLogoutClearDataSubmit: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_submit") }
  /// Clear personal data
  internal static var softLogoutClearDataTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_title") }
  /// Sign in to recover encryption keys stored exclusively on this device. You need them to read all of your secure messages on any device.
  internal static var softLogoutSigninE2eWarningNotice: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_e2e_warning_notice") }
  /// Your homeserver (%1$s) admin has signed you out of your account %2$s (%3$s).
  internal static func softLogoutSigninNotice(_ p1: UnsafePointer<CChar>, _ p2: UnsafePointer<CChar>, _ p3: UnsafePointer<CChar>) -> String {
    return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_notice", p1, p2, p3)
  }
  /// Sign in
  internal static var softLogoutSigninTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_title") }
  /// Untranslated
  internal static var untranslated: String { return UntranslatedL10n.tr("Untranslated", "untranslated") }
  /// Plural format key: "%#@VARIABLE@"
  internal static func untranslatedPlural(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "untranslated_plural", p1)
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension UntranslatedL10n {
  static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
    // No need to check languages, we always default to en for untranslated strings
    guard let bundle = Bundle.lprojBundle(for: "en") else { return key }
    let format = NSLocalizedString(key, tableName: table, bundle: bundle, comment: "")
    return String(format: format, locale: Locale(identifier: "en"), arguments: args)
  }
}

// swiftlint:enable all
