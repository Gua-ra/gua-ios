//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A message's text with the system selection handles, for copying, translating or looking up part of it.
struct MessageTextSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let info: TimelineItemTextSelectionInfo

    var body: some View {
        NavigationStack {
            SelectableTextView(text: info.text)
                .background(Color.compound.bgCanvasDefault)
                .navigationTitle(UntranslatedL10n.guaMessageTextSelectionTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.actionDone) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String
    
    func makeUIView(context: Context) -> SelectAllTextView {
        let textView = SelectAllTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = UIColor(.compound.textPrimary)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.text = text
        return textView
    }
    
    func updateUIView(_ textView: SelectAllTextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

/// Selects all of its text the first time it appears, so the selection handles show straight away.
private final class SelectAllTextView: UITextView {
    private var hasSelectedAll = false
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasSelectedAll else { return }
        hasSelectedAll = true
        
        // Becoming first responder only works once the sheet has finished presenting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            guard let self, window != nil else { return }
            becomeFirstResponder()
            selectAll(nil)
        }
    }
}

// MARK: - Previews

struct MessageTextSelectionSheet_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        MessageTextSelectionSheet(info: .init(id: .randomEvent,
                                              text: "Me mudei pra Floripa ano passado, tô morando de frente pro mar agora 🌅"))
    }
}
