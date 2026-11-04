import SwiftUI

/// "Reorder projects…" in the project switcher: the projects in their order. A row is dragged onto another to take its place;
/// its context menu has Move up / Move down (the keyboard and VoiceOver path). The order is written to `projects.json`.
struct ProjectOrderList: View {
    let model: PanelModel
    /// The row a drag is over (set from outside only for the snapshot).
    @State private var target: String?
    @Environment(\.snapshotMode) private var snapshot

    init(model: PanelModel, target: String? = nil) {
        self.model = model
        _target = State(initialValue: target)
    }

    struct MenuItem {
        let title: String
        let enabled: Bool
        let action: () -> Void
    }

    /// The row's context menu: Move up, Move down (off at the ends of the list).
    func menu(for id: String) -> [MenuItem] {
        let index = model.projects.firstIndex { $0.id == id } ?? 0
        return [MenuItem(title: "Move up", enabled: index > 0, action: { model.moveProject(id, to: index - 1) }),
                MenuItem(title: "Move down", enabled: index < model.projects.count - 1, action: { model.moveProject(id, to: index + 1) })]
    }

    /// A dragged project dropped on `target`'s row takes that row's place. False for anything that is not a project on the list.
    @discardableResult
    func drop(_ ids: [String], on target: String) -> Bool {
        guard let id = ids.first, id != target, model.projects.contains(where: { $0.id == id }),
              let index = model.projects.firstIndex(where: { $0.id == target }) else { return false }
        model.moveProject(id, to: index)
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            Text("Drag a project to change the order").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                .padding(.horizontal, Tok.Space.xs).padding(.bottom, Tok.Space.xs)
            ForEach(model.projects) { project in row(project) }
        }
        .padding(Tok.Space.m)
        .frame(width: 280, alignment: .leading)
        .background(Tok.pane)
    }

    private func row(_ project: ProjectConfig) -> some View {
        let over = target == project.id
        return HStack(spacing: Tok.Space.s) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Tok.ink3)
            Text(project.name).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
            Spacer(minLength: 0)
            if project.id == model.selectedProjectID { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink2) }
        }
        .padding(.horizontal, Tok.Space.s).frame(height: 32)
        .background(over ? Tok.work.opacity(0.18) : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(over ? Tok.work : Tok.line, lineWidth: over ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .modifier(RowInteractions(list: self, project: project, target: $target, live: !snapshot))
    }
}

/// Drag, drop and the context menu: AppKit underneath, so a snapshot leaves them out (ImageRenderer draws them as a placeholder, N117).
private struct RowInteractions: ViewModifier {
    let list: ProjectOrderList
    let project: ProjectConfig
    @Binding var target: String?
    let live: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if live { interactive(content) } else { content }
    }

    private func interactive(_ content: Content) -> some View {
        content
            .draggable(project.id) { Text(project.name).font(Tok.Font.bodyStrong).padding(Tok.Space.s) }
            .dropDestination(for: String.self) { ids, _ in
                target = nil
                return list.drop(ids, on: project.id)
            } isTargeted: { inside in
                if inside { target = project.id } else if target == project.id { target = nil }
            }
            .contextMenu {
                ForEach(list.menu(for: project.id), id: \.title) { item in Button(item.title, action: item.action).disabled(!item.enabled) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityActions {
                ForEach(list.menu(for: project.id).filter(\.enabled), id: \.title) { item in Button(item.title, action: item.action) }
            }
    }
}
