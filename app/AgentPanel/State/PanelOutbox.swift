import Foundation

/// The panel's own messages to an agent (start and approve answers to the PM) that wait until that agent can take them:
/// sent in order, one pane at a time, only while the agent is idle or done (never while it works or shows a menu).
/// Kept in memory only; a restart of the panel drops what is still waiting.
@MainActor
final class PanelOutbox {
    struct Item: Equatable {
        let id: String
        let pane: String
        let text: String
        let added: Date
        /// The project whose chat shows the message as pending.
        let project: String?
    }

    /// A message that was dropped after `staleAfter`, kept for the user (Waiting for you) with why it never arrived.
    struct Undelivered: Equatable, Identifiable {
        let item: Item
        let reason: String
        var id: String { item.id }
    }

    /// A message still waiting after this long is dropped (and logged by the caller).
    static let staleAfter: TimeInterval = 30 * 60

    private(set) var items: [Item] = []
    /// Dropped messages that wait for Retry or Dismiss, oldest first.
    private(set) var undelivered: [Undelivered] = []
    private var delivering = false
    /// The pane the user is typing to on the Terminals screen: its messages wait until the user leaves the message box (N224).
    var typingPane: String?

    @discardableResult
    func add(_ text: String, pane: String, project: String? = nil, now: Date = Date()) -> Item {
        let item = Item(id: "outbox-" + UUID().uuidString, pane: pane, text: text, added: now, project: project)
        items.append(item)
        return item
    }

    /// Puts a dropped message back in the queue as new (its 30 minutes start again); nil when it is not (or no longer) listed.
    @discardableResult
    func retry(_ id: String, now: Date = Date()) -> Item? {
        guard let entry = undelivered.first(where: { $0.id == id }) else { return nil }
        undelivered.removeAll { $0.id == id }
        return add(entry.item.text, pane: entry.item.pane, project: entry.item.project, now: now)
    }

    func dismiss(_ id: String) { undelivered.removeAll { $0.id == id } }

    /// Takes waiting messages out of the queue (a QUESTION line whose question went back to the user, N380); returns them.
    @discardableResult
    func remove(where drop: (Item) -> Bool) -> [Item] {
        let gone = items.filter(drop)
        items.removeAll(where: drop)
        return gone
    }

    /// Why a message to `pane` never arrived, from what the agents looked like when it was dropped.
    static func reason(forPane pane: String, agents: [AgentStatus]) -> String {
        guard let agent = agents.first(where: { $0.paneID == pane }) else { return "the agent's pane is gone" }
        switch agent.state {
        case .working: return "the agent was busy for 30 minutes"
        case .blocked: return "the agent waited on a question or menu for 30 minutes"
        default: return "the agent could not take it for 30 minutes"
        }
    }

    /// Drops the stale messages (passed to `dropped`), then sends each pane's messages in order while its agent is idle or done.
    /// A failed send stops that pane until the next call, so a later message never goes before an earlier one.
    /// A call that comes while another is sending is skipped (the running one already covers it).
    /// `failed` sees a message whose send threw: true takes it out of the queue (its sender handles it), false keeps it for the next call.
    func deliver(agents: [AgentStatus], now: Date = Date(), send: (Item, AgentStatus) async throws -> Void, dropped: (Item) -> Void,
                 failed: (Item) -> Bool = { _ in false }) async {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        let stale = items.filter { now.timeIntervalSince($0.added) > Self.staleAfter }
        items.removeAll { item in stale.contains { $0.id == item.id } }
        for item in stale {
            undelivered.append(Undelivered(item: item, reason: Self.reason(forPane: item.pane, agents: agents)))
            dropped(item)
        }
        var panes: [String] = []
        for item in items where !panes.contains(item.pane) { panes.append(item.pane) }
        for pane in panes {
            guard pane != typingPane, let agent = agents.first(where: { $0.paneID == pane }), agent.state == .idle || agent.state == .done else { continue }
            while let next = items.first(where: { $0.pane == pane }) {
                do { try await send(next, agent) } catch {
                    guard failed(next) else { break }
                    items.removeAll { $0.id == next.id }
                    continue
                }
                items.removeAll { $0.id == next.id }
            }
        }
    }
}
