import SwiftUI

/// Where each marked control is, for the overlay that draws the spotlight (N311).
struct TutorialAnchorKey: PreferenceKey {
    static let defaultValue: [TutorialAnchorID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialAnchorID: Anchor<CGRect>], nextValue: () -> [TutorialAnchorID: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

/// Which marked controls are on screen (the model skips a step whose target is missing).
struct TutorialAnchorIDsKey: PreferenceKey {
    static let defaultValue: Set<TutorialAnchorID> = []
    static func reduce(value: inout Set<TutorialAnchorID>, nextValue: () -> Set<TutorialAnchorID>) { value.formUnion(nextValue()) }
}

extension View {
    /// Marks a control a tour step can point at. The control's own VoiceOver label stays as it is.
    func tutorialAnchor(_ id: TutorialAnchorID) -> some View {
        // Transform, not set: a marked card keeps the marks of the controls inside it.
        transformAnchorPreference(key: TutorialAnchorKey.self, value: .bounds) { $0[id] = $0[id] ?? $1 }
            .transformPreference(TutorialAnchorIDsKey.self) { $0.insert(id) }
    }

    /// Marks the control only when `on` (one item of a list).
    @ViewBuilder func tutorialAnchor(_ id: TutorialAnchorID, if on: Bool) -> some View {
        if on { tutorialAnchor(id) } else { self }
    }

    /// Draws the tour over this view (the window, or an open sheet) when the current step's target is inside it.
    /// `name` keeps the window's and a sheet's anchors apart.
    func tutorialHost(_ model: TutorialModel?, name: String) -> some View {
        modifier(TutorialHost(model: model, name: name))
    }
}

private struct TutorialHost: ViewModifier {
    let model: TutorialModel?
    let name: String

    func body(content: Content) -> some View {
        if let model {
            content
                .onPreferenceChange(TutorialAnchorIDsKey.self) { ids in
                    MainActor.assumeIsolated { model.anchorsChanged(host: name, ids) }
                }
                .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                    TutorialOverlay(model: model, anchors: anchors, isWindow: name == TutorialOverlay.windowHost)
                }
                .onDisappear { model.anchorsChanged(host: name, []) }
        } else {
            content
        }
    }
}
