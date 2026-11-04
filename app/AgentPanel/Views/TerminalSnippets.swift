import SwiftUI

/// The Saved commands list (N272): the project's commands and the global ones. A click or ↩ sends to the focused pane; ⌘1…⌘9 take the first
/// nine of the shown list. Nothing is sent without the user's click.
struct TerminalSnippetsPanel: View {
    let store: TerminalSnippetStore
    let project: String?
    /// The ⌘L box's text, offered as "Save the prompt box text".
    let promptText: String
    let canSend: Bool
    let onSend: (TerminalSnippet) -> Void

    @State private var scope: TerminalSnippetScope
    @State private var items: [TerminalSnippet] = []
    @State private var selection: UUID?
    @State private var editing: TerminalSnippet?
    @State private var isNew = false
    @State private var deleting: TerminalSnippet?
    @Environment(\.snapshotMode) private var snapshot

    init(store: TerminalSnippetStore, project: String?, promptText: String, canSend: Bool, scope: TerminalSnippetScope? = nil, onSend: @escaping (TerminalSnippet) -> Void) {
        self.store = store; self.project = project; self.promptText = promptText; self.canSend = canSend; self.onSend = onSend
        _scope = State(initialValue: scope ?? project.map { .project($0) } ?? .global)
    }

    private var scopes: [(String, TerminalSnippetScope)] { (project.map { [("Project", TerminalSnippetScope.project($0))] } ?? []) + [("Global", .global)] }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack {
                Text("Saved commands").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
                Spacer()
                ForEach(scopes, id: \.0) { name, value in
                    Button { scope = value } label: {
                        Text(name).font(.system(size: 11, weight: scope == value ? .semibold : .regular)).foregroundStyle(Tok.ink)
                            .padding(.horizontal, Tok.Space.s).frame(height: 24)
                            .background(scope == value ? Tok.youFill : Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(scope == value ? Tok.you : Tok.line)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }
            if let editing { editor(editing) } else { list }
        }
        .padding(Tok.Space.m).frame(width: 380)
        .onAppear(perform: reload)
        .onChange(of: scope) { _, _ in reload(); editing = nil }
        .confirmationDialog("Delete this command?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button("Delete \(item.name)", role: .destructive) { store.delete(item.id, from: scope); reload() }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Saved commands")
    }

    private func reload() { items = store.load(scope) }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("Nothing saved yet.").font(Tok.Font.small).foregroundStyle(Tok.ink2).padding(.vertical, Tok.Space.s)
            }
            Group { ForEach(Array(items.enumerated()), id: \.element.id) { index, item in row(item, index: index) } }
                .focusable()
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.return) {
                    guard canSend, let item = items.first(where: { $0.id == selection }) else { return .ignored }
                    onSend(item); return .handled
                }
            HStack(spacing: Tok.Space.s) {
                small("New command") { editing = TerminalSnippet(name: "", text: ""); isNew = true }
                if !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    small("Save prompt box text") { editing = TerminalSnippet(name: "", text: promptText); isNew = true }
                }
                small("Save clipboard") { editing = TerminalSnippet(name: "", text: snapshot ? "" : NSPasteboard.general.string(forType: .string) ?? ""); isNew = true }
                    .help("Select text in a terminal, copy it (⌘C), then save it as a command")
            }.padding(.top, Tok.Space.s)
        }
    }

    private func row(_ item: TerminalSnippet, index: Int) -> some View {
        HStack(spacing: Tok.Space.s) {
            Button { onSend(item) } label: {
                HStack(spacing: 6) {
                    Text(index < 9 ? "⌘\(index + 1)" : "").font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 26, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink).lineLimit(1)
                        Text(item.text + (item.runAtOnce ? "  ↩" : "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canSend).opacity(canSend ? 1 : 0.5)
            .background(index < 9 ? Button("") { if canSend { onSend(item) } }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command).opacity(0).accessibilityHidden(true) : nil)
            .help(canSend ? "Send to the focused pane" : "No pane to send to")
            .accessibilityLabel("Send \(item.name)")
            Button { move(item, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move up")
            Button { move(item, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == items.count - 1).help("Move down")
            Button { editing = item; isNew = false } label: { Image(systemName: "pencil") }.help("Edit")
            Button { deleting = item } label: { Image(systemName: "trash") }.help("Delete")
        }
        .buttonStyle(.plain).foregroundStyle(Tok.ink2).font(.system(size: 11))
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(selection == item.id ? Tok.youFill : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func step(_ by: Int) {
        let i = items.firstIndex { $0.id == selection }.map { $0 + by } ?? (by > 0 ? 0 : items.count - 1)
        if items.indices.contains(i) { selection = items[i].id }
    }

    private func move(_ item: TerminalSnippet, _ step: Int) { store.move(item.id, by: step, in: scope); reload() }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(Tok.ink).padding(.horizontal, Tok.Space.s).frame(height: 24)
                .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func editor(_ item: TerminalSnippet) -> some View {
        let bind = Binding(get: { editing ?? item }, set: { editing = $0 })
        let valid = !bind.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Tok.Space.s) {
            TextField("Name", text: bind.name).textFieldStyle(.roundedBorder)
            TextField("Command", text: bind.text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5).font(.system(size: 12, design: .monospaced))
            Toggle("Run at once (adds Return)", isOn: bind.runAtOnce).font(Tok.Font.small)
            HStack {
                Spacer()
                small("Cancel") { editing = nil }
                small("Save") {
                    let v = bind.wrappedValue
                    if isNew { store.add(name: v.name, text: v.text, runAtOnce: v.runAtOnce, to: scope) } else { store.update(v, in: scope) }
                    editing = nil; reload()
                }.disabled(!valid).opacity(valid ? 1 : 0.5)
            }
        }
    }
}
