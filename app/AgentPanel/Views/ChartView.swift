import SwiftUI

/// The team chart of the project as a tree: you at the top, each role under the one it reports to. Click a role to see and change it in
/// the side panel; drag a role onto another to make it report to that one. Nothing is written until Save.
struct ChartView: View {
    @Bindable var model: TeamChartModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Scroller {
                VStack(alignment: .leading, spacing: Tok.Space.l + 2) {
                    header
                    if model.hasChart { refusal; treeBox; notInChart } else { empty }
                    if !model.hasChart { problemsView }
                }
                .padding(Tok.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if model.hasChart {
                Rectangle().fill(Tok.line).frame(width: 1)
                ChartSidePanel(model: model).frame(width: 340)
            }
        }
        .background(Tok.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Team chart" + (model.project.map { " · \($0.name)" } ?? "")).font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text("A role gives tasks only to the roles below it and reports to the one above. Drag a role onto another to change who it reports to.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            if model.project == nil {
                Text("Select a project to see its team chart.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            } else {
                if !model.fileProblems.isEmpty {
                    Text("This project's team.json cannot be used, so no task can be started until it is fixed or replaced:").font(Tok.Font.body).foregroundStyle(Tok.stop)
                    ForEach(Array(model.fileProblems.enumerated()), id: \.offset) { _, p in Text("· " + p.message).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
                } else {
                    Text("This project has no team chart yet. Without one, nothing is checked and agents get no team text.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
                }
                Button(model.fileProblems.isEmpty ? "Create the default chart" : "Start a new chart") { model.createDefaultChart() }
                    .buttonStyle(ConfirmButtonStyle())
                Text("The default chart is pm → reviewer → dev and ui_dev, using the roles that exist. You can change it before saving.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
    }

    @ViewBuilder private var refusal: some View {
        if let reason = model.dropRefusal {
            HStack(spacing: Tok.Space.s) {
                Image(systemName: "nosign").foregroundStyle(Tok.stop)
                Text(reason).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Tok.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.stop.opacity(0.1), in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.stop.opacity(0.4)))
            .accessibilityLabel("Drop refused: \(reason)")
        }
    }

    private var treeBox: some View {
        let roots = model.tree
        return Scroller(axes: .horizontal) {
            VStack(spacing: 0) {
                ChartYouNode(model: model)
                if !roots.isEmpty {
                    ChartLine(height: 28)
                    ChartChildren(nodes: roots, model: model)
                }
            }
            .padding(.vertical, 32).padding(.horizontal, Tok.Space.xl)
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .top)
        .background(Tok.pane.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Tok.line))
        .contentShape(Rectangle())
        .onTapGesture { model.select(nil) }
    }

    private var notInChart: some View {
        let others = model.notInChart
        return HStack(alignment: .center, spacing: Tok.Space.m) {
            Text("Not in the chart").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            Text(others.isEmpty ? "Every role is placed. A role left out here can get tasks only from you."
                                : "Until these roles are placed, only you can give them tasks.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ForEach(others, id: \.self) { role in
                HStack(spacing: 6) {
                    Text(model.title(of: role)).font(Tok.Font.body).foregroundStyle(Tok.ink2)
                    Button("Add") { model.add(role) }.buttonStyle(PanelButtonStyle()).accessibilityLabel("Add \(role) to the chart")
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
                .background(Tok.raise, in: Capsule())
            }
        }
        .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.m + 2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .contain).accessibilityLabel("Not in the chart")
    }

    @ViewBuilder private var problemsView: some View {
        if !model.problems.isEmpty || model.saveError != nil { ChartProblems(model: model) }
    }
}

// MARK: tree

/// A connector line of the tree.
private struct ChartLine: View {
    var height: CGFloat
    var body: some View { Rectangle().fill(Tok.line).frame(width: 2, height: height).accessibilityHidden(true) }
}

/// A row of sibling branches joined by one horizontal line from the first one's center to the last one's.
private struct ChartChildren: View {
    let nodes: [ChartNode]
    let model: TeamChartModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { i, node in
                VStack(spacing: 0) {
                    if nodes.count > 1 {
                        HStack(spacing: 0) {
                            Rectangle().fill(i == 0 ? Color.clear : Tok.line).frame(height: 2)
                            Rectangle().fill(i == nodes.count - 1 ? Color.clear : Tok.line).frame(height: 2)
                        }
                        .accessibilityHidden(true)
                        ChartLine(height: 22)
                    }
                    AnyView(ChartBranch(node: node, model: model)).padding(.horizontal, 15)
                }
                .fixedSize()
            }
        }
    }
}

private struct ChartBranch: View {
    let node: ChartNode
    let model: TeamChartModel

    var body: some View {
        VStack(spacing: 0) {
            ChartTile(node: node, model: model)
            if !node.children.isEmpty {
                ChartLine(height: 24)
                ChartChildren(nodes: node.children, model: model)
            }
        }
    }
}

/// A role's tile colour, picked from its name so it stays the same between launches.
func chartTint(_ role: String) -> Color {
    let tints = [Tok.wait, Tok.work, Tok.go, Tok.ink2]
    return tints[role.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tints.count]
}

struct ChartInitialTile: View {
    let node: ChartNode
    var size: CGFloat = 32
    var body: some View {
        Text(node.initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Tok.bg)
            .frame(width: size, height: size)
            .background(node.isMissingRole ? Tok.ink3 : chartTint(node.role), in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

private struct ChartTile: View {
    let node: ChartNode
    let model: TeamChartModel
    @State private var targeted = false

    private var isSelected: Bool { model.selected == node.role }

    var body: some View {
        HStack(spacing: 10) {
            ChartInitialTile(node: node)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
                Text(node.subtitle).font(Tok.Font.small).foregroundStyle(node.isMissingRole ? Tok.wait : Tok.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !model.warnings(for: node.role).isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Tok.wait).accessibilityLabel("has a warning")
            }
            if node.running > 0 { Circle().fill(Tok.work).frame(width: 8, height: 8).accessibilityLabel("running") }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 240)
        .background(isSelected ? Tok.work.opacity(0.14) : Tok.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected || targeted ? Tok.work : Tok.line,
                                                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: targeted && !isSelected ? [5, 3] : [])))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.select(node.role) }
        .modifier(ChartDragDrop(drag: node, target: node.role, model: model, targeted: $targeted))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title), \(node.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Drag a tile, drop on a tile (or on You: `target` nil). Left out in snapshots, which cannot draw the drag and drop views.
private struct ChartDragDrop: ViewModifier {
    let drag: ChartNode?
    let target: String?
    let model: TeamChartModel
    @Binding var targeted: Bool
    @Environment(\.snapshotMode) private var snapshot

    func body(content: Content) -> some View {
        if snapshot { content }
        else if let drag { dropping(content.draggable(drag.role) { ChartInitialTile(node: drag, size: 40) }) }
        else { dropping(content) }
    }

    private func dropping(_ view: some View) -> some View {
        view.dropDestination(for: String.self) { items, _ in
            guard let role = items.first else { return false }
            return model.drop(role, onto: target) == nil
        } isTargeted: { targeted = $0 }
    }
}

/// "You" at the top; dropping a role here makes it report to you.
private struct ChartYouNode: View {
    let model: TeamChartModel
    @State private var targeted = false

    var body: some View {
        Text("You").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Tok.raise, in: Capsule())
            .overlay(Capsule().stroke(targeted ? Tok.work : Tok.line, style: StrokeStyle(lineWidth: 1, dash: targeted ? [5, 3] : [])))
            .modifier(ChartDragDrop(drag: nil, target: nil, model: model, targeted: $targeted))
            .accessibilityLabel("You, top of the chart")
    }
}

// MARK: side panel

private struct ChartSidePanel: View {
    @Bindable var model: TeamChartModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l + 2) {
            Scroller {
                VStack(alignment: .leading, spacing: Tok.Space.l + 2) {
                    if let role = model.selected, let node = find(role, in: model.tree) { selectedRole(node) } else { nothingSelected }
                    Text(TeamChartModel.runningAgentsNote).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                    if !model.problems.isEmpty || model.saveError != nil { ChartProblems(model: model) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Tok.Space.s + 2) {
                Button("Revert") { model.revert() }.buttonStyle(PanelButtonStyle()).disabled(!model.isDirty).frame(maxWidth: .infinity)
                Button("Save chart") { Task { await model.save() } }.buttonStyle(ConfirmButtonStyle())
                    .disabled(!model.isDirty || model.problems.contains { $0.severity == .error }).frame(maxWidth: .infinity)
            }
        }
        .padding(Tok.Space.xl)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain).accessibilityLabel("Selected role")
    }

    private func find(_ role: String, in nodes: [ChartNode]) -> ChartNode? {
        for n in nodes { if n.role == role { return n }; if let hit = find(role, in: n.children) { return hit } }
        return nil
    }

    private var nothingSelected: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("Click a role to see who it reports to and who it gives tasks to.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.allWarnings.enumerated()), id: \.offset) { _, w in ChartWarningBox(warning: w, model: model, showsRole: true) }
        }
    }

