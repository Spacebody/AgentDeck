// AgentDeck v2 — 会话页数据模型。对应 api_sessions(1137) / api_preview(1460) / api_resume(2334)。
import Foundation

struct SessionsResponse: Decodable {
    let sessions: [SessionItem]
    let query: String?
}

struct SessionItem: Decodable, Identifiable {
    let tool: String
    let id: String
    let title: String?
    let cwd: String?
    let project: String?
    let branch: String?
    let mtime: Double
    let account: String?
    let accountId: String?
    var pinned: Bool?

    /// ForEach 复合键（同 id 可能跨工具）。
    var rowKey: String { "\(tool):\(id)" }

    /// 恢复命令（与前端一致）：cd "cwd" && claude --resume <id> / codex resume <id>
    var resumeCommand: String {
        let dir = cwd ?? "~"
        let cmd = tool == "claude" ? "claude --resume" : "codex resume"
        return "cd \(quoted(dir)) && \(cmd) \(id)"
    }
    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// /api/preview?tool=&id= → {ok, messages:[{role, text}]}
struct PreviewResponse: Decodable {
    let ok: Bool
    let messages: [PreviewMsg]?
}
struct PreviewMsg: Decodable, Identifiable {
    let role: String   // user / assistant
    let text: String
    var id: String { role + text.prefix(24) }
}

// /api/resume 应答（仅复制 / 唤起粘贴模式）
struct ResumeResult: Decodable {
    let ok: Bool
    let copy: Bool?
    let paste: Bool?
    let command: String?
    let app: String?
    let autoPaste: Bool?
    let terminal: String?
    let error: String?
}
