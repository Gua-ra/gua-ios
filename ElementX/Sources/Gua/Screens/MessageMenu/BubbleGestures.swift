//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// Reads a view's frame in window coordinates on demand, so the timeline doesn't track
/// every bubble's geometry while it scrolls.
@MainActor
@Observable
final class WindowFrameReader {
    /// Accessibility clients make SwiftUI build copies of the bubble outside any window, so only a view in a window counts.
    private let views = NSHashTable<UIView>.weakObjects()
    var isLifted = false

    var frame: CGRect? {
        guard let view = views.allObjects.first(where: { $0.window != nil }) else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    func track(_ view: UIView) {
        views.add(view)
    }
}

extension EnvironmentValues {
    @Entry var isMessageMenuPreview = false
}

extension View {
    func readsWindowFrame(_ reader: WindowFrameReader) -> some View {
        background(WindowFrameReaderView(reader: reader))
    }

    /// A double tap that leaves the view's single taps (links, media) undelayed.
    func onDoubleTap(isEnabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        modifier(DoubleTapModifier(isEnabled: isEnabled, action: action))
    }
}

private struct WindowFrameReaderView: UIViewRepresentable {
    let reader: WindowFrameReader

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        reader.track(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        reader.track(uiView)
    }
}

private struct DoubleTapModifier: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .gesture(DoubleTapGestureRepresentable(isEnabled: isEnabled, action: action))
        } else {
            content
                .onTapGesture(count: 2) {
                    if isEnabled {
                        action()
                    }
                }
        }
    }
}

@available(iOS 18, *)
private struct DoubleTapGestureRepresentable: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        .init()
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let gesture = UITapGestureRecognizer()
        gesture.numberOfTapsRequired = 2
        gesture.delegate = context.coordinator
        gesture.isEnabled = isEnabled
        return gesture
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended {
            action()
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
