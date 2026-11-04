import SwiftUI

/// N385: the Review packets tile. Cards in review with their build, tests, shots, diff size and files outside the card's list; Open packet
/// opens the review the way Waiting for you does. One card is shown in full, several as a list (a taller tile shows more of them).
struct ReviewPacketsTile: View {
    let packets: [ReviewPacketSummary]
    let onOpen: (String) -> Void

    var body: some View {
        DashboardTileShell(title: "Review packets", meta: packets.isEmpty ? nil : "\(packets.count) ready") {
            if packets.isEmpty {
                Text(DashboardFeeds.noPackets).font(.system(size: 13)).foregroundStyle(Tok.ink3)
            } else if packets.count == 1, let p = packets.first {
                VStack(alignment: .leading, spacing: 10) {
                    head(p, size: 13.5)
                    chips(p)
                    outsideRow(p)
                }
            } else {
                Scroller {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(packets) { p in
                            VStack(alignment: .leading, spacing: 6) {
                                head(p, size: 13)
                                HStack(spacing: 6) {
                                    chips(p)
                                    if !p.outside.isEmpty { outsideDot(p) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func head(_ p: ReviewPacketSummary, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(p.id).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundStyle(Tok.ink)
            Text(p.title).font(.system(size: size)).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Open packet") { onOpen(p.id) }.buttonStyle(PanelButtonStyle()).controlSize(.small)
                .help("Open the review of \(p.id)").accessibilityLabel("Open packet \(p.id)")
        }
    }

    private func chips(_ p: ReviewPacketSummary) -> some View {
        HStack(spacing: 6) {
            Chip(text: p.buildText, tint: p.build == .passed ? Tok.go : p.build == .failed ? Tok.stop : nil)
            Chip(text: p.testsText, tint: Self.testsTint(p.tests))
            Chip(text: "shots \(p.shots)")
            if let d = p.diff { Text(d.text).font(Tok.Font.mono).foregroundStyle(Tok.ink2).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Tok.raise, in: Capsule()) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Green when nothing failed, red when something did, neutral when the line could not be read.
    static func testsTint(_ tests: String?) -> Color? {
        guard let tests, let failed = tests.split(separator: "/").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        return failed == 0 ? Tok.go : Tok.stop
    }

    @ViewBuilder private func outsideRow(_ p: ReviewPacketSummary) -> some View {
        if !p.outside.isEmpty {
            HStack(spacing: 8) {
                Circle().fill(Tok.wait).frame(width: 7, height: 7)
                Text(Self.outsideText(p.outside.count)).font(.system(size: 12.5)).foregroundStyle(Tok.ink)
                Spacer(minLength: 4)
                Text(Self.outsideNames(p.outside)).font(.system(size: 12)).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func outsideDot(_ p: ReviewPacketSummary) -> some View {
        Circle().fill(Tok.wait).frame(width: 7, height: 7)
            .help(Self.outsideText(p.outside.count) + ": " + p.outside.joined(separator: ", "))
            .accessibilityLabel(Self.outsideText(p.outside.count))
    }

    static func outsideText(_ n: Int) -> String { n == 1 ? "1 file outside the card's list" : "\(n) files outside the card's list" }
    /// "project.pbxproj, …": the first file name, then an ellipsis when there are more.
    static func outsideNames(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        return (first as NSString).lastPathComponent + (paths.count > 1 ? ", …" : "")
    }
}

/// The tile on the Dashboard: reads the selected project's packets off the main thread (card files, `tasks/<ID>/`, git) whenever a card
/// in review changes, and again each minute.
struct ReviewPacketsLiveTile: View {
    @Bindable var model: PanelModel
    let onOpen: (String) -> Void
    @State private var read: (key: String, packets: [ReviewPacketSummary])?

    private var inReview: [TaskCard] { model.selectedTaskCards.filter { $0.status == .review } }
    private var key: String {
        (model.selectedProjectID ?? "") + "|" + inReview.map { "\($0.id)@\($0.modified?.timeIntervalSince1970 ?? 0)" }.joined(separator: ",")
    }

    var body: some View {
        let key = key
        ReviewPacketsTile(packets: read?.key == key ? read!.packets : DashboardFeeds.reviewPackets(cards: inReview, dataDir: nil), onOpen: onOpen)
            .task(id: key) {
                let cards = inReview
                let project = model.selectedProject
                let runner: GitToolRunning? = PanelModel.runsUnderXCTest ? nil : ProcessToolRunner(timeout: 30)
                while !Task.isCancelled {
                    let packets = await Self.load(cards: cards, project: project, runner: runner)
                    guard !Task.isCancelled else { return }
                    read = (key, packets)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    static func load(cards: [TaskCard], project: ProjectConfig?, runner: GitToolRunning?) async -> [ReviewPacketSummary] {
        var diffs: [String: BranchDiff] = [:]
        if let project, let runner {
            for c in cards {
                let branch = c.branch ?? "task/\(c.id.lowercased())"
                if let d = await DashboardFeeds.readDiff(repo: project.repoPath, base: project.baseBranch, branch: branch, runner: runner) { diffs[c.id] = d }
            }
        }
        let dataDir = project?.dataURL
        return await Task.detached { DashboardFeeds.reviewPackets(cards: cards, dataDir: dataDir, diffs: diffs) }.value
    }
}
