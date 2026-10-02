//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// Six-bubble PIN entry. A hidden `SecureField` captures keystrokes while a row of circles shows
/// how many digits have been entered. Tapping the row refocuses the field.
struct PinBubbleField: View {
    @Binding var pin: String
    let length: Int
    var hasError = false
    @FocusState private var isFocused: Bool

    init(pin: Binding<String>, length: Int = 6, hasError: Bool = false) {
        _pin = pin
        self.length = length
        self.hasError = hasError
    }

    var body: some View {
        ZStack {
            // Hidden field that owns the keyboard.
            SecureField("", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.02) // Must be > 0 to remain focusable in SwiftUI.
                .accessibilityHidden(true)
                .onChange(of: pin) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(length))
                    if filtered != newValue { pin = filtered }
                }

            HStack(spacing: 14) {
                ForEach(0..<length, id: \.self) { index in
                    bubble(filled: index < pin.count)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear { isFocused = true }
    }

    private func bubble(filled: Bool) -> some View {
        let fill: Color = hasError ? .compound.iconCriticalPrimary : .compound.iconPrimary
        let stroke: Color = hasError ? .compound.iconCriticalPrimary : .compound.iconSecondary
        return Circle()
            .strokeBorder(stroke, lineWidth: 1.5)
            .background(Circle().fill(filled ? fill : Color.clear))
            .frame(width: 18, height: 18)
            .animation(.easeOut(duration: 0.12), value: filled)
    }
}

#Preview {
    @Previewable @State var pin = "123"
    return Form {
        Section {
            PinBubbleField(pin: $pin)
        }
    }
    .compoundList()
}
