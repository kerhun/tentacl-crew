import Foundation

/// The one fixed prompt the PM gets after a project is added: inspect, write the summary, the first cards and the first round.
/// Built from the probe facts; pure, so it is tested without a PM.
enum OnboardingPrompt {
    static func build(name: String, repoPath: String, dataDir: String, probe: ProjectProbe, runBuildAndTest: Bool) -> String {
        var facts: [String] = ["Project \"\(name)\", repository \(repoPath), data folder \(dataDir)."]
        if probe.facts.isGitRepo {
            let branch = probe.facts.branch.map { "branch \($0), " } ?? ""
            facts.append("Git: \(branch)\(probe.commitCount) commits, remote \(probe.remote ?? "none"), \(probe.dirtyFiles) changed files, \(probe.unpushedCommits.map { "\($0) unpushed commits" } ?? "no upstream").")
        } else {
            facts.append("The folder is not a git repository.")
        }
        facts.append("\(probe.fileCount) files; ecosystems: \(probe.ecosystems.isEmpty ? "unknown" : probe.ecosystems.map(\.rawValue).joined(separator: ", ")).")
        facts.append("Build command: \(probe.buildCommand ?? "none found"). Test command: \(probe.testCommand ?? "none found").")
        if !probe.agentDocs.isEmpty { facts.append("Agent docs: \(probe.agentDocs.map(\.name).joined(separator: ", ")).") }
        if !probe.ciWorkflows.isEmpty { facts.append("CI workflows: \(probe.ciWorkflows.joined(separator: ", ")).") }

        let commands = runBuildAndTest
            ? "Check the build and test commands by running them read-only (no installs, no pushes, no file changes outside build output) and keep only the last 30 lines of each output."
            : "Do not run the build or test commands; judge them from the files."
        var steps = [
            "1. Look through the project. Do not change any code.",
            "2. Write \(dataDir)/summary.md: the structure, how to build and test, the risks, and a short summary of CLAUDE.md/AGENTS.md. \(commands)",
            "3. Write the first cards in \(dataDir)/tasks/ (each with `status: todo` and `from: pm`) and \(dataDir)/plan.json with round 1 `status: \"waiting\"`. Nothing starts until the user approves the round.",
            "4. Put every question for the user in `questions` in plan.json. If the commands you found differ from the ones above, or none were found, ask there; do not edit project.json.",
        ]
        if probe.fileCount == 0 { steps.append("5. The project is empty: if \(dataDir)/goal.md is empty, ask the user for the goal in `questions`.") }
        return (["Onboarding for a new project.", ""] + facts + ["", "Do this:"] + steps).joined(separator: "\n")
    }
}
