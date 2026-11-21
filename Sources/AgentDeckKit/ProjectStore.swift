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
    @Published private var discovered: [ProjectItem]
    @Published private(set) var imported: [String]
    private let defaults: UserDefaults
    private static let directoryKey = "importedProjectDirectories"
    var projects: [ProjectItem] {
        let known = Set(discovered.map(\.cwd))
        return discovered + imported.filter { !known.contains($0) }.map {
            ProjectItem(cwd: $0, name: URL(fileURLWithPath: $0).lastPathComponent,
                        mtime: 0, count: 0, active: [])
        }
    }
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var indexing = false
    private var generation = 0
    private var scope: Set<String>?
    private let api: APIClient

    init(projects: [ProjectItem] = [], api: APIClient = .shared, defaults: UserDefaults = .standard,
         loadImported: Bool = true) {
        self.discovered = projects; self.api = api; self.defaults = defaults
        imported = loadImported ? defaults.stringArray(forKey: Self.directoryKey) ?? [] : []
    }

    func importDirectories(_ urls: [URL]) {
        var paths = imported
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory),
               directory.boolValue, !paths.contains(path) { paths.append(path) }
        }
        imported = paths
        defaults.set(paths, forKey: Self.directoryKey)
    }

    func forgetDirectory(_ path: String) {
        imported.removeAll { $0 == path }
        defaults.set(imported, forKey: Self.directoryKey)
    }

    func refresh(agents: Set<String>, interactive: Bool = true) async {
        if scope != agents { discovered = []; indexing = false; scope = agents }
        generation += 1
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        failed = false
        guard !agents.isEmpty else { discovered = []; loading = false; indexing = false; return }
        do {
            var params = ["tool": agents.sorted().joined(separator: ",")]
            if interactive { params["interactive"] = "1" }
            let response: ProjectsResponse = try await api.get("/api/projects", query: params)
            guard !Task.isCancelled, request == generation else { return }
            discovered = response.projects
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
            var params = [
                "cwd": cwd, "tool": agents.sorted().joined(separator: ","), "cursor": cursors[target - 1]
            ]
            if !refreshCurrent { params["interactive"] = "1" }
            let response: SessionsResponse = try await api.get("/api/projects", query: params)
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
