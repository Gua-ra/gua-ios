//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatPhotoCreditsScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            ForEach(ChatArtwork.artworks(in: .photos)) { artwork in
                if let credit = artwork.credit {
                    section(artwork: artwork, credit: credit)
                }
            }
        }
        .compoundList()
        .navigationTitle(UntranslatedL10n.guaChatThemePhotoCredits)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.actionDone) {
                    dismiss()
                }
            }
        }
    }
    
    /// One row per link: buttons that share a form row all fire on a single tap.
    private func section(artwork: ChatArtwork, credit: ChatArtwork.Credit) -> some View {
        Section {
            ListRow(kind: .custom {
                HStack(spacing: ListRowPadding.labelIconSpacing) {
                    ChatBackgroundView(background: .art(artwork), mediaProvider: nil)
                        .frame(width: 45, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artwork.name)
                            .font(.compound.bodyLG)
                            .foregroundStyle(.compound.textPrimary)
                        Text(UntranslatedL10n.guaChatThemePhotoCredit(credit.author))
                            .font(.compound.bodySM)
                            .foregroundStyle(.compound.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(ListRowPadding.insets)
                .accessibilityElement(children: .combine)
            })
            
            ListRow(label: .plain(title: credit.licence.name),
                    kind: .button { openURL(credit.licence.deedURL) })
            
            if let sourceURL = credit.sourceURL {
                ListRow(label: .plain(title: UntranslatedL10n.guaChatThemePhotoSource),
                        kind: .button { openURL(sourceURL) })
            }
        } footer: {
            Text(UntranslatedL10n.guaChatThemePhotoChanges)
                .compoundListSectionFooter()
        }
    }
}

struct ChatPhotoCreditLine: View {
    let credit: ChatArtwork.Credit
    let action: () -> Void
    
    var body: some View {
        Button(UntranslatedL10n.guaChatThemePhotoCreditLicence(credit.author, credit.licence.name), action: action)
            .buttonStyle(.compound(.textLink, size: .small))
    }
}

struct ChatThemeSectionHeader: View {
    let section: ChatThemeGallerySection.Kind
    let onPhotoCredits: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text(section.title)
            
            Spacer()
            
            if section == .photos {
                Button(UntranslatedL10n.guaChatThemePhotoCredits, action: onPhotoCredits)
                    .buttonStyle(.compound(.textLink, size: .small))
            }
        }
        .compoundListSectionHeader()
    }
}

extension View {
    func chatPhotoCreditsSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            ElementNavigationStack {
                ChatPhotoCreditsScreen()
            }
        }
    }
}

struct ChatPhotoCreditsScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        ElementNavigationStack {
            ChatPhotoCreditsScreen()
        }
        .previewDisplayName("Light")
        
        ElementNavigationStack {
            ChatPhotoCreditsScreen()
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("Dark")
    }
}
