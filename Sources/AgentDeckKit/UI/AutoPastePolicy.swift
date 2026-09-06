import Foundation

public enum AutoPastePolicy {
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
