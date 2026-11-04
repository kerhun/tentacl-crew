import SwiftUI

/// The Team screen's Roster tab: four summary tiles and one card per role (design team-v2, Main).
struct RosterView: View {
    let roster: TeamRoster
    let onEdit: (ResolvedRole) -> Void
    let onDuplicate: (ResolvedRole) -> Void
    let onNewRole: () -> Void

    /// The roles' colours, in roster order (orange stays reserved for "waiting for your decision").
    static let tints: [Color] = [Tok.work, Tok.tintViolet, Tok.tintTeal, Tok.wait, Tok.go, Tok.ink2]
    static func tint(_ index: Int?) -> Color { index.map { tints[$0 % tints.count] } ?? Tok.ink3 }
    static let claudeColor = Tok.claude

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: Tok.Space.xl) {
                HStack(alignment: .firstTextBaseline, spacing: Tok.Space.l) {
                    Text(roster.title).font(Tok.Font.title).foregroundStyle(Tok.ink)
                    Text(roster.subtitle).font(Tok.Font.body).foregroundStyle(Tok.ink2)
                    Spacer(minLength: 0)
                }
                tiles
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Tok.Space.l, alignment: .top)], alignment: .leading, spacing: Tok.Space.l) {
                    ForEach(roster.cards) { RoleCardView(card: $0, onEdit: onEdit, onDuplicate: onDuplicate) }
                    newRoleTile
                }
            }
            .padding(.top, Tok.Space.xl).pageMargin([.horizontal, .bottom])
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: tiles

    private var tiles: some View {
        HStack(alignment: .top, spacing: Tok.Space.m) {
            tile("Agents running") {
                big("\(roster.runningCount)")
                note(roster.runningByRole)
            }
            tile("Engines") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    big("\(roster.claudeCount)"); Text("Claude Code").font(Tok.Font.bodyStrong).foregroundStyle(Self.claudeColor).lineLimit(1).fixedSize()
                    big("\(roster.codexCount)").padding(.leading, 8); Text("Codex").font(Tok.Font.bodyStrong).foregroundStyle(Tok.work)
                }
                note("Pick per role in the role editor")
            }
            tile("Cards done") {
                big("\(roster.doneTotal)")
                if roster.doneTotal > 0 {
                    GeometryReader { geo in
                        let gaps = CGFloat(max(roster.doneSplit.count - 1, 0)) * 2
                        HStack(spacing: 2) {
                            ForEach(roster.doneSplit, id: \.role) { share in
                                Self.tint(share.tint).frame(width: max(2, (geo.size.width - gaps) * CGFloat(share.count) / CGFloat(roster.doneTotal)))
                            }
                        }
                    }
                    .frame(height: 6).clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
                    note(roster.doneLine)
                } else {
                    note("No card is done yet")
                }
            }
            tile("Needs attention") {
                big("\(roster.attention.count)")
                if roster.attention.isEmpty { note("Nothing to look at") }
                ForEach(roster.attention, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // the tiles are as tall as the tallest one, no taller
    }

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Tok.Font.small.weight(.medium)).foregroundStyle(Tok.ink2)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, Tok.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
        .accessibilityElement(children: .combine)
    }

    private func big(_ text: String) -> some View { Text(text).font(.system(size: 24, weight: .bold)).foregroundStyle(Tok.ink) }
    private func note(_ text: String) -> some View { Text(text).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }

    private var newRoleTile: some View {
        Button(action: onNewRole) {
            VStack(spacing: 10) {
                Text("+").font(.system(size: 22)).foregroundStyle(Tok.ink).frame(width: 44, height: 44).background(Tok.raise, in: RoundedRectangle(cornerRadius: 12))
                Text("New role").font(Tok.Font.heading).foregroundStyle(Tok.ink)
                Text("Start from a template: tester, designer, docs writer, security reviewer").font(Tok.Font.body).foregroundStyle(Tok.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, minHeight: 320).padding(Tok.Space.xl)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New role from a template")
    }
}

/// One role on the Roster.
struct RoleCardView: View {
    let card: RosterCard
    let onEdit: (ResolvedRole) -> Void
    let onDuplicate: (ResolvedRole) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: Tok.Space.s) {
                fact("Model") { Text(card.modelLabel).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1) }
                fact("Effort") {
                    HStack(spacing: 3) {
                        ForEach(0..<card.effortSteps, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(i < card.effortStep ? Tok.work : Tok.line).frame(width: 12, height: 6)
                        }
                    }.accessibilityHidden(true)
                    Text(card.effort).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
                }
                fact("Permissions") { Text(card.modeLabel).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1) }
            }
            Text(card.modeMeaning).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                line("Reports to", card.reportsTo)
                line("Gives tasks to", card.givesTasksTo)
            }
            running
            HStack(spacing: Tok.Space.s) {
                Button { onEdit(card.role) } label: {
                    Text("Edit role").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).frame(maxWidth: .infinity, minHeight: 32)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Edit role \(card.name)")
                Button { onDuplicate(card.role) } label: {
                    Text("Duplicate").font(Tok.Font.body).foregroundStyle(Tok.ink2).padding(.horizontal, Tok.Space.m).frame(minHeight: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line)).contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Duplicate role \(card.name)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tok.line))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tok.Space.m) {
            Text(card.initial).font(.system(size: 15, weight: .bold)).foregroundStyle(Tok.bg)
                .frame(width: 40, height: 40).background(RosterView.tint(card.tint), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s) {
                    Text(card.display).font(.system(size: 16, weight: .bold)).foregroundStyle(Tok.ink).lineLimit(1)
                    if card.display != card.name { Text(card.name).font(Tok.Font.mono).foregroundStyle(Tok.ink2) }
                }
                Text(card.scope).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            }
            Spacer(minLength: 0)
            let color = card.isCodex ? Tok.work : RosterView.claudeColor
            Text(card.isCodex ? "Codex" : "Claude Code").font(Tok.Font.small.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule()).overlay(Capsule().stroke(color.opacity(0.35)))
        }
    }

    private func fact<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            content()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s) {
            Text(label).font(Tok.Font.body).foregroundStyle(Tok.ink2).frame(width: 96, alignment: .leading)
            Text(value).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack {
                Text("Running now"); Spacer(); Text("\(card.done) done · \(card.waiting) waiting")
            }.font(Tok.Font.small).foregroundStyle(Tok.ink2)
            if card.agents.isEmpty { Text("No agent running").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
            ForEach(Array(card.agents.enumerated()), id: \.offset) { _, agent in
                let color = Self.color(agent)
                HStack(spacing: Tok.Space.s) {
                    Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                    if let id = agent.cardID { Text(id).font(Tok.Font.mono).foregroundStyle(Tok.ink) }
                    Text(agent.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(agent.label).font(Tok.Font.small).foregroundStyle(color)
                }
            }
        }
        .padding(.top, Tok.Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    static func color(_ agent: RosterAgent) -> Color {
        switch agent.stage {
        case .review?: return Tok.waitReview
        case .needsFix? where agent.state != .working: return Tok.wait
        default: return color(agent.state)
        }
    }

    static func color(_ state: AgentState) -> Color {
        switch state {
        case .working: return Tok.work
        case .blocked: return Tok.wait
        case .done: return Tok.go
        case .idle, .unknown: return Tok.ink3
        }
    }

    static func label(_ state: AgentState) -> String {
        switch state {
        case .working: return "working"
        case .blocked: return "blocked"
        case .done: return "done"
        case .idle: return "idle"
        case .unknown(let raw): return raw
        }
    }
}
