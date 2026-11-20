//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import PhotosUI
import SwiftUI

struct ChatBackgroundScreen: View {
    @Bindable var context: ChatBackgroundScreenViewModel.Context

    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                ListRow(kind: .custom {
                    ChatBackgroundPreviewCard(background: context.viewState.previewBackground, mediaProvider: context.mediaProvider)
                        .padding(16)
                })
            }

            Section {
                ListRow(kind: .custom {
                    ChatBackgroundPresetGrid(selected: context.viewState.selectedPreset) { preset in
                        context.send(viewAction: .selectPreset(preset))
                    }
                    .padding(16)
                })
                .disabled(!context.viewState.canChange)
            }

            Section {
                ListRow(kind: .custom {
                    PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                        ListRowLabel.default(title: UntranslatedL10n.guaChatBackgroundChoosePhoto, icon: \.image)
                    }
                })
                .disabled(!context.viewState.canChange)
            } footer: {
                Text(UntranslatedL10n.guaChatBackgroundSharedNote)
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .safeAreaInset(edge: .bottom) { buttons }
        .navigationTitle(UntranslatedL10n.guaChatBackgroundScreenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
        .fullScreenCover(item: $context.photoDraft) { _ in
            ChatBackgroundPhotoPreview(context: context)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            context.send(viewAction: .photoPicked { try? await item.loadTransferable(type: Data.self) })
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(UntranslatedL10n.guaChatBackgroundActionSet) {
                context.send(viewAction: .apply)
            }
            .buttonStyle(.compound(.primary))
            .disabled(!context.viewState.canSet)

            if context.viewState.canRemove {
                Button(UntranslatedL10n.guaChatBackgroundActionRemove, role: .destructive) {
                    context.send(viewAction: .remove)
                }
                .buttonStyle(.compound(.tertiary))
            }
        }
        .padding(16)
        .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
    }
}

struct ChatBackgroundPreviewCard: View {
    let background: ChatBackground
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        ChatBackgroundSampleMessages(isOnBackground: !background.isNone)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            .background {
                ChatBackgroundView(background: background, mediaProvider: mediaProvider)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.compound.borderInteractiveSecondary, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UntranslatedL10n.guaChatBackgroundPreviewA11y)
            .accessibilityValue(background.displayName)
    }
}

struct ChatBackgroundSampleMessages: View {
    let isOnBackground: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(UntranslatedL10n.guaChatBackgroundSampleToday)
                .font(.compound.bodySMSemibold)
                .foregroundColor(.compound.textPrimary)
                .legibilityCapsule()

            HStack(spacing: 0) {
                bubble(UntranslatedL10n.guaChatBackgroundSampleIncoming, isOutgoing: false)
                Spacer(minLength: 48)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 48)
                bubble(UntranslatedL10n.guaChatBackgroundSampleOutgoing, isOutgoing: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .environment(\.chatBackgroundActive, isOnBackground)
    }

    private func bubble(_ text: String, isOutgoing: Bool) -> some View {
        Text(text)
            .font(.compound.bodyLG)
            .foregroundColor(.compound.textPrimary)
            .bubbleBackground(isOutgoing: isOutgoing, color: isOutgoing ? .compound._bgBubbleOutgoing : .compound._bgBubbleIncoming)
    }
}

/// Phone-shaped swatches up to 88 pt wide, in as many columns as keep the longest name on one line, and at least three.
struct ChatBackgroundPresetGrid: View {
    let selected: ChatBackgroundPreset?
    let onSelect: (ChatBackgroundPreset) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ChatBackgroundPresetGridLayout(minimumCellWidth: minimumCellWidth, maximumCellWidth: max(minimumCellWidth, 88), spacing: 12) {
            ForEach(ChatBackgroundPreset.allCases) { preset in
                ChatBackgroundPresetSwatch(preset: preset, isSelected: preset == selected) {
                    onSelect(preset)
                }
            }
        }
    }

    private var minimumCellWidth: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let longestName = ChatBackgroundPreset.allCases
            .map { ($0.name as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(longestName.rounded(.up) + 4, 56)
    }
}

