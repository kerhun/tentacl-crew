import SwiftUI
import AppKit

/// The tour over a window or a sheet (N311, spec "Biçim"): the rest dimmed, a 3 pt ring around the target, the coach card beside it.
/// The dim never takes a click: the target (and everything else) stays clickable. Only the card's own buttons act, and none of them
/// changes anything but the tour.
struct TutorialOverlay: View {
    static let windowHost = "window"
    static let cardWidth: CGFloat = 300
    private static let gap: CGFloat = 14

    let model: TutorialModel
    let anchors: [TutorialAnchorID: Anchor<CGRect>]
    /// The window's host also draws the welcome and offer cards.
    let isWindow: Bool
    @State private var cardHeight: CGFloat = 180
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            if model.active != nil, let id = model.highlighted, let anchor = anchors[id] {
                let target = model.showsExample ? Self.exampleRect(g[anchor]) : g[anchor]
                let ring = target.insetBy(dx: -4, dy: -4)
                ZStack(alignment: .topLeading) {
                    dim(hole: ring, size: g.size)
                    if model.showsExample { ExampleQuestion().frame(width: target.width, height: target.height).offset(x: target.minX, y: target.minY) }
                    RoundedRectangle(cornerRadius: 10).stroke(Tok.work, lineWidth: 3)
                        .frame(width: ring.width, height: ring.height).offset(x: ring.minX, y: ring.minY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    let place = Self.place(target: ring, card: CGSize(width: Self.cardWidth, height: cardHeight), in: g.size)
                    CoachCard(model: model, arrow: place.arrow)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { cardHeight = $0 }
                        .offset(x: place.origin.x, y: place.origin.y)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.index)
                .background(TutorialKeys(onEsc: { model.skip() }, onNext: { model.next() }, onBack: { model.back() }))
            } else if isWindow, model.active == nil, let card = model.card {
                ZStack {
                    dim(hole: nil, size: g.size)
                    OfferCard(model: model, card: card)
                }
                .frame(width: g.size.width, height: g.size.height)
                .background(TutorialKeys(onEsc: { if card == .welcome { model.declineWelcome() } else { model.card = nil } },
                                         onNext: { model.start(card == .welcome ? .firstLaunch : .dashboard) }, onBack: {}))
            }
        }
        .onChange(of: model.announcement) { _, text in
            if !text.isEmpty { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// The dim: black like the shadows (`Tok.shadowOpacity`), 46 % in a light theme and 62 % in a dark one (spec "Biçim").
    private func dim(hole: CGRect?, size: CGSize) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            if let hole { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10)) }
        }
        .fill(Color.black.opacity(scheme == .light ? 0.46 : 0.62), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the dashed example question goes: just above the message field it stands in for.
    static func exampleRect(_ field: CGRect) -> CGRect {
        CGRect(x: field.minX, y: field.minY - 84, width: field.width, height: 72)
    }

    enum ArrowEdge: Equatable { case leading, trailing, top, bottom }
    struct Placement: Equatable {
        var origin: CGPoint
        /// The card's edge that faces the target, and how far along it the arrow sits.
        var arrow: (edge: ArrowEdge, at: CGFloat)
        static func == (a: Placement, b: Placement) -> Bool { a.origin == b.origin && a.arrow.edge == b.arrow.edge && a.arrow.at == b.arrow.at }
    }

    /// Right of the target, else left, else below, else above; slid back inside the window, the arrow still on the target.
    static func place(target r: CGRect, card: CGSize, in size: CGSize) -> Placement {
        let m: CGFloat = 8
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, m), max(m, size.height - card.height - m)) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, m), max(m, size.width - card.width - m)) }
        func along(_ v: CGFloat, _ length: CGFloat) -> CGFloat { min(max(v, 16), length - 16) }
        if r.maxX + gap + card.width <= size.width - m {
            let y = clampY(r.midY - card.height / 2)
            return Placement(origin: CGPoint(x: r.maxX + gap, y: y), arrow: (.leading, along(r.midY - y, card.height)))
        }
        if r.minX - gap - card.width >= m {
            let y = clampY(r.midY - card.height / 2)
            return Placement(origin: CGPoint(x: r.minX - gap - card.width, y: y), arrow: (.trailing, along(r.midY - y, card.height)))
        }
        let x = clampX(r.midX - card.width / 2)
        if r.maxY + gap + card.height <= size.height - m {
            return Placement(origin: CGPoint(x: x, y: r.maxY + gap), arrow: (.top, along(r.midX - x, card.width)))
        }
        return Placement(origin: CGPoint(x: x, y: max(m, r.minY - gap - card.height)), arrow: (.bottom, along(r.midX - x, card.width)))
    }
}

/// The coach card: `<Tour> · step n of N`, the title, one or two sentences, `Try it:`, the dots and Skip tour · Back · Next.
struct CoachCard: View {
    let model: TutorialModel
    var arrow: (edge: TutorialOverlay.ArrowEdge, at: CGFloat) = (.leading, 40)

