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
        Form {
            switch context.viewState.phase {
            case .intro:
                introSection
            case .newPhone:
                phoneEntrySection
            case .pin, .otp, .submitting:
                codeEntrySection
            case .done:
                doneSection
            }
        }
        .compoundList()
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

    private var isEnteringFlow: Bool {
        switch context.viewState.phase {
        case .newPhone, .pin, .otp, .submitting:
            return true
        default:
            return false
        }
    }

    // MARK: - Intro

    @ViewBuilder
    private var introSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenChangePhoneIntroHeader,
                                    description: L10n.screenChangePhoneIntroMessage,
                                    icon: \.userProfile),
                    kind: .label)
        } header: {
            Text(L10n.screenChangePhoneTitle)
        }

        Section {
            ListRow(label: .centeredAction(title: L10n.actionContinue, icon: \.arrowRight),
                    kind: .button { context.send(viewAction: .start) })
        }
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

    @ViewBuilder
    private var doneSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenChangePhoneDoneHeader,
                                    description: L10n.screenChangePhoneDoneMessage,
                                    icon: \.checkCircle),
                    kind: .label)
        }

        Section {
            ListRow(label: .centeredAction(title: L10n.actionDone, icon: \.check),
                    kind: .button { context.send(viewAction: .done) })
        }
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

// MARK: - Previews

struct ChangePhoneScreen_Previews: PreviewProvider {
    static let viewModel: ChangePhoneScreenViewModel = {
        let clientProxy = ClientProxyMock(.init())
        let userIndicatorController = UserIndicatorControllerMock()
        let identityServiceClient = IdentityServiceClient(baseURL: URL(string: "https://example.com")!)
        return ChangePhoneScreenViewModel(clientProxy: clientProxy,
                                          identityServiceClient: identityServiceClient,
                                          userIndicatorController: userIndicatorController)
    }()

    static var previews: some View {
        NavigationStack {
            ChangePhoneScreen(context: viewModel.context)
        }
    }
}
