import SwiftUI

/// The notes pad: closed, the one-line quick capture box (⌘⇧N), or the full floating pad.
enum NotesPadMode: Equatable {
    case closed, capture, open

    /// The rail's notes icon opens the pad, or closes it when it is open.
    func railTapped() -> NotesPadMode { self == .open ? .closed : .open }
    /// ⌘⇧N: the quick capture box first, the full pad when pressed again.
    func shortcut() -> NotesPadMode { self == .closed ? .capture : .open }
    /// Return in the quick capture box: adds the line and closes; an empty box stays open.
    @MainActor func captured(_ text: String, into notes: NotesModel) -> NotesPadMode {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        notes.add(text)
        return .closed
    }
}

/// The rail's notes icon: at the bottom of the rail, apart from the screens, with the selected project's open lines as a count.
struct RailNotes {
    var open: Int
    var active: Bool
    var onTap: () -> Void
}

struct RailNotesButton: View {
    let notes: RailNotes
    @State private var hovering = false

    var body: some View {
        Button(action: notes.onTap) {
            Image(systemName: "note.text").font(.system(size: 17)).foregroundStyle(notes.active || hovering ? Tok.ink : Tok.ink3)
                .frame(maxWidth: .infinity, minHeight: ClickTargets.railItem.height, maxHeight: ClickTargets.railItem.height)
                .background(notes.active ? Tok.raise : (hovering ? Tok.raise.opacity(0.5) : .clear), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if notes.open > 0 {
                        Text("\(notes.open)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.ink2)
                            .padding(.horizontal, Tok.Space.xs).frame(minWidth: 16, minHeight: 16)
                            .background(Tok.line, in: Capsule())
                            .padding(Tok.Space.xs / 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, (ClickTargets.railWidth - ClickTargets.railItem.width) / 2 + 4)
        .onHover { hovering = $0 }
        .help("Notes (⌘⇧N)")
        .accessibilityLabel(notes.open > 0 ? "Notes, \(notes.open) open" : "Notes")
    }
}

/// What a line's right-click menu can do; nil hides or disables the item.
struct NoteActions {
    /// Nil: the pad shows another project than the selected one (New task writes into the selected project).
    var makeTask: ((String) -> Void)?
    /// Nil: the project has no PM.
    var sendToPM: ((String) -> Void)?
}

/// The pad over the window: the pad or the quick capture box, the ⌘⇧N key, and reloading the notes when their file changes.
struct NotesOverlay: View {
    let model: PanelModel
    let book: NotesBook
    @Binding var mode: NotesPadMode
    /// The line the ⌘K field opened the pad at (N134); cleared when the pad closes.
    @Binding var highlight: UUID?
    /// "Make a task…" on a line of the selected project.
    let onMakeTask: (String) -> Void
    @State private var place: NotesPadPlace
    @State private var drag = CGSize.zero
    /// The project the pad shows when the user picked another one in its header (nil: the selected project).
    @State private var padProjectID: String?
    @Environment(\.snapshotMode) private var snapshot

    init(model: PanelModel, book: NotesBook, mode: Binding<NotesPadMode>, highlight: Binding<UUID?> = .constant(nil), onMakeTask: @escaping (String) -> Void) {
        self.model = model; self.book = book; _mode = mode; _highlight = highlight; self.onMakeTask = onMakeTask
        _place = State(initialValue: NotesPadPlace.load(model.defaults))
    }

    private var padProject: ProjectConfig? { model.projects.first { $0.id == padProjectID } ?? model.selectedProject }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if mode == .open, let project = padProject { pad(project, in: geo.size) }
                if mode == .capture, let project = model.selectedProject {
                    QuickCapture(projectName: project.name, onAdd: { mode = mode.captured($0, into: book.notes(dataDir: project.dataURL)) },
                                 onClose: { mode = .closed })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, NotesPadPlace.home.left - 4).padding(.bottom, NotesPadPlace.home.bottom - 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Button("") { if model.selectedProject != nil { mode = mode.shortcut() } }
            .keyboardShortcut("n", modifiers: [.command, .shift]).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
        .task(id: [model.selectedProject?.dataDir, padProject?.dataDir]) { await follow() }
        // A found note is in the selected project's notes, so the pad shows them.
        .onChange(of: highlight) { _, line in if line != nil { padProjectID = nil } }
        .onChange(of: mode) { _, now in if now == .closed { highlight = nil } }
    }

    private func pad(_ project: ProjectConfig, in bounds: CGSize) -> some View {
        var shown = place
        shown.move(by: drag, in: bounds)
        let origin = shown.origin(in: bounds)
        let pane = model.pmPane(forProject: project.id)
        let actions = NoteActions(makeTask: project.id == model.selectedProjectID ? onMakeTask : nil,
                                  sendToPM: pane.map { pane in { text in Task { await model.tellPM(pane: pane, "Note: \(text)") } } })
        return NotesPad(notes: book.notes(dataDir: project.dataURL), projectName: project.name,
                        projects: model.projects.map { ($0.id, $0.name) }, onPickProject: { padProjectID = $0 == model.selectedProjectID ? nil : $0 },
                        big: place.big, onToggleBig: { place.big.toggle(); place.save(model.defaults) }, onClose: { mode = .closed }, actions: actions,
                        onDrag: { drag = $0 }, onDragEnd: { place.move(by: $0, in: bounds); drag = .zero; place.save(model.defaults) },
                        highlight: project.id == model.selectedProjectID ? highlight : nil)
            .frame(width: shown.size.width, height: shown.size.height)
            .offset(x: origin.x, y: origin.y)
    }

    /// Reads the shown notes again when their file changed on disk (the user or the PM edited it).
    private func follow() async {
        if snapshot { return }
        while !Task.isCancelled {
            for project in [model.selectedProject, padProject].compactMap({ $0 }) { book.notes(dataDir: project.dataURL).reloadIfChanged() }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// The pad drawn on its own, for snapshots: the window's background with the pad or the quick capture box where the window puts it.
struct NotesPadPreview: View {
    let notes: NotesModel
    let projectName: String
    let mode: NotesPadMode
    let place: NotesPadPlace

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Tok.bg
                if mode == .open {
                    let origin = place.origin(in: geo.size)
                    NotesPad(notes: notes, projectName: projectName, projects: [], onPickProject: { _ in }, big: place.big, onToggleBig: {}, onClose: {},
                             actions: NoteActions(makeTask: { _ in }, sendToPM: nil), onDrag: { _ in }, onDragEnd: { _ in })
                        .frame(width: place.size.width, height: place.size.height)
                        .offset(x: origin.x, y: origin.y)
                }
                if mode == .capture {
                    QuickCapture(projectName: projectName, onAdd: { _ in }, onClose: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, NotesPadPlace.home.left - 4).padding(.bottom, NotesPadPlace.home.bottom - 4)
                }
            }
        }
    }
}

/// The floating pad: one running page of the project's notes, grouped by day, newest first.
struct NotesPad: View {
    let notes: NotesModel
    let projectName: String
    let projects: [(id: String, name: String)]
    let onPickProject: (String) -> Void
    let big: Bool
    let onToggleBig: () -> Void
    let onClose: () -> Void
    let actions: NoteActions
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize) -> Void
    /// A line to scroll to and mark (opened from the ⌘K field).
    var highlight: UUID?
    @State private var draft = ""
    @State private var editing: UUID?
    @State private var editText = ""
    /// Bumped when an edit ends, so the focus goes back to the add box.
    @State private var addFocus = 0
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tok.line)
            lines
            Divider().overlay(Tok.line)
            footer
        }
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius + 2).stroke(Tok.line))
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius + 2))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.5)), radius: 25, y: 18)
        .escapeCancels(cancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes")
    }

    private var header: some View {
        HStack(spacing: Tok.Space.xs) {
            Text("Notes").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            MenuBox {
                ForEach(projects, id: \.id) { project in Button(project.name) { onPickProject(project.id) } }
            } label: {
                Text("· \(projectName) ⌄").font(Tok.Font.body).foregroundStyle(Tok.ink3).lineLimit(1)
            }
            .fixedSize()
            .accessibilityLabel("Project of these notes")
            Spacer(minLength: Tok.Space.s)
            iconButton(big ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: big ? "Make the pad smaller" : "Make the pad bigger", action: onToggleBig)
            iconButton("xmark", label: "Close notes (Esc)", action: onClose)
        }
        .padding(.leading, Tok.Space.m + 2).padding(.trailing, Tok.Space.s + 2).padding(.vertical, Tok.Space.s + 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global).onChanged { onDrag($0.translation) }.onEnded { onDragEnd($0.translation) })
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink3)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
        Scroller {
            VStack(alignment: .leading, spacing: Tok.Space.xs) {
                if notes.groups.isEmpty && notes.foldedCount == 0 { empty }
                ForEach(notes.groups) { group in
                    Text(group.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Tok.ink3)
                        .padding(.top, Tok.Space.s).padding(.bottom, Tok.Space.xs)
                    ForEach(group.lines) { row($0) }
                }
                if notes.foldedCount > 0 {
                    Button(notes.showDone ? "Hide done" : "Show done (\(notes.foldedCount))") { notes.showDone.toggle() }
                        .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).padding(.top, Tok.Space.s)
                }
            }
            .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if let highlight { proxy.scrollTo(highlight, anchor: .center) } }
        .onChange(of: highlight) { _, line in if let line { withAnimation { proxy.scrollTo(line, anchor: .center) } } }
        }
        .frame(maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: Tok.Space.s) {
            Image(systemName: "note.text").font(.system(size: 24)).foregroundStyle(Tok.ink3)
            Text("No notes in \(projectName) yet.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
            Text("Ideas that come up while agents work go here. A note can become a task card later.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).multilineTextAlignment(.center).frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    @ViewBuilder private func row(_ line: NoteLine) -> some View {
        let content = HStack(alignment: .top, spacing: Tok.Space.s + 2) {
            if line.raw {
                Text(line.text).font(Tok.Font.body).foregroundStyle(Tok.ink2).frame(maxWidth: .infinity, alignment: .leading)
                    .help("This line is not a note line (- [ ] text); it is kept as written.")
            } else {
                checkbox(line)
                if editing == line.id && !snapshot {
                    NoteField(text: $editText, identifier: NoteField.editIdentifier, takesFocus: .always,
                              onSubmit: { notes.edit(line.id, to: editText); endEdit() }, onCancel: cancel)
                } else {
                    Text(line.text).font(Tok.Font.body).lineSpacing(2)
                        .foregroundStyle(line.done ? Tok.ink3 : Tok.ink).strikethrough(line.done, color: Tok.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let task = line.task {
                    Text("→ \(task)").font(Tok.Font.small).foregroundStyle(Tok.go)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Tok.bg, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(.vertical, Tok.Space.xs)
        .background(line.id == highlight ? Tok.work.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6).inset(by: -Tok.Space.xs))
        .contentShape(Rectangle())
        .id(line.id)
        if snapshot { content } else { content.contextMenu { menu(line) } }
    }

    private func checkbox(_ line: NoteLine) -> some View {
        Button { notes.toggle(line.id) } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(line.done ? Tok.go : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(line.done ? Tok.go : Tok.ink3, lineWidth: 1.5))
                .overlay { if line.done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Tok.bg) } }
                .frame(width: 16, height: 16).padding(.top, 1)
                // The open box is filled with .clear, which takes no clicks: without this only its outline did.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.done ? "Mark as not done" : "Mark as done")
    }

    @ViewBuilder private func menu(_ line: NoteLine) -> some View {
        if !line.raw { Button("Edit") { editText = line.text; editing = line.id } }
        Button("Make a task…") { actions.makeTask?(line.text) }.disabled(actions.makeTask == nil)
            .help(actions.makeTask == nil ? "Select this project first: a new task is made in the selected project." : "")
        Button("Send to the PM") { actions.sendToPM?(line.text) }.disabled(actions.sendToPM == nil)
            .help(actions.sendToPM == nil ? "This project has no PM session." : "Sends \"Note: \(line.text)\" to the PM")
        Divider()
        Button("Delete", role: .destructive) { notes.delete(line.id) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(alignment: .bottom, spacing: Tok.Space.s) {
                LineField(placeholder: "Add a line… ↵", text: $draft, takesFocus: .unlessEditing, focusRequest: addFocus, onSubmit: add, onCancel: cancel)
                Button("Add", action: add).buttonStyle(.plain).font(Tok.Font.body).foregroundStyle(Tok.ink)
                    .padding(.horizontal, Tok.Space.m).frame(height: 30)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            }
            if let error = notes.saveError {
                Text("\(notes.openCount) open · not saved: \(error)").font(Tok.Font.small).foregroundStyle(Tok.stop).lineLimit(2)
            } else {
                Text("\(notes.openCount) open · saved").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
        .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 2)
    }

    private func add() {
        notes.add(draft)
        draft = ""
    }

    private func endEdit() {
        editing = nil
        addFocus += 1
    }

    /// Esc: ends an edit, or closes the pad.
    private func cancel() { if editing != nil { endEdit() } else { onClose() } }
}

/// ⌘⇧N with the pad closed: one note box above the rail's notes icon.
struct QuickCapture: View {
    let projectName: String
    let onAdd: (String) -> Void
    let onClose: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LineField(placeholder: "Add a line… ↵", text: $text, highlighted: true, onSubmit: { onAdd(text); text = "" }, onCancel: onClose)
            Text("↵ add to \(projectName) · ⇧↵ new line · Esc close · ⌘⇧N open the pad").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tok.Space.s + 2)
        .frame(width: 300)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius + 2).stroke(Tok.line))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.5)), radius: 15, y: 12)
        .escapeCancels(onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick note")
    }
}

/// The pad's note box: a `NoteField` in a rounded box, growing to five lines; drawn as a static box in snapshots (ImageRenderer cannot draw
/// an AppKit text view).
private struct LineField: View {
    let placeholder: String
    @Binding var text: String
    var takesFocus = NoteField.TakeFocus.always
    var focusRequest = 0
    var highlighted = false
    let onSubmit: () -> Void
    var onCancel: (() -> Void)?
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Group {
            if snapshot {
                Text(text.isEmpty ? placeholder : text).foregroundStyle(text.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                NoteField(text: $text, identifier: NoteField.addIdentifier, takesFocus: takesFocus, focusRequest: focusRequest, onSubmit: onSubmit, onCancel: onCancel)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text(placeholder).foregroundStyle(Tok.ink3).allowsHitTesting(false) }
                    }
            }
        }
        .font(Tok.Font.body)
        .padding(.horizontal, Tok.Space.s + 2).padding(.vertical, 7).frame(minHeight: 30)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlighted ? Tok.work : Tok.line))
        .accessibilityLabel("Add a line")
    }
}