    var body: some View {
        let pos = model.position
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack {
                Text("\(model.tour?.id.title ?? "") · step \(pos.n) of \(pos.of)")
                    .accessibilityLabel("\(model.tour?.id.title ?? "") tour, step \(pos.n) of \(pos.of). Highlighted: \(model.highlighted?.spokenName ?? "")")
                Spacer(minLength: Tok.Space.s)
                Text("Esc skips")
            }
            .font(Tok.Font.small).foregroundStyle(Tok.ink3)
            Text(model.step?.title ?? "").font(Tok.Font.heading).foregroundStyle(Tok.ink).accessibilityAddTraits(.isHeader)
            Text(model.text).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            if let tryIt = model.step?.tryIt, !model.isAlone {
                Text("Try it: \(tryIt)").font(Tok.Font.small).foregroundStyle(Tok.work)
            }
            HStack(spacing: Tok.Space.s) {
                TutorialDots(n: pos.n, of: pos.of)
                Spacer(minLength: 0)
                Button("Skip tour") { model.skip() }.buttonStyle(CoachButtonStyle())
                Button("Back") { model.back() }.buttonStyle(CoachButtonStyle()).disabled(pos.n <= 1)
                Button(model.isLast ? "Done" : "Next") { model.next() }.buttonStyle(CoachButtonStyle(primary: true))
            }
            .padding(.top, Tok.Space.xs)
        }
        .padding(Tok.Space.l - 2)
        .frame(width: TutorialOverlay.cardWidth, alignment: .leading)
        .background(alignment: .topLeading) { CoachArrow(edge: arrow.edge, at: arrow.at) }
        .coachCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// The small diamond on the card's edge that points at the target.
private struct CoachArrow: View {
    let edge: TutorialOverlay.ArrowEdge
    let at: CGFloat

    var body: some View {
        GeometryReader { g in
            let p: CGPoint = switch edge {
            case .leading: CGPoint(x: 0, y: at)
            case .trailing: CGPoint(x: g.size.width, y: at)
            case .top: CGPoint(x: at, y: 0)
            case .bottom: CGPoint(x: at, y: g.size.height)
            }
            Rectangle().fill(Tok.pane).overlay(Rectangle().stroke(Tok.line))
                .frame(width: 12, height: 12).rotationEffect(.degrees(45))
                .position(p)
        }
        .accessibilityHidden(true)
    }
}

/// The progress dots: done and current in the accent, the rest as lines.
struct TutorialDots: View {
    let n: Int
    let of: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...max(of, 1), id: \.self) { i in
                Circle().fill(i <= n ? Tok.work : Tok.line).frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The card's buttons: Next/Done/Start filled with the accent, the others plain text.
struct CoachButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(primary ? Tok.Font.bodyStrong : Tok.Font.body)
            .lineLimit(1).fixedSize()
            .foregroundStyle(primary ? Tok.bg : Tok.ink2)
            .padding(.horizontal, primary ? 12 : 6).frame(height: 26)
            .background(primary ? Tok.work : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension View {
    /// The coach card's surface: the pane, a hairline and a soft shadow.
    func coachCardChrome() -> some View {
        background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
            .shadow(color: .black.opacity(Tok.shadowOpacity(0.35)), radius: 18, y: 8)
    }
}

/// The first-launch welcome (A1) and the Dashboard tour offered after first launch.
private struct OfferCard: View {
    let model: TutorialModel
    let card: TutorialModel.Card

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack {
                Text(card == .welcome ? "Welcome · before you start" : "First launch · done")
                Spacer()
                Text("Esc skips")
            }
            .font(Tok.Font.small).foregroundStyle(Tok.ink3)
            Text(card == .welcome ? "Welcome to Tentacl Crew" : "Tour the Dashboard?").font(Tok.Font.heading).foregroundStyle(Tok.ink).accessibilityAddTraits(.isHeader)
            Text(card == .welcome ? "Tentacl Crew runs a small AI team on your project. A PM plans and starts the work; you answer questions and approve."
                                  : "Eight short steps, about a minute: where things are and what waits for you.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            if card == .welcome {
                VStack(alignment: .leading, spacing: Tok.Space.s) {
                    item(1, "Check the tools (Setup)")
                    item(2, "Add your first project")
                    item(3, "Meet your team")
                }
                .padding(Tok.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: Tok.Space.s) {
                if card == .welcome { Text("You can open tours again with the ? button.").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                Spacer(minLength: 0)
                Button("Not now") { if card == .welcome { model.declineWelcome() } else { model.card = nil } }.buttonStyle(CoachButtonStyle())
                Button(card == .welcome ? "Start the tour" : "Start") { model.start(card == .welcome ? .firstLaunch : .dashboard) }
                    .buttonStyle(CoachButtonStyle(primary: true))
            }
        }
        .padding(Tok.Space.l + 2)
        .frame(width: 380, alignment: .leading)
        .coachCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func item(_ n: Int, _ text: String) -> some View {
        HStack(spacing: Tok.Space.s) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(Tok.bg).frame(width: 18, height: 18).background(Tok.work, in: Circle())
            Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink)
        }
    }
}

/// The dashed stand-in for a question when none is open (Chat tour, step 4): it is marked "example" and sends nothing.
private struct ExampleQuestion: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Tok.Space.s) {
                Text("example").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(Tok.line))
                Text("PM asks").font(Tok.Font.small).foregroundStyle(Tok.askText)
                Text("Start N300 now?").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            }
            HStack(spacing: 6) {
                ForEach(["1  Yes", "2  Yes, and don't ask again", "3  No"], id: \.self) { option in
                    Text(option).font(Tok.Font.small).foregroundStyle(Tok.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example question: Start N300 now? Options 1 Yes, 2 Yes and don't ask again, 3 No")
    }
}

/// → / Return: Next, ←: Back, Esc: Skip tour, while the card is up. Arrows and Return stay with a text field the user is typing in.
private struct TutorialKeys: View {
    let onEsc: () -> Void
    let onNext: () -> Void
    let onBack: () -> Void
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .onAppear {
                guard monitor == nil, NSApp != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                    let typing = event.window?.firstResponder is NSText
                    switch event.keyCode {
                    case 53: onEsc(); return nil
                    case 124, 36, 76: if typing { return event }; onNext(); return nil
                    case 123: if typing { return event }; onBack(); return nil
                    default: return event
                    }
                }
            }
            .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
