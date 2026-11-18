//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

extension View {
    @ViewBuilder func backportButtonStyleGlassProminent() -> some View {
        if #available(iOS 26, *) {
            // `.glassProminent` breaks snapshot tests: https://github.com/pointfreeco/swift-snapshot-testing/issues/1029
            if ProcessInfo.isRunningUnitTests {
                self
            } else {
                buttonStyle(.glassProminent)
            }
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
