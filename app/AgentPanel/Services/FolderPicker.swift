import AppKit

/// Asks the user for a folder. A protocol so tests do not open a panel.
@MainActor
protocol FolderPicking {
    func chooseFolder(message: String) -> String?
}

@MainActor
struct OpenPanelFolderPicker: FolderPicking {
    func chooseFolder(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
