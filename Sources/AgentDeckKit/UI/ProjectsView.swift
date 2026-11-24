import SwiftUI

struct ProjectsView: View {
    @StateObject private var model: ProjectStore
    let agents: Set<String>
    let isActive: Bool
    let showActive: Bool
    let refreshSeconds: Int
    var previewSessions: [SessionItem]? = nil
    var onOpen: (ActiveSession) -> Void
    var onResume: (SessionItem) -> Void
    @State private var expanded: Set<String> = []
    private var scope: String { agents.sorted().joined(separator: ",") }

    init(agents: Set<String>, isActive: Bool = true, showActive: Bool = true, refreshSeconds: Int = 30,
         previewProjects: [ProjectItem]? = nil,
         previewSessions: [SessionItem]? = nil,
         onOpen: @escaping (ActiveSession) -> Void, onResume: @escaping (SessionItem) -> Void) {
        self.agents = agents; self.isActive = isActive; self.onOpen = onOpen; self.onResume = onResume
        self.previewSessions = previewSessions
        self.showActive = showActive
        self.refreshSeconds = min(600, max(5, refreshSeconds))
        _model = StateObject(wrappedValue: ProjectStore(projects: previewProjects ?? [], loadImported: previewProjects == nil))
        _expanded = State(initialValue: Set(previewProjects?.prefix(1).map(\.id) ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DashboardHeading(text: L("tab.projects"), count: model.projects.count)
                IconButton(system: "folder.badge.plus", fontSize: 13) {
                    let picker = NSOpenPanel()
                    picker.title = L("v3.importFolders")
                    picker.canChooseFiles = false
                    picker.canChooseDirectories = true
                    picker.allowsMultipleSelection = true
                    picker.canCreateDirectories = false
                    if picker.runModal() == .OK { model.importDirectories(picker.urls) }
                }
                .help(L("v3.importFolders")).accessibilityLabel(L("v3.importFolders"))
                IconButton(system: "arrow.clockwise", fontSize: 13) {
                    Task { await model.refresh(agents: agents) }
                }
                .help(L("header.refresh")).accessibilityLabel(L("header.refresh")).disabled(model.loading)
            }
            if model.loading && model.projects.isEmpty { ProgressView().controlSize(.small) }
            if model.failed {
                Text(L("session.loadFailed")).foregroundStyle(Theme.warn)
            }
            if model.indexing { Text(L("session.indexing")).foregroundStyle(Theme.ink3) }
            if !model.loading && !model.failed && model.projects.isEmpty {
                Text(L("v3.projectsEmpty")).foregroundStyle(Theme.ink3).padding(.vertical, 30)
            }
            LazyVStack(spacing: 0) {
                ForEach(model.projects) { project in
                    VStack(spacing: 0) {
                        Button {
                            if expanded.contains(project.id) { expanded.remove(project.id) }
                            else { expanded.insert(project.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.system(size: 21)).foregroundStyle(DashboardStyle.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if project.mtime > 0 {
                                            Text(Fmt.relative(Date(timeIntervalSince1970: project.mtime)))
                                                .font(.system(size: 10)).foregroundStyle(Theme.ink3)
                                        }
                                    }
                                    Text(project.cwd).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                                        .lineLimit(1).truncationMode(.middle).help(project.cwd)
                                    if showActive && !project.active.isEmpty {
                                        Text(L("active.running", ["n": "\(project.active.count)"]))
                                            .font(.system(size: 10)).foregroundStyle(DashboardStyle.accent)
                                    }
                                }
                                Image(systemName: expanded.contains(project.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10)).foregroundStyle(Theme.ink3)
                            }.padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu {
                            if model.imported.contains(project.cwd) {
                                Button(L("v3.forgetFolder")) { model.forgetDirectory(project.cwd) }
                            }
                        }
                        if expanded.contains(project.id) {
                            if project.count == 0 && project.active.isEmpty {
                                Text(L("v3.noProjectSessions")).foregroundStyle(Theme.ink3).padding(.bottom, 12)
                            } else {
                                ProjectSessionsView(project: project, agents: agents, showActive: showActive,
                                                previewSessions: previewSessions?.filter { $0.cwd == project.cwd },
                                                onOpen: onOpen, onResume: onResume)
                                .padding(.leading, 32).padding(.bottom, 15)
                            }
                        }
                    }
                    Divider().opacity(0.4)
                }
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.ink)
            .task(id: "\(scope)|\(isActive)|\(refreshSeconds)") {
                guard isActive, previewSessions == nil else { return }
                await model.refresh(agents: agents)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(refreshSeconds) * 1_000_000_000) } catch { return }
                    await model.refresh(agents: agents, interactive: false)
                }
            }
    }
}

private struct ProjectSessionsView: View {
    let project: ProjectItem
    let agents: Set<String>
    let showActive: Bool
    var previewSessions: [SessionItem]? = nil
    var onOpen: (ActiveSession) -> Void
    var onResume: (SessionItem) -> Void
    @StateObject private var model = ProjectSessionsStore()
    @State private var loadedScope: String?
    private var scope: String { project.id + agents.sorted().joined(separator: ",") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showActive && !project.active.isEmpty { DashboardActiveList(sessions: project.active.filter { agents.contains($0.tool) }, onOpen: onOpen) }
            if model.loading { ProgressView().controlSize(.small) }
            if model.failed {
                Button(L("v3.retry")) { Task { await load() } }.foregroundStyle(Theme.warn)
            }
            ForEach((previewSessions ?? model.sessions).filter { session in !showActive || !project.active.contains { $0.indexedRowKey == session.rowKey } }, id: \.rowKey) { session in
                HStack(spacing: 8) {
                    SessionIcon(tool: session.tool)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title ?? session.id).font(.system(size: 11)).lineLimit(2)
                        Text([session.sourceLabel ?? session.account, session.tool == "antigravity" && session.mtime <= 0 ? nil : Fmt.relative(Date(timeIntervalSince1970: session.mtime))]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { onResume(session) } label: {
                        Image(systemName: "arrow.up.right").frame(width: 28, height: 28)
                    }.buttonStyle(.plain).foregroundStyle(DashboardStyle.accent).help(L("session.resume"))
                        .disabled(!session.canResume)
                }.padding(.vertical, 6)
            }
            HStack {
                Text("\(previewSessions?.count ?? model.total)").foregroundStyle(Theme.ink3)
                Spacer()
                Button { Task { await load(-1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page <= 1 || model.loading)
                Text("\(model.page)").monospacedDigit()
                Button { Task { await load(1) } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.hasMore || model.loading)
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.top, 8)
        }.task(id: "\(scope)|\(project.mtime)|\(project.count)|\(project.revision ?? 0)") {
            guard previewSessions == nil else { return }
            let refresh = loadedScope == scope
            loadedScope = scope
            await model.load(cwd: project.cwd, agents: agents, refreshCurrent: refresh)
        }
    }
    private func load(_ direction: Int = 0) async {
        guard previewSessions == nil else { return }
        await model.load(cwd: project.cwd, agents: agents, direction: direction)
    }
}