    private func selectedRole(_ node: ChartNode) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.l + 2) {
            HStack(spacing: Tok.Space.m) {
                ChartInitialTile(node: node, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Tok.ink)
                    Text(node.role).font(Tok.Font.mono).foregroundStyle(Tok.ink2)
                }
                Spacer(minLength: 0)
                Button { model.remove(node.role) } label: { Image(systemName: "minus.circle").foregroundStyle(Tok.ink3) }
                    .buttonStyle(.plain).help("Take \(node.role) out of the chart").accessibilityLabel("Take \(node.role) out of the chart")
            }
            field("Reports to") { managerMenu(node.role) }
            field("Gives tasks to") {
                let below = model.draft?.descendants(of: node.role) ?? []
                if below.isEmpty { Text("nobody").font(Tok.Font.body).foregroundStyle(Tok.ink3) } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(below, id: \.self) { role in
                            let title = model.title(of: role)
                            Text(title == role ? role : "\(title) · \(role)").font(Tok.Font.body).foregroundStyle(Tok.ink)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Tok.raise, in: Capsule()).overlay(Capsule().stroke(Tok.line))
                        }
                    }
                }
            }
            field("Its reports go to") { Text(model.reportsGoTo(node.role)).font(Tok.Font.body).foregroundStyle(Tok.ink) }
            ForEach(Array(model.warnings(for: node.role).enumerated()), id: \.offset) { _, w in ChartWarningBox(warning: w, model: model, showsRole: false) }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            content()
        }
    }

    private func label(_ role: String?) -> String {
        guard let role else { return "You" }
        let title = model.title(of: role)
        return title == role ? role : "\(title) (\(role))"
    }

    private func managerMenu(_ role: String) -> some View {
        let boss = model.draft?.manager(of: role)
        return MenuBox {
            Button("You") { model.drop(role, onto: nil) }
            ForEach(model.availableManagers(for: role), id: \.self) { b in Button(label(b)) { model.drop(role, onto: b) } }
        } label: {
            HStack {
                Text(label(boss)).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Tok.ink3)
            }
            .padding(.horizontal, Tok.Space.m).padding(.vertical, 8)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("\(role) reports to \(boss ?? "you")")
    }
}

private struct ChartWarningBox: View {
    let warning: ChartWarning
    let model: TeamChartModel
    let showsRole: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(showsRole ? "\(warning.role): \(warning.title)" : warning.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.wait)
            Text(warning.message).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            if let fix = warning.fix, let label = warning.fixLabel {
                Button(label) { model.apply(fix) }.buttonStyle(PanelButtonStyle()).padding(.top, 4)
            }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.wait.opacity(0.08), in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.wait.opacity(0.35)))
        .onTapGesture { if showsRole { model.select(warning.role) } }
    }
}

private struct ChartProblems: View {
    let model: TeamChartModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.problems.enumerated()), id: \.offset) { _, p in Text(p.message).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
            if let e = model.saveError { Text(e).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
