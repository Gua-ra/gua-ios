// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum UntranslatedL10n {
  /// We couldn’t finish setting up your account on this device. Please try again.
  internal static var guaAccountGenesisSetupFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_account_genesis_setup_failed") }
  /// Contact info
  internal static var guaContactInfoTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_contact_info_title") }
  /// Opens country picker
  internal static var guaCountryCodeA11yHint: String { return UntranslatedL10n.tr("Untranslated", "gua_country_code_a11y_hint") }
  /// Country code: %1$@, plus %2$@
  internal static func guaCountryCodeA11yLabel(_ p1: Any, _ p2: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_country_code_a11y_label", String(describing: p1), String(describing: p2))
  }
  /// Search country or code
  internal static var guaCountryPickerSearchPrompt: String { return UntranslatedL10n.tr("Untranslated", "gua_country_picker_search_prompt") }
  /// Select country
  internal static var guaCountryPickerTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_country_picker_title") }
  /// Plural format key: "%#@COUNT@"
  internal static func guaDurationDays(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_duration_days", p1)
  }
  /// Plural format key: "%#@COUNT@"
  internal static func guaDurationHours(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_duration_hours", p1)
  }
  /// Plural format key: "%#@COUNT@"
  internal static func guaDurationMinutes(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_duration_minutes", p1)
  }
  /// Use my other device
  internal static var guaEncryptionRecoverFromOtherDeviceAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_action") }
  /// Couldn’t get your messages from the other device. Make sure it’s open and try again, or reset.
  internal static var guaEncryptionRecoverFromOtherDeviceFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_failed") }
  /// Use your other device to restore messages that aren’t available on this device yet.
  /// 
  /// If you don’t have access to it, you can reset and finish setup, but messages saved only in your backup will be permanently lost.
  internal static var guaEncryptionRecoverFromOtherDeviceMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_message") }
  /// Restore your previous messages
  internal static var guaEncryptionRecoverFromOtherDeviceTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_recover_from_other_device_title") }
  /// Finish setup
  internal static var guaEncryptionRepairAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_action") }
  /// Setting up…
  internal static var guaEncryptionRepairActionInProgress: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_action_in_progress") }
  /// Finish setup to see your encrypted chats and message history on this device.
  internal static var guaEncryptionRepairMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_message") }
  /// Finish setting up this device
  internal static var guaEncryptionRepairTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_repair_title") }
  /// Couldn’t finish setup. Please try again.
  internal static var guaEncryptionResetFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_failed") }
  /// Finishing setup…
  internal static var guaEncryptionResetFinishing: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_finishing") }
  /// Setup wasn’t approved. Please try again.
  internal static var guaEncryptionResetNotApproved: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_not_approved") }
  /// Reset and finish setup
  internal static var guaEncryptionResetRequiredAction: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_action") }
  /// To finish setting up encrypted chats on this device, your encrypted backup needs to be reset. Messages stored only in that backup will be lost. Messages already on your devices won’t be affected.
  internal static var guaEncryptionResetRequiredMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_message") }
  /// Some previous messages can’t be recovered
  internal static var guaEncryptionResetRequiredTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_required_title") }
  /// Still finishing setup in the background. You can keep using Gua.
  internal static var guaEncryptionResetStillFinishing: String { return UntranslatedL10n.tr("Untranslated", "gua_encryption_reset_still_finishing") }
  /// Too many attempts. Please wait a moment and try again.
  internal static var guaErrorRateLimited: String { return UntranslatedL10n.tr("Untranslated", "gua_error_rate_limited") }
  /// See which of your contacts are on Gua
  internal static var guaFindFriendsActionDescription: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_action_description") }
  /// Looking for your contacts on Gua…
  internal static var guaFindFriendsLoading: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_loading") }
  /// Open Settings
  internal static var guaFindFriendsOpenSettings: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_open_settings") }
  /// Gua checks your contacts privately to find which of them are already here. Your contacts are never stored.
  internal static var guaFindFriendsPermissionMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_permission_message") }
  /// Allow access to Contacts
  internal static var guaFindFriendsPermissionTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_permission_title") }
  /// Plural format key: "%#@COUNT@"
  internal static func guaFindFriendsResultsHeader(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_find_friends_results_header", p1)
  }
  /// Something went wrong starting a chat with %1$@. Please try again.
  internal static func guaFindFriendsStartChatFailedMessage(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_find_friends_start_chat_failed_message", String(describing: p1))
  }
  /// Couldn’t start the chat
  internal static var guaFindFriendsStartChatFailedTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_find_friends_start_chat_failed_title") }
  /// View %1$@’s profile
  internal static func guaFindFriendsViewProfileA11y(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_find_friends_view_profile_a11y", String(describing: p1))
  }
  /// This took too long. Please start again.
  internal static var guaFlowExpired: String { return UntranslatedL10n.tr("Untranslated", "gua_flow_expired") }
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
  /// Paste the address you were given.
  internal static var guaJoinRoomByAddressHint: String { return UntranslatedL10n.tr("Untranslated", "gua_join_room_by_address_hint") }
  /// Your passkey can’t be used for this right now.
  internal static var guaPasskeyUnavailable: String { return UntranslatedL10n.tr("Untranslated", "gua_passkey_unavailable") }
  /// That passkey didn’t confirm it was you. Please try again.
  internal static var guaPasskeyVerificationFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_passkey_verification_failed") }
  /// For security, you can change your PIN again in %1$@.
  internal static func guaPinChangeCooldownRetry(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_pin_change_cooldown_retry", String(describing: p1))
  }
  /// That PIN is incorrect. Please try again.
  internal static var guaPinIncorrect: String { return UntranslatedL10n.tr("Untranslated", "gua_pin_incorrect") }
  /// Too many wrong PIN attempts. Try again in %1$@.
  internal static func guaPinLockedRetry(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "gua_pin_locked_retry", String(describing: p1))
  }
  /// Your verification expired. Please request a new code.
  internal static var guaReauthExpired: String { return UntranslatedL10n.tr("Untranslated", "gua_reauth_expired") }
  /// We couldn’t confirm your account details. Please try again.
  internal static var guaResolverClaimsInvalid: String { return UntranslatedL10n.tr("Untranslated", "gua_resolver_claims_invalid") }
  /// We can’t set up new accounts right now. Please try again later.
  internal static var guaResolverRegistrationClosed: String { return UntranslatedL10n.tr("Untranslated", "gua_resolver_registration_closed") }
  /// We’re having trouble connecting right now. Please try again in a moment.
  internal static var guaResolverRoutingUnavailable: String { return UntranslatedL10n.tr("Untranslated", "gua_resolver_routing_unavailable") }
  /// We couldn’t sign you back in. Please sign in again.
  internal static var guaRestoreSigninFailed: String { return UntranslatedL10n.tr("Untranslated", "gua_restore_signin_failed") }
  /// Sign in with a passkey
  internal static var guaSignInWithPasskey: String { return UntranslatedL10n.tr("Untranslated", "gua_sign_in_with_passkey") }
  /// Messages kept only here will not be available when you sign back in.
  internal static var guaSignoutLastDeviceMessage: String { return UntranslatedL10n.tr("Untranslated", "gua_signout_last_device_message") }
  /// Signing out will remove your messages from this device
  internal static var guaSignoutLastDeviceTitle: String { return UntranslatedL10n.tr("Untranslated", "gua_signout_last_device_title") }
  /// You were signed out of your Gua account. Sign in again to continue.
  internal static var guaSoftLogoutSigninNotice: String { return UntranslatedL10n.tr("Untranslated", "gua_soft_logout_signin_notice") }
  /// You’ll need two-step verification before you can change your number.
  internal static var guaStepUpRequired: String { return UntranslatedL10n.tr("Untranslated", "gua_step_up_required") }
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
    // Gua keeps its own translations in this table, so resolve the app language exactly like L10n does.
    let languages = Bundle.overrideLocalizations ?? Bundle.app.preferredLocalizations

    for language in languages {
      if let translation = trIn(language, table, key, args) {
        return translation
      }
    }
    return Bundle.app.developmentLocalization.flatMap { trIn($0, table, key, args) } ?? key
  }

  private static func trIn(_ language: String, _ table: String, _ key: String, _ args: CVarArg...) -> String? {
    guard let bundle = Bundle.lprojBundle(for: language) else { return nil }
    let format = NSLocalizedString(key, tableName: table, bundle: bundle, comment: "")
    let translation = String(format: format, locale: Locale(identifier: language), arguments: args)
    guard translation != key,
          translation != "\(key) \(key)" // Handle double pseudo for tests
    else {
      return nil
    }
    return translation
  }
}

// swiftlint:enable all
