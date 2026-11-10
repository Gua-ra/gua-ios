//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import PhotosUI
import SwiftUI

struct ChatWallpaperPicker: View {
    @Bindable var context: ChatThemeScreenViewModel.Context

    @State private var pickerItem: PhotosPickerItem?

    private var viewState: ChatThemeScreenViewState {
        context.viewState
    }

    private var selectedPreset: ChatBackgroundPreset? {
        guard case .preset(let preset) = viewState.current.wallpaper else { return nil }
        return preset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ListRow(kind: .custom {
                        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                            ListRowLabel.default(title: UntranslatedL10n.guaChatThemeChoosePhoto, icon: \.image)
                        }
                    })

                    ListRow(label: .default(title: UntranslatedL10n.guaChatThemeNoWallpaper, icon: \.block),
                            kind: .selection(isSelected: viewState.current.wallpaper.isNone) {
                                context.send(viewAction: .selectWallpaper(.none))
                            })
                }

                section(UntranslatedL10n.guaChatThemeSectionColours, presets: ChatBackgroundPreset.colours)
                section(UntranslatedL10n.guaChatThemeSectionGradients, presets: ChatBackgroundPreset.gradients)
            }
            .compoundList()
            .navigationTitle(UntranslatedL10n.guaChatThemeWallpaper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.isWallpaperPickerPresented = false
                    }
                }
            }
            .fullScreenCover(item: $context.wallpaperPreview) { draft in
                ChatThemePreview(context: context, draft: draft, saveTitle: UntranslatedL10n.guaChatThemeActionSet)
            }
        }
        .alert(item: $context.alertInfo.presented(if: viewState.bindings.isWallpaperPickerTopmost))
        .fullScreenCover(item: $context.photoDraft) { _ in
            ChatBackgroundPhotoPreview(context: context)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            context.send(viewAction: .photoPicked { try? await item.loadTransferable(type: Data.self) })
        }
    }

    private func section(_ title: String, presets: [ChatBackgroundPreset]) -> some View {
        Section {
            ListRow(kind: .custom {
                ChatBackgroundPresetGrid(presets: presets, selected: selectedPreset) { preset in
                    context.send(viewAction: .selectWallpaper(.preset(preset)))
                }
                .padding(16)
            })
        } header: {
            Text(title)
                .compoundListSectionHeader()
        }
    }
}

/// Phone-shaped swatches up to 88 pt wide, in as many columns as keep the longest name of any preset on one line, and at least three.
struct ChatBackgroundPresetGrid: View {
    let presets: [ChatBackgroundPreset]
    let selected: ChatBackgroundPreset?
    let onSelect: (ChatBackgroundPreset) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ChatBackgroundPresetGridLayout(minimumCellWidth: minimumCellWidth, maximumCellWidth: max(minimumCellWidth, 88), spacing: 12) {
            ForEach(presets) { preset in
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

struct ChatWallpaperPicker_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()

    static var previews: some View {
        ChatWallpaperPicker(context: viewModel.context)
    }

    static func makeViewModel() -> ChatThemeScreenViewModel {
        let viewModel = ChatThemeScreen_Previews.makeViewModel(theme: .init(wallpaper: .preset(.dusk), bubble: .orange))
        viewModel.context.send(viewAction: .presentWallpaperPicker)
        return viewModel
    }
}
