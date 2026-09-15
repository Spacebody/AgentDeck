import AppKit

public enum AutoPastePolicy {
    @MainActor public static func copyCommand(_ command: String,
                                              to pasteboard: NSPasteboard = .general) -> Int? {
        verifiedCopy(command, clear: { pasteboard.clearContents() },
                     write: { pasteboard.setString($0, forType: .string) },
                     generation: { pasteboard.changeCount })
    }

    // Capture ownership at clearContents, not after writing: another writer must
    // never become the accepted baseline for a delayed paste.
    static func verifiedCopy(_ command: String, clear: () -> Int,
                             write: (String) -> Bool, generation: () -> Int) -> Int? {
        guard !command.isEmpty else { return nil }
        let ownedGeneration = clear()
        guard write(command), generation() == ownedGeneration else { return nil }
        return ownedGeneration
    }

    public static func applicationName(for terminal: String) -> String? {
        ["warp": "Warp", "vscode": "Visual Studio Code", "cursor": "Cursor",
         "windsurf": "Windsurf", "hyper": "Hyper", "tabby": "Tabby",
         "rio": "Rio", "wave": "Wave"][terminal]
    }

    public static func shouldSend(expectedPID: Int32, frontmostPID: Int32?,
                                  originalClipboard: Int, currentClipboard: Int) -> Bool {
        expectedPID > 0 && frontmostPID == expectedPID
            && originalClipboard == currentClipboard
    }
}
