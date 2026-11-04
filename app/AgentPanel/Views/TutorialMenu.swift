import SwiftUI

/// The `?` in the top bar, left of the Inbox (N311, artboard C1): a popover with "Tour this screen", every tour with its state,
/// "Offer a tour on a new screen" and "Reset all tours…".
struct TutorialButton: View {
    @Bindable var model: TutorialModel
    let screen: ShellScreen
    let hasProjects: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Button { model.popoverOpen.toggle() } label: {
            Text("?").font(Tok.Font.body.weight(.semibold)).foregroundStyle(model.popoverOpen ? Tok.work : Tok.ink2)
                .frame(width: 32, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.popoverOpen ? Tok.work : Tok.line))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Tours: see where things are on each screen (⌘?)")
        .accessibilityLabel("Tours")
        .popover(isPresented: Binding(get: { model.popoverOpen && !snapshot }, set: { model.popoverOpen = $0 }), arrowEdge: .bottom) {
            TutorialPanel(model: model, screen: screen, hasProjects: hasProjects).onExitCommand { model.popoverOpen = false }
        }
    }
}

/// The popover's list.
struct TutorialPanel: View {
    @Bindable var model: TutorialModel
    let screen: ShellScreen
    let hasProjects: Bool

    var body: some View {
        let here = TutorialTours.forScreen(screen, hasProjects: hasProjects)
        VStack(alignment: .leading, spacing: 2) {
            Text("TOURS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Tok.ink3)
                .padding(.horizontal, Tok.Space.s).padding(.bottom, Tok.Space.xs)
            row(title: "Tour this screen", detail: here.map { "\($0.title) · \($0.tour.steps.count) steps" } ?? "none here", color: Tok.ink3, strong: true) {
                if let here { model.open(here) }
            }
            .disabled(here == nil)
            Divider().overlay(Tok.line).padding(.vertical, Tok.Space.xs)
            ForEach(TutorialTourID.allCases, id: \.self) { id in
                row(title: id.title, detail: model.stateLabel(id), color: color(model.progress(id).state)) { model.open(id) }
            }
            Divider().overlay(Tok.line).padding(.vertical, Tok.Space.xs)
            // A chip as in the artboard (C1), which a snapshot can draw, unlike an AppKit switch.
            let on = model.save.offerOnNewScreen
            Button { model.setOfferOnNewScreen(!on) } label: {
                HStack {
                    Text("Offer a tour on a new screen").font(Tok.Font.body).foregroundStyle(Tok.ink)
                    Spacer(minLength: Tok.Space.m)
                    Text(on ? "On" : "Off").font(Tok.Font.small.weight(.medium)).foregroundStyle(on ? Tok.go : Tok.ink3)
                        .padding(.horizontal, 8).padding(.vertical, 2).background((on ? Tok.go : Tok.ink3).opacity(0.14), in: Capsule())
                }
                .padding(.horizontal, Tok.Space.s).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Offer a tour on a new screen").accessibilityValue(on ? "On" : "Off")
            Button { model.popoverOpen = false; model.confirmingReset = true } label: {
                Text("Reset all tours…").font(Tok.Font.body).foregroundStyle(Tok.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Tok.Space.s).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(Tok.Space.m)
        .frame(width: 300)
        .background(Tok.pane)
    }

    private func color(_ state: TutorialProgress.State) -> Color {
        switch state {
        case .finished: Tok.go
        case .inProgress: Tok.work
        case .skipped, .notStarted: Tok.ink3
        }
    }

    private func row(title: String, detail: String, color: Color, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(strong ? Tok.Font.bodyStrong : Tok.Font.body).foregroundStyle(Tok.ink)
                Spacer(minLength: Tok.Space.m)
                Text(detail).font(Tok.Font.small).foregroundStyle(color)
            }
            .padding(.horizontal, Tok.Space.s).padding(.vertical, 5)
            .background(strong ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// The first visit to a screen (artboard C3): "New here? Plan in 4 steps · Take the tour · ✕" under the top bar. It goes on ✕, on Take the
/// tour, on Esc, on a click anywhere outside it (the click still lands), or after 8 seconds, and never covers the screen.
struct TutorialNudge: View {
    let model: TutorialModel
    let screen: ShellScreen
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?

    var body: some View {
        if let id = TutorialTours.forScreen(screen, hasProjects: true) {
            HStack(spacing: Tok.Space.s) {
                Text("New here? \(screen.railTitle) in \(id.tour.steps.count) steps").font(Tok.Font.body).foregroundStyle(Tok.ink)
                Button("Take the tour") { model.start(id) }.buttonStyle(CoachButtonStyle(primary: true))
                Button { model.dismissNudge() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.ink3).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
            .padding(.leading, Tok.Space.m).padding(.trailing, Tok.Space.s).padding(.vertical, 5)
            .background(Tok.pane, in: Capsule())
            .overlay(Capsule().stroke(Tok.line))
            .shadow(color: .black.opacity(Tok.shadowOpacity(0.2)), radius: 8, y: 3)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .padding(.top, Tok.Space.s)
            .task(id: screen) {
                try? await Task.sleep(for: .seconds(8))
                if model.nudge == screen { model.nudge = nil }
            }
            .onAppear(perform: watch)
            .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        }
    }

    /// A click outside the capsule is passed on unchanged; Esc is used up by the nudge.
    private func watch() {
        guard monitor == nil, NSApp != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                model.dismissNudge()
                return nil
            }
            if let height = event.window?.contentView?.bounds.height {
                let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                if frame.contains(point) { return event }
            }
            model.dismissNudge()
            return event
        }
    }
}
