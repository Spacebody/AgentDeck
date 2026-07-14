// AgentDeck v2 — 会话页数据模型。对应 api_sessions(1137) / api_preview(1460) / api_resume(2334)。
import Foundation

struct SessionsResponse: Decodable {
    let sessions: [SessionItem]
    let query: String?
    let tool: String?
    let total: Int?
    let hasMore: Bool?
    let nextCursor: String?
    let indexing: Bool?
    let indexedAt: Double?
    let indexProgress: SessionIndexProgress?
    let indexError: String?
}

struct SessionIndexProgress: Decodable {
    let processed: Int?
    let total: Int?
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

    /// ForEach / 预览 / 置顶复合键；同一会话可被复制到不同账号目录。
    var rowKey: String { "\(tool):\(accountId ?? "default"):\(id)" }
}

// /api/preview?tool=&id=&account_id= → {ok, messages:[{role, text}]}
struct PreviewResponse: Decodable {
    let ok: Bool
    let messages: [PreviewMsg]?
}
struct PreviewMsg: Decodable {
    let role: String   // user / assistant
    let text: String
}

// /api/terminals → {terminals:[{mode, name}]}（已安装终端，恢复方式选项）
struct TerminalsResponse: Decodable { let terminals: [TerminalOption] }
struct TerminalOption: Decodable { let mode: String; let name: String }

struct SessionResumeRequest: Encodable {
    let tool: String
    let id: String
    let cwd: String
    let accountId: String?
    let copyOnly: Bool
    let replacementCwd: String?

    enum CodingKeys: String, CodingKey {
        case tool, id, cwd
        case accountId = "account_id"
        case copyOnly = "copy_only"
        case replacementCwd = "replacement_cwd"
    }
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
    let needsPath: Bool?
    let originalCwd: String?
    let resolvedCwd: String?
    let pathMapped: Bool?
    let error: String?
}
