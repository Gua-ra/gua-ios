// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal nonisolated enum UntranslatedL10n {
  /// Find friends
  internal static var commonFindFriends: String { return UntranslatedL10n.tr("Untranslated", "common_find_friends") }
  /// See which of your contacts are on Gua
  internal static var commonFindFriendsDescription: String { return UntranslatedL10n.tr("Untranslated", "common_find_friends_description") }
  /// Search
  internal static var screenHomeTabSearch: String { return UntranslatedL10n.tr("Untranslated", "screen_home_tab_search") }
  /// Change phone number
  internal static var screenOtpChangePhone: String { return UntranslatedL10n.tr("Untranslated", "screen_otp_change_phone") }
  /// Enter the 6-digit code we just sent you.
  internal static var screenOtpFooterEnter: String { return UntranslatedL10n.tr("Untranslated", "screen_otp_footer_enter") }
  /// Resend code
  internal static var screenOtpResend: String { return UntranslatedL10n.tr("Untranslated", "screen_otp_resend") }
  /// Resend in %1$ds
  internal static func screenOtpResendCountdown(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_otp_resend_countdown", p1)
  }
  /// Verification code sent to %@
  internal static func screenOtpSentTo(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_otp_sent_to", String(describing: p1))
  }
  /// Verify your number
  internal static var screenOtpVerifyNumberTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_otp_verify_number_title") }
  /// We'll text a verification code to this number.
  internal static var screenPhoneLoginFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_phone_login_footer") }
  /// Enter a valid phone number including the country code.
  internal static var screenPhoneLoginInvalidNumber: String { return UntranslatedL10n.tr("Untranslated", "screen_phone_login_invalid_number") }
  /// Sign in with another method
  internal static var screenPhoneLoginLegacy: String { return UntranslatedL10n.tr("Untranslated", "screen_phone_login_legacy") }
  /// Enter your phone number
  internal static var screenPhoneLoginTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_phone_login_title") }
  /// Welcome to Gua
  internal static var screenPhoneLoginWelcome: String { return UntranslatedL10n.tr("Untranslated", "screen_phone_login_welcome") }
  /// Enter the 6-digit PIN you set up for %@.
  internal static func screenPinChallengeFooter(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_pin_challenge_footer", String(describing: p1))
  }
  /// Forgot PIN?
  internal static var screenPinChallengeForgot: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_challenge_forgot") }
  /// Two-step verification
  internal static var screenPinChallengeHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_challenge_header") }
  /// Enter your PIN
  internal static var screenPinChallengeTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_challenge_title") }
  /// Re-enter your PIN to confirm.
  internal static var screenPinSetupConfirmFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_confirm_footer") }
  /// Confirm your PIN
  internal static var screenPinSetupConfirmHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_confirm_header") }
  /// Pick a 6-digit PIN. You'll be asked for it when signing in on a new device, protecting your account if your SIM is swapped or your number is reassigned.
  internal static var screenPinSetupCreateFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_create_footer") }
  /// Add an extra layer of security
  internal static var screenPinSetupCreateHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_create_header") }
  /// PINs don't match. Try again.
  internal static var screenPinSetupMismatchError: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_mismatch_error") }
  /// Not now
  internal static var screenPinSetupSkip: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_skip") }
  /// You can set this up later in Settings → Account → Two-step verification.
  internal static var screenPinSetupSkipFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_skip_footer") }
  /// Two-step verification
  internal static var screenPinSetupTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_title") }
  /// Choose a less predictable PIN (avoid 000000, 123456, etc.).
  internal static var screenPinSetupWeakError: String { return UntranslatedL10n.tr("Untranslated", "screen_pin_setup_weak_error") }
  /// How should others see you?
  internal static var screenProfileSetupDisplayNameHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_display_name_header") }
  /// Your Name
  internal static var screenProfileSetupDisplayNamePlaceholder: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_display_name_placeholder") }
  /// Set up your profile
  internal static var screenProfileSetupTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_title") }
  /// Available
  internal static var screenProfileSetupUsernameAvailable: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_available") }
  /// Checking availability…
  internal static var screenProfileSetupUsernameChecking: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_checking") }
  /// Choose your @username
  internal static var screenProfileSetupUsernameHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_header") }
  /// 3-30 characters: lowercase letters, digits, dot, underscore, or dash.
  internal static var screenProfileSetupUsernameHint: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_hint") }
  /// Username isn't allowed.
  internal static var screenProfileSetupUsernameInvalid: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_invalid") }
  /// Your @username is permanent and can't be changed later. Choose wisely.
  internal static var screenProfileSetupUsernamePermanent: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_permanent") }
  /// your_username
  internal static var screenProfileSetupUsernamePlaceholder: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_placeholder") }
  /// Already taken. Pick another.
  internal static var screenProfileSetupUsernameTaken: String { return UntranslatedL10n.tr("Untranslated", "screen_profile_setup_username_taken") }
  /// Contact info
  internal static var screenRoomDetailsContactInfoTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_room_details_contact_info_title") }
  /// Search for rooms
  internal static var screenSearchEmptyStateMessage: String { return UntranslatedL10n.tr("Untranslated", "screen_search_empty_state_message") }
  /// Start searching...
  internal static var screenSearchEmptyStateTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_search_empty_state_title") }
  /// There are no results for “%1$@.” Try a new search term.
  internal static func screenSearchNoResultsMessage(_ p1: Any) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_search_no_results_message", String(describing: p1))
  }
  /// Change PIN
  internal static var screenTwoStepVerificationChangeButton: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_change_button") }
  /// Re-enter your new PIN to confirm.
  internal static var screenTwoStepVerificationConfirmFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_confirm_footer") }
  /// Confirm your new PIN
  internal static var screenTwoStepVerificationConfirmHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_confirm_header") }
  /// Confirm your current PIN to authorize the change.
  internal static var screenTwoStepVerificationCurrentFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_current_footer") }
  /// Enter your current PIN
  internal static var screenTwoStepVerificationCurrentHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_current_header") }
  /// Current PIN is incorrect.
  internal static var screenTwoStepVerificationCurrentIncorrect: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_current_incorrect") }
  /// Too many incorrect attempts. Please try again later.
  internal static var screenTwoStepVerificationLocked: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_locked") }
  /// Pick a 6-digit PIN that's hard to guess.
  internal static var screenTwoStepVerificationNewFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_new_footer") }
  /// Choose a new PIN
  internal static var screenTwoStepVerificationNewHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_new_header") }
  /// Enter the 6-digit code we just sent to your phone.
  internal static var screenTwoStepVerificationOtpFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_otp_footer") }
  /// Enter the SMS code
  internal static var screenTwoStepVerificationOtpHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_otp_header") }
  /// That code is invalid or has expired. Please try again.
  internal static var screenTwoStepVerificationOtpInvalid: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_otp_invalid") }
  /// Add a 6-digit PIN to protect your account against SIM swap attacks. You'll be asked for it when signing in on a new device.
  internal static var screenTwoStepVerificationOverviewFooterOff: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_overview_footer_off") }
  /// Your PIN is required when signing in on a new device. Keep it secret — anyone with your PIN and SMS code can access your account.
  internal static var screenTwoStepVerificationOverviewFooterOn: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_overview_footer_on") }
  /// Status
  internal static var screenTwoStepVerificationOverviewHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_overview_header") }
  /// We'll send a verification code by SMS to the phone linked to your account.
  internal static var screenTwoStepVerificationPhoneFooter: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_phone_footer") }
  /// Confirm your phone number
  internal static var screenTwoStepVerificationPhoneHeader: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_phone_header") }
  /// Set up PIN
  internal static var screenTwoStepVerificationReminderAction: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_reminder_action") }
  /// Set up a 6-digit PIN so your account stays safe even if someone takes over your phone number.
  internal static var screenTwoStepVerificationReminderMessage: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_reminder_message") }
  /// Protect your account
  internal static var screenTwoStepVerificationReminderTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_reminder_title") }
  /// New PIN must differ from the current one.
  internal static var screenTwoStepVerificationSameAsCurrent: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_same_as_current") }
  /// Set up PIN
  internal static var screenTwoStepVerificationSetButton: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_set_button") }
  /// No PIN set
  internal static var screenTwoStepVerificationStatusOff: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_status_off") }
  /// PIN is enabled
  internal static var screenTwoStepVerificationStatusOn: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_status_on") }
  /// Two-step verification
  internal static var screenTwoStepVerificationTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_title") }
  /// PIN updated
  internal static var screenTwoStepVerificationUpdated: String { return UntranslatedL10n.tr("Untranslated", "screen_two_step_verification_updated") }
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

nonisolated extension UntranslatedL10n {
  static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
    // No need to check languages, we always default to en for untranslated strings
    guard let bundle = Bundle.lprojBundle(for: "en") else { return key }
    let format = NSLocalizedString(key, tableName: table, bundle: bundle, comment: "")
    return String(format: format, locale: Locale(identifier: "en"), arguments: args)
  }
}

// swiftlint:enable all
