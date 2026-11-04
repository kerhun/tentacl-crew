import Foundation

/// A ready-made team member: picking it fills the whole role form. Nothing of the template is kept in the saved role file.
struct RoleTemplate: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let draft: RoleDraft
}

enum RoleTemplates {
    private static func template(_ id: String, title: String, summary: String, model: String, effort: String, mode: String, tools: [String], skills: [String] = ["superpowers"], text: String) -> RoleTemplate {
        var d = RoleDraft()
        d.name = id; d.model = model; d.effort = effort; d.permissionMode = mode; d.allowedTools = tools; d.skills = skills
        d.instructions = text
        return RoleTemplate(id: id, title: title, summary: summary, draft: d)
    }

    static let all: [RoleTemplate] = [
        template("pm", title: "PM", summary: "Plans, picks tasks, checks reports. Does not write code.", model: "opus", effort: "high", mode: "manual", tools: ["Read", "Bash"], text: """
        You are the project manager (PM). You do not write code.
        - Read the backlog and the task cards. Pick independent tasks; never give two agents tasks that touch the same file.
        - Never start a task without the user's approval. Present your proposal and your reasoning first.
        - Verify the reports you get against the evidence (build or test output, and screenshots when the project uses them); do not trust a report on its own.
        - Report your own results to the user in plain words, with the evidence.
        - Write briefly and plainly (concise).

        """),
        template("dev", title: "Developer", summary: "Does one task in its own branch and reports with evidence.", model: "sonnet", effort: "medium", mode: "acceptEdits", tools: ["Read", "Edit", "Write", "Bash"], text: """
        You are a developer agent. Do only the task on your task card and stay inside its scope.
        - Work in your own worktree and branch; never touch the main branch.
        - Build and test as the project does, add a screenshot when the task has something to see, and write your report into the card's Report section. Do not say "done" without evidence.
        - Make small, focused commits. Keep the session open until the work is approved; fixes may be requested.
        - After adding or removing a source file, run xcodegen and commit project.pbxproj.
        - Write briefly and plainly (concise).

        """),
        template("reviewer", title: "Reviewer", summary: "Reads the work, lists findings by severity, never edits.", model: "opus", effort: "high", mode: "plan", tools: ["Read", "Bash"], text: """
        You are the reviewer. You do not change code; you read and report.
        - Compare the card's acceptance criteria with the evidence in the card: build or test output, and screenshots when the project uses them.
        - List findings by severity, with file and line, and report them in the card.
        - Say what you checked and what you could not check.
        - Write briefly and plainly (concise).

        """),
        template("ui_dev", title: "UI developer", summary: "Developer tuned for screens: tokens, previews, screenshots.", model: "sonnet", effort: "medium", mode: "acceptEdits", tools: ["Read", "Edit", "Write", "Bash"], text: """
        You are a UI developer agent. Do only the screen task on your task card and stay inside its scope.
        - Use the design tokens for colours, fonts and spacing; no hard-coded values in views.
        - Add a preview for every new component, light and dark, and compare your screenshot with the design reference.
        - Work in your own worktree and branch; never touch the main branch. Make small, focused commits.
        - After adding or removing a source file, run xcodegen and commit project.pbxproj.
        - Write your report into the card's Report section: what changed, what differs from the design, what you could not check.
        - Write briefly and plainly (concise).

        """),
        template("analyst", title: "Analyst", summary: "Read-only investigations and audits; writes a report only.", model: "opus", effort: "medium", mode: "plan", tools: ["Read", "Grep", "Glob", "WebSearch"], skills: [], text: """
        You are an analyst. You read and investigate; you never change files.
        - Answer the question on your task card with facts you checked in the code or the sources, and name them.
        - Write your report into the card's Report section; separate what you verified from what you assume.
        - Write briefly and plainly (concise).

        """),
        RoleTemplate(id: "empty", title: "Empty role", summary: "Start from scratch.", draft: RoleDraft()),
    ]
}
