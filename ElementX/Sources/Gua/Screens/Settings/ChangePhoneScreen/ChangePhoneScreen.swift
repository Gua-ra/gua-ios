//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChangePhoneScreen: View {
    @Bindable var context: ChangePhoneScreenViewModel.Context
    @FocusState private var isPhoneFieldFocused: Bool

    var body: some View {
        screenContent
            .navigationTitle(context.viewState.titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEnteringFlow {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.actionCancel) { context.send(viewAction: .cancel) }
                    }
                }
            }
            .interactiveDismissDisabled(isEnteringFlow)
            .sheet(isPresented: $context.isCountryPickerPresented) {
                CountryPickerScreen(selectedCountry: context.viewState.selectedCountry) { country in
                    context.send(viewAction: .countrySelected(country))
                }
            }
    }

    /// The message phases (intro/stepUpRequired/cooldown/done) render as polished centered cards on
    /// a plain background. The entry phases (reauth code/phone/PIN/OTP) keep the Compound
    /// list/`Form` styling.
    @ViewBuilder
    private var screenContent: some View {
        switch context.viewState.phase {
        case .intro:
            introSection
        case .stepUpRequired:
            stepUpRequiredSection
        case .cooldown:
            cooldownSection
        case .done:
            doneSection
        case .reauth, .newPhone, .pin, .otp, .submitting:
            Form {
                switch context.viewState.phase {
                case .newPhone:
                    phoneEntrySection
                default:
                    codeEntrySection
                }
            }
            .compoundList()
        }
    }

    private var isEnteringFlow: Bool {
        switch context.viewState.phase {
        case .reauth, .newPhone, .pin, .otp, .submitting:
            return true
        default:
            return false
        }
    }

    // MARK: - Intro

    private var introSection: some View {
        ChangePhoneMessageScreen(icon: \.userProfile,
                                 iconTint: .compound.iconPrimary,
                                 title: L10n.screenChangePhoneIntroHeader,
                                 message: L10n.screenChangePhoneIntroMessage,
                                 primary: ChangePhoneMessageButton(title: L10n.actionContinue) {
                                     context.send(viewAction: .start)
                                 })
    }

    // MARK: - Step-up required interstitial

    /// The hard block. It offers both ways to get a factor, strongest first, instead of the old
    /// single funnel into PIN setup: an account that wants a passkey should not have to create a
    /// PIN to be allowed to change its number.
    private var stepUpRequiredSection: some View {
        ChangePhoneMessageScreen(icon: \.lock,
                                 iconTint: .compound.iconPrimary,
                                 title: L10n.screenChangePhoneStepUpHeader,
                                 message: context.viewState.stepUpBlockMessage,
                                 primary: ChangePhoneMessageButton(title: L10n.screenChangePhoneStepUpPasskeyAction) {
                                     context.send(viewAction: .setUpStepUpFactor(.passkey))
                                 },
                                 secondary: ChangePhoneMessageButton(title: L10n.screenChangePhoneStepUpPinAction) {
                                     context.send(viewAction: .setUpStepUpFactor(.pin))
                                 })
    }

    // MARK: - Cooldown interstitial

    private var cooldownSection: some View {
        ChangePhoneMessageScreen(icon: \.time,
                                 iconTint: .compound.iconCriticalPrimary,
                                 title: L10n.screenChangePhoneCooldownHeader,
                                 message: context.viewState.cooldownMessage)
    }

    // MARK: - New phone entry

    @ViewBuilder
    private var phoneEntrySection: some View {
        Section {
            HStack(spacing: 8) {
                countryButton
                phoneField
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text(context.viewState.titleKey)
        } footer: {
            footerText
        }

        Section {
            ListRow(label: .centeredAction(title: L10n.actionContinue, icon: \.arrowRight),
                    kind: .button {
                        isPhoneFieldFocused = false
                        context.send(viewAction: .continueTapped)
                    })
                    .disabled(!context.viewState.canContinue)
        }
    }

    private var countryButton: some View {
        Button {
            isPhoneFieldFocused = false
            context.isCountryPickerPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(context.viewState.selectedCountry.flag)
                    .font(.title3)
                Text("+\(context.viewState.selectedCountry.dialCode)")
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textPrimary)
                CompoundIcon(\.chevronDown, size: .small, relativeTo: .compound.bodyLG)
                    .foregroundStyle(.compound.iconSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("Country code: \(context.viewState.selectedCountry.name) plus \(context.viewState.selectedCountry.dialCode)")
        .accessibilityHint("Opens country picker")
    }

    private var phoneField: some View {
        TextField(context.viewState.selectedCountry.nationalExample, text: $context.localPhoneNumber)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .font(.compound.bodyLG)
            .foregroundStyle(.compound.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 14))
            .focused($isPhoneFieldFocused)
            .submitLabel(.done)
            .onSubmit {
                if context.viewState.canContinue {
                    isPhoneFieldFocused = false
                    context.send(viewAction: .continueTapped)
                }
            }
            .onChange(of: context.localPhoneNumber) { _, _ in
                context.send(viewAction: .phoneChanged)
            }
            .onAppear { isPhoneFieldFocused = true }
    }

    // MARK: - Code entry (re-auth OTP / PIN / new-number OTP)

    @ViewBuilder
    private var codeEntrySection: some View {
        Section {
            PinBubbleField(pin: $context.code,
                           length: codeFieldLength,
                           hasError: context.viewState.errorMessage != nil)
                .onChange(of: context.code) {
                    context.send(viewAction: .codeChanged)
                }
                .id(context.viewState.phase)
        } header: {
            Text(context.viewState.titleKey)
        } footer: {
            footerText
        }

        Section {
            ListRow(label: .centeredAction(title: context.viewState.phase == .submitting ? L10n.commonLoading : L10n.actionContinue,
                                           icon: \.arrowRight),
                    kind: .button { context.send(viewAction: .continueTapped) })
                .disabled(!context.viewState.canContinue)
        }
    }

    private var codeFieldLength: Int {
        context.viewState.phase == .pin
            ? ChangePhoneScreenViewState.pinLength
            : ChangePhoneScreenViewState.otpLength
    }

    // MARK: - Done

    private var doneSection: some View {
        ChangePhoneMessageScreen(icon: \.checkCircle,
                                 iconTint: .compound.iconSuccessPrimary,
                                 title: L10n.screenChangePhoneDoneHeader,
                                 message: L10n.screenChangePhoneDoneMessage,
                                 primary: ChangePhoneMessageButton(title: L10n.actionDone) {
                                     context.send(viewAction: .done)
                                 })
    }

    // MARK: - Shared

    @ViewBuilder
    private var footerText: some View {
        if let errorMessage = context.viewState.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.compound.textCriticalPrimary)
        } else {
            Text(context.viewState.footerKey)
        }
    }
}