private struct ChatBackgroundPresetGridLayout: Layout {
    private struct Row {
        let indices: Range<Int>
        let columns: Int
        let cellWidth: CGFloat
        let height: CGFloat
    }

    let minimumCellWidth: CGFloat
    let maximumCellWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumCellWidth * 5 + spacing * 4
        let heights = rows(width: width, subviews: subviews).map(\.height)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            let gridWidth = CGFloat(row.columns) * row.cellWidth + CGFloat(row.columns - 1) * spacing
            let minX = bounds.minX + max(0, (bounds.width - gridWidth) / 2)
            for (column, index) in row.indices.enumerated() {
                subviews[index].place(at: CGPoint(x: minX + CGFloat(column) * (row.cellWidth + spacing), y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: row.cellWidth, height: row.height))
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        let columns = min(max(Int((width + spacing) / (minimumCellWidth + spacing)), 3), max(subviews.count, 3))
        let cellWidth = min(max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)), maximumCellWidth)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let indices = start..<min(start + columns, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            return Row(indices: indices, columns: columns, cellWidth: cellWidth, height: height)
        }
    }
}

private struct ChatBackgroundPresetSwatch: View {
    let preset: ChatBackgroundPreset
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ChatBackgroundFillView(fill: preset.fill(for: colorScheme))
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.compound.borderInteractivePrimary : Color.compound.borderInteractiveSecondary,
                                          lineWidth: isSelected ? 2 : 1)
                    }
                    .overlay {
                        if isSelected {
                            CompoundIcon(\.checkCircleSolid)
                                .foregroundStyle(.compound.iconAccentPrimary)
                                .background(Circle().fill(Color.compound.bgCanvasDefault))
                        }
                    }

                Text(preset.name)
                    .font(.compound.bodySM)
                    .foregroundColor(isEnabled ? .compound.textPrimary : .compound.textDisabled)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ChatBackgroundScreen_Previews: PreviewProvider, TestablePreview {
    static let presetViewModel = makeViewModel(current: .preset(.aurora))
    static let pickedViewModel = makeViewModel(current: .preset(.aurora), picked: .sunset)
    static let photoViewModel = makeViewModel(current: .photo(.mock))
    static let noPermissionViewModel = makeViewModel(current: .none, canChange: false)

    static var previews: some View {
        NavigationStack {
            ChatBackgroundScreen(context: presetViewModel.context)
        }
        .previewDisplayName("Preset")

        NavigationStack {
            ChatBackgroundScreen(context: pickedViewModel.context)
        }
        .previewDisplayName("Preset picked")

        NavigationStack {
            ChatBackgroundScreen(context: photoViewModel.context)
        }
        .previewDisplayName("Photo")

        NavigationStack {
            ChatBackgroundScreen(context: noPermissionViewModel.context)
        }
        .previewDisplayName("No permission")

        NavigationStack {
            ChatBackgroundScreen(context: pickedViewModel.context)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("Preset picked dark")
    }

    static func makeViewModel(current: ChatBackground, picked: ChatBackgroundPreset? = nil, canChange: Bool = true) -> ChatBackgroundScreenViewModel {
        let roomProxy = JoinedRoomProxyMock(.init(id: "chat_background_room", members: [canChange ? .mockMeAdmin : .mockMe, .mockAlice]))
        let viewModel = ChatBackgroundScreenViewModel(roomProxy: roomProxy,
                                                      clientProxy: ClientProxyMock(.init()),
                                                      chatBackgroundService: ChatBackgroundServiceMock(.init(background: current)),
                                                      userIndicatorController: UserIndicatorControllerMock(),
                                                      mediaProvider: MediaProviderMock(configuration: .init()))
        if let picked {
            viewModel.context.send(viewAction: .selectPreset(picked))
        }
        return viewModel
    }
}
