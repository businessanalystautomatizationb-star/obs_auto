import AppKit

enum NSWorkspaceOpener {
    static func reveal(path: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }
}