// MARK: - Message phase layout

/// A polished, centered "hero" message screen used by the intro / needs-PIN / cooldown / done phases.
/// Mirrors the Android `MessageCard`: a tinted card near the top holding an icon tile, a bold title and
/// a muted body, with an optional full-width primary CTA below the card (outside it).
/// One button on a message phase: its title and its handler travel together.
///
/// They are bundled rather than passed as a title plus a bare closure because the screen offers two
/// buttons. With two closure parameters an unlabelled trailing closure binds to the LAST of them,
/// so a call site that meant to pass the primary handler silently filled in the secondary one and
/// left `action` nil, and the primary button was then nil-guarded out of the layout entirely. One
/// closure per initialiser makes that misbinding impossible to write.
private struct ChangePhoneMessageButton {
    let title: String
    let action: () -> Void
}

private struct ChangePhoneMessageScreen: View {
    let icon: KeyPath<CompoundIcons, Image>
    let iconTint: Color
    let title: String
    let message: String
    let primary: ChangePhoneMessageButton?
    let secondary: ChangePhoneMessageButton?

    init(icon: KeyPath<CompoundIcons, Image>,
         iconTint: Color,
         title: String,
         message: String,
         primary: ChangePhoneMessageButton? = nil,
         secondary: ChangePhoneMessageButton? = nil) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        VStack(spacing: 16) {
            ChangePhoneMessageCard(icon: icon, iconTint: iconTint, title: title, message: message)
                .padding(.bottom, 8)

            if let primary {
                Button(primary.title, action: primary.action)
                    .buttonStyle(.compound(.primary))
            }

            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.compound(.secondary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
    }
}

/// The rounded `bgSubtleSecondary` card: an icon tile, a centered title and a centered body.
private struct ChangePhoneMessageCard: View {
    let icon: KeyPath<CompoundIcons, Image>
    let iconTint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            CompoundIcon(icon, size: .custom(28), relativeTo: .compound.headingMD)
                .foregroundStyle(iconTint)
                .frame(width: 64, height: 64)
                .background(.compound.bgSubtlePrimary, in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 8) {
                Text(title)
                    .font(.compound.headingMD)
                    .foregroundStyle(.compound.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Previews

struct ChangePhoneScreen_Previews: PreviewProvider {
    static func makeViewModel(phase: ChangePhoneScreenPhase,
                              cooldownRemainingSeconds: Int = 0) -> ChangePhoneScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        let userIndicatorController = UserIndicatorControllerMock()
        let identityServiceClient = IdentityServiceClient(baseURL: URL(string: "https://example.com")!)
        let viewModel = ChangePhoneScreenViewModel(clientProxy: clientProxy,
                                                   identityServiceClient: identityServiceClient,
                                                   userIndicatorController: userIndicatorController)
        viewModel.state.phase = phase
        viewModel.state.cooldownRemainingSeconds = cooldownRemainingSeconds
        return viewModel
    }

    static let introViewModel = makeViewModel(phase: .intro)
    static let stepUpRequiredViewModel = makeViewModel(phase: .stepUpRequired)
    static let cooldownViewModel = makeViewModel(phase: .cooldown, cooldownRemainingSeconds: 3 * 86400 + 4 * 3600)
    static let doneViewModel = makeViewModel(phase: .done)

    static var previews: some View {
        NavigationStack {
            ChangePhoneScreen(context: introViewModel.context)
        }
        .previewDisplayName("Intro")

        NavigationStack {
            ChangePhoneScreen(context: stepUpRequiredViewModel.context)
        }
        .previewDisplayName("Step-up required")

        NavigationStack {
            ChangePhoneScreen(context: cooldownViewModel.context)
        }
        .previewDisplayName("Cooldown")

        NavigationStack {
            ChangePhoneScreen(context: doneViewModel.context)
        }
        .previewDisplayName("Done")
    }
}
