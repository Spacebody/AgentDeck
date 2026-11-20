import Foundation

struct ProjectItem: Decodable, Identifiable {
    let cwd: String
    let name: String
    let mtime: Double
    let count: Int
    let active: [ActiveSession]
    var revision: Int? = nil
    var id: String { cwd }
}

struct ProjectsResponse: Decodable {
    let projects: [ProjectItem]
    let indexing: Bool
}

@MainActor final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var indexing = false
    private var generation = 0
    private var scope: Set<String>?
    private let api: APIClient

    init(projects: [ProjectItem] = [], api: APIClient = .shared) { self.projects = projects; self.api = api }

    func refresh(agents: Set<String>) async {
        if scope != agents { projects = []; indexing = false; scope = agents }
        generation += 1
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        failed = false
        guard !agents.isEmpty else { projects = []; loading = false; indexing = false; return }
        do {
            let response: ProjectsResponse = try await api.get("/api/projects", query: ["tool": agents.sorted().joined(separator: ",")])
            guard !Task.isCancelled, request == generation else { return }
            projects = response.projects
            indexing = response.indexing
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            failed = true
        }
        loading = false
    }
}

@MainActor final class ProjectSessionsStore: ObservableObject {
    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var hasMore = false
    @Published private(set) var page = 1
    @Published private(set) var total = 0
    private var cursors = [""]
    private var nextCursor = ""
    private var generation = 0
    private let api: APIClient

    init(api: APIClient = .shared) { self.api = api }

    func load(cwd: String, agents: Set<String>, direction: Int = 0, refreshCurrent: Bool = false) async {
        guard !loading || direction == 0 else { return }
        generation += 1
        let request = generation
        var target = direction == 0 ? (refreshCurrent ? page : 1) : max(1, page + direction)
        if direction == 0 && !refreshCurrent { cursors = [""]; sessions = []; page = 1; hasMore = false }
        if direction > 0 {
            guard hasMore, !nextCursor.isEmpty else { return }
            cursors = Array(cursors.prefix(page)) + [nextCursor]
        }
        guard target <= cursors.count else { return }
        loading = true; failed = false
        defer { if request == generation { loading = false } }
        do {
            let response: SessionsResponse = try await api.get("/api/projects", query: [
                "cwd": cwd, "tool": agents.sorted().joined(separator: ","), "cursor": cursors[target - 1]
            ])
            guard !Task.isCancelled, request == generation else { return }
            if response.cursorStale == true { cursors = [""]; target = 1 }
            sessions = response.sessions
            total = response.total ?? response.sessions.count
            nextCursor = response.nextCursor ?? ""
            hasMore = response.hasMore == true
            page = target
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            failed = true
        }
        loading = false
    }
}
