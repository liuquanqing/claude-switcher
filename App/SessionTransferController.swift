import AppKit
import SwiftUI
import Combine
import SwitcherCore

struct TransferLocationOption: Identifiable, Sendable {
    let id: String
    let name: String
    var isActive: Bool = false
    var isNewest: Bool = false
    var lastKnownAccountPrefix: String? = nil
    var latestActivityAt: Date? = nil
}

struct TransferSpaceOption: Identifiable, Sendable {
    let space: SessionTransferSpace
    let matchesProfile: Bool
    let profileName: String?
    let accountName: String?
    let organizationName: String?
    let count: Int?
    let title: String?
    var accountEmail: String? = nil
    var inferredNewSince: Date? = nil
    var latestActivityAt: Date? = nil
    var id: String { space.id }
}

private struct TransferAccountNames {
    let identity: CLIIdentity
    let account: String?
    let organization: String?
    let email: String?

    init?(document: URL?) {
        guard let document, let data = try? Data(contentsOf: document),
              let json = try? CLIJSON.object(data), let record = json["oauthAccount"] as? [String: Any] else { return nil }
        let identity = CLIIdentity.profile(record)
        guard identity.isComplete else { return nil }
        func name(_ key: String) -> String? {
            guard let value = (record[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        self.identity = identity
        email = identity.email
        account = name("displayName") ?? name("fullName")
        organization = name("organizationName")
    }
}

struct TransferSessionItem: Identifiable {
    let id: String
    let title: String
    let cwd: String
    let kind: SessionTransferKind
    var continuation = false
    var parkedFrom: String? = nil
}

struct SessionTransferConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let buttonTitle: String
    var kind: String = "copy"
    var items: [TransferSessionItem] = []
    var addedCount: Int = 0
    var updatedCount: Int = 0
    var continuationCount: Int = 0
    var parkedCount: Int = 0
    var canWaitForQuit: Bool = false
}

struct SessionTransferOperation: Identifiable {
    let id: String
    let targetName: String
    let title: String
    let summary: String
    let canUndo: Bool
    let needsRecovery: Bool
    let backupURL: URL
    let items: [TransferSessionItem]
    let state: SessionTransferReceiptState
    var addedCount: Int { items.filter { $0.kind == .add && $0.parkedFrom == nil }.count }
    var updatedCount: Int { items.filter { $0.kind == .update }.count }
    var parkedCount: Int { items.filter { $0.parkedFrom != nil }.count }
}

enum NewSessionCutoffMode: Equatable, Sendable {
    case auto
    case days(Int)
    case custom(Date)
    case all
}

enum SyncWaitPhase: Equatable, Sendable {
    case idle
    case waitingForQuit
    case settling(Int)
    case writing
}

struct SessionTransferEnvironment: Sendable {
    let endpoints: [SessionTransferEndpoint]
    let activeEndpointIDs: Set<String>
    let transcripts: URL
    let backups: URL
    var savedIdentities: [String: CLIIdentity] = [:]
    var cliMetadataDocument: URL?
}

struct SessionTransferLoaded: Sendable {
    let spaces: [String: [SessionTransferSpace]]
    let options: [String: [TransferSpaceOption]]
    let errors: [String: String]
    let receipts: [SessionTransferReceipt]
    let historyError: String?
    let endpointActivities: [String: Date]
    let endpointLastKnownAccounts: [String: String]
    let newestEndpointID: String?
}

private struct SessionCopyResultSnapshot {
    let operationID: String
    let sourceSpaceID: String
    let targetSpaceID: String
    let rows: [SessionTransferRow]
    let forkResolutions: [String: SessionForkResolution]
}

actor SessionTransferWorker {
    private let runningProbe: @Sendable () throws -> Bool
    private let beforePlan: @Sendable () async -> Void
    init(runningProbe: @escaping @Sendable () throws -> Bool = {
        let result = try LocalCommand.run("/bin/ps", ["-axo", "comm="])
        guard result.0 == 0 else { throw SessionTransferFailure("无法确认目标桌面是否已退出，未操作会话。") }
        return result.1.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("/Contents/MacOS/Claude") }
    }, beforePlan: @escaping @Sendable () async -> Void = {}) { self.runningProbe = runningProbe; self.beforePlan = beforePlan }
    private func service(_ env: SessionTransferEnvironment) -> SessionTransferService {
        SessionTransferService(transcripts: env.transcripts, backups: env.backups)
    }
    func isDesktopRunning(for target: SessionTransferSpace, in env: SessionTransferEnvironment) throws -> Bool {
        guard env.activeEndpointIDs.contains(target.endpoint.id) else { return false }
        return try runningProbe()
    }
    func load(_ env: SessionTransferEnvironment) -> SessionTransferLoaded {
        let engine = service(env)
        var spaces: [String: [SessionTransferSpace]] = [:], errors: [String: String] = [:]
        var options: [String: [TransferSpaceOption]] = [:]
        var endpointActivities: [String: Date] = [:]
        var endpointLastKnownAccounts: [String: String] = [:]
        let localNames = TransferAccountNames(document: env.cliMetadataDocument)
        for endpoint in env.endpoints {
            if let uuid = SessionTransferService.lastKnownAccountUUID(in: endpoint.root) {
                endpointLastKnownAccounts[endpoint.id] = String(uuid.prefix(8))
            }
            do {
                let discovered = try engine.spaces(in: endpoint)
                spaces[endpoint.id] = discovered
                var maxActivity: Date?
                options[endpoint.id] = discovered.map { space in
                    let identity = CLIIdentity(accountID: space.account, organizationID: space.organization, email: nil)
                    let matches = env.savedIdentities[endpoint.id]?.samePrincipal(as: identity) == true
                    let profiles = env.endpoints.filter { env.savedIdentities[$0.id]?.samePrincipal(as: identity) == true }
                    let profileName = matches ? endpoint.name : (profiles.count == 1 ? profiles.first?.name : nil)
                    let accountMatches = CLIReportedStatus.sameAccountRecord(localNames?.identity, identity) == true
                    let accountProfiles = env.endpoints.filter {
                        CLIReportedStatus.sameAccountRecord(env.savedIdentities[$0.id], identity) == true
                    }
                    let organizationMatches = localNames?.identity.samePrincipal(as: identity) == true
                    let emails = (accountProfiles.compactMap { env.savedIdentities[$0.id]?.email }
                        + [accountMatches ? localNames?.email : nil].compactMap { $0 })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                    let email = Set(emails).count == 1 ? emails.first : nil
                    let activity = try? engine.spaceActivity(space)
                    if let ts = activity?.newestTimestamp, (maxActivity == nil || ts > maxActivity!) {
                        maxActivity = ts
                    }
                    let preview = discovered.count > 1 ? try? engine.spacePreview(space) : nil
                    return TransferSpaceOption(space: space, matchesProfile: matches, profileName: profileName,
                        accountName: (accountMatches ? localNames?.account : nil)
                            ?? (accountProfiles.count == 1 ? accountProfiles.first?.name : nil),
                        organizationName: organizationMatches ? localNames?.organization : nil,
                        count: preview?.count, title: preview?.title, accountEmail: email,
                        inferredNewSince: activity?.inferredNewSince, latestActivityAt: activity?.newestTimestamp)
                }
                if let maxActivity { endpointActivities[endpoint.id] = maxActivity }
            }
            catch { spaces[endpoint.id] = []; errors[endpoint.id] = error.localizedDescription }
        }
        let newestEndpointID = endpointActivities.max(by: { $0.value < $1.value })?.key
        do {
            return SessionTransferLoaded(spaces: spaces, options: options, errors: errors, receipts: try engine.receipts(),
                                         historyError: nil, endpointActivities: endpointActivities,
                                         endpointLastKnownAccounts: endpointLastKnownAccounts, newestEndpointID: newestEndpointID)
        } catch {
            return SessionTransferLoaded(spaces: spaces, options: options, errors: errors, receipts: [],
                                         historyError: "备份记录无法确认，已停止新复制。备份位置：\(env.backups.path)",
                                         endpointActivities: endpointActivities,
                                         endpointLastKnownAccounts: endpointLastKnownAccounts, newestEndpointID: newestEndpointID)
        }
    }
    func rows(_ env: SessionTransferEnvironment, source: SessionTransferSpace, target: SessionTransferSpace,
              updates: Bool, newSince: Date? = nil) throws -> [SessionTransferRow] {
        try service(env).rows(source: source, target: target, updateExisting: updates, newSince: newSince)
    }
    func plan(_ env: SessionTransferEnvironment, source: SessionTransferSpace, target: SessionTransferSpace,
              selected: Set<String>, updates: Bool, expectedSourceIdentities: [String: String],
              newSince: Date? = nil, forkResolutions: [String: SessionForkResolution] = [:]) async throws -> SessionTransferPlan {
        await beforePlan()
        return try service(env).plan(source: source, target: target, selected: selected, updateExisting: updates,
                                     expectedSourceIdentities: expectedSourceIdentities, newSince: newSince,
                                     forkResolutions: forkResolutions)
    }
    private func idle(_ env: SessionTransferEnvironment, _ target: SessionTransferSpace) throws {
        if env.activeEndpointIDs.contains(target.endpoint.id), try runningProbe() {
            throw SessionTransferFailure("请先保存工作并自行退出 Claude，再重新检查后复制；本工具不会自动结束桌面或 CLI 任务。")
        }
    }
    func execute(_ env: SessionTransferEnvironment, _ plan: SessionTransferPlan) throws -> SessionTransferReceipt {
        try service(env).execute(plan, requireIdle: { try self.idle(env, plan.target) })
    }
    func verify(_ env: SessionTransferEnvironment, receipt: SessionTransferReceipt, target: SessionTransferSpace) throws -> SessionTransferVerification {
        try service(env).verifyAfterExecute(receipt, in: target)
    }
    func keepCurrentData(_ env: SessionTransferEnvironment, id: String, space: SessionTransferSpace) throws -> SessionTransferReceipt {
        try service(env).keepCurrentData(id, in: space)
    }
    func restore(_ env: SessionTransferEnvironment, id: String, space: SessionTransferSpace, undo: Bool) throws -> SessionTransferReceipt {
        try service(env).restore(id, to: space, undo: undo, requireIdle: { try self.idle(env, space) })
    }
    func saveInstructions(_ env: SessionTransferEnvironment, plan: SessionTransferPlan, command: URL) throws -> String {
        let request = try SessionTransferRequest(plan: plan, transcripts: env.transcripts, backups: env.backups)
        let path = env.backups.deletingLastPathComponent().appendingPathComponent("session-transfer-requests/" + UUID().uuidString + ".json")
        try request.save(to: path)
        return try SessionTransferRequest.load(from: path).instructions(command: command, request: path)
    }
    func backup(_ env: SessionTransferEnvironment, id: String) throws -> SessionTransferReceipt {
        try service(env).checkedBackup(id)
    }
}

@MainActor final class SessionTransferController: ObservableObject {
    @Published private(set) var locations: [TransferLocationOption] = []
    @Published private(set) var sourceID = ""
    @Published private(set) var targetID = ""
    @Published private(set) var sourceSpaceID = ""
    @Published private(set) var targetSpaceID = ""
    @Published private(set) var sourceSpaces: [TransferSpaceOption] = []
    @Published private(set) var targetSpaces: [TransferSpaceOption] = []
    @Published private(set) var rows: [SessionTransferRow] = []
    @Published private(set) var picked: Set<String> = []
    @Published private(set) var forkResolutions: [String: SessionForkResolution] = [:]
    @Published var query = ""
    @Published private(set) var updateExisting = true
    @Published private(set) var cutoffMode: NewSessionCutoffMode = .auto
    @Published private(set) var inferredNewSinceDate: Date?
    @Published private(set) var customNewSince: Date?
    @Published var showsCustomNewDate = false
    @Published private(set) var isWorking = false
    @Published private(set) var waitPhase: SyncWaitPhase = .idle
    @Published private(set) var reopenCountdown: Int = 0
    @Published private(set) var targetIsActive = false
    @Published private(set) var desktopRunning = false
    @Published private(set) var newestEndpointID: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmation: SessionTransferConfirmation?
    @Published private(set) var lastOperation: SessionTransferOperation?
    @Published private(set) var lastVerification: SessionTransferVerification?
    @Published private(set) var backupInformation: String?
    @Published private(set) var backupItems: [TransferSessionItem] = []
    @Published private(set) var handoffInformation: String?
    @Published private(set) var language = AppLocalization.defaultLanguage
    @Published private var completedSnapshot: SessionCopyResultSnapshot?
    private var languageObservation: AnyCancellable?
    private let store: Store
    private let worker: SessionTransferWorker
    private let fixedEnvironment: SessionTransferEnvironment?
    private var environment: SessionTransferEnvironment?
    private var spaces: [String: [SessionTransferSpace]] = [:]
    private var latestReceipt: SessionTransferReceipt?
    private var historyError: String?
    private var refreshID = UUID()
    private var pendingPlan: SessionTransferPlan?
    private var pendingRestore: (String, Bool)?
    private var pendingPreserve: String?
    private var writing = false
    private var operationStatus: String?
    private var preselectMissing = true
    private var loadedSelectionScope: String?
    private let demoRoot: URL?
    private let commandURL: URL
    private var waitTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private let waitPollNanoseconds: UInt64
    private let settleSeconds: Int
    private let reopenSeconds: Int

    init(store: Store, testEnvironment: SessionTransferEnvironment? = nil, worker: SessionTransferWorker? = nil,
         commandURL: URL? = nil, waitPollNanoseconds: UInt64 = 1_000_000_000, settleSeconds: Int = 8, reopenSeconds: Int = 15) {
        self.store = store
        self.commandURL = commandURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeSessionTransfer")
        self.waitPollNanoseconds = waitPollNanoseconds
        self.settleSeconds = settleSeconds
        self.reopenSeconds = reopenSeconds
        if let testEnvironment {
            fixedEnvironment = testEnvironment; demoRoot = nil
            self.worker = worker ?? SessionTransferWorker(runningProbe: { false })
        } else if store.isDemo {
            do {
                let scenario = Bundle.main.object(forInfoDictionaryKey: "CSPreviewTransferScenario") as? String ?? "normal"
                let result = try SessionTransferDemo.environment(scenario: scenario)
                fixedEnvironment = result.0; demoRoot = result.1
            } catch {
                fixedEnvironment = SessionTransferEnvironment(endpoints: [], activeEndpointIDs: [], transcripts: URL(fileURLWithPath: "/unavailable-fixture"), backups: URL(fileURLWithPath: "/unavailable-fixture"))
                demoRoot = nil; errorMessage = "演示夹具未创建，未访问真实会话。"
            }
            let delay = min(5000, max(0, Bundle.main.object(forInfoDictionaryKey: "CSPreviewTransferPlanDelayMS") as? Int ?? 0))
            self.worker = worker ?? SessionTransferWorker(runningProbe: { false }, beforePlan: {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            })
        } else {
            fixedEnvironment = nil; demoRoot = nil
            self.worker = worker ?? SessionTransferWorker()
        }
        language = store.appLanguage
        languageObservation = store.$appLanguage.removeDuplicates().sink { [weak self] value in self?.language = value }
    }
    deinit {
        waitTask?.cancel()
        reopenTask?.cancel()
        if let demoRoot { try? FileManager.default.removeItem(at: demoRoot) }
    }

    var isWaitingForQuit: Bool { waitPhase != .idle }

    var newSessionAgeDays: Int? {
        switch cutoffMode {
        case .days(let d): return d
        case .auto, .custom, .all: return nil
        }
    }

    var effectiveNewSince: Date? {
        switch cutoffMode {
        case .auto: return inferredNewSinceDate
        case .days(let d): return Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(d) * 86400))
        case .custom(let date): return Calendar.current.startOfDay(for: date)
        case .all: return nil
        }
    }

    var visibleRows: [SessionTransferRow] {
        let displayed = isShowingCopyResult ? completedSnapshot?.rows ?? rows : rows
        return displayed.filter { matchesQuery($0) }
    }

    var hiddenOlderAdditionsCount: Int {
        guard !isShowingCopyResult else { return 0 }
        return rows.filter { $0.skippedByCutoff && matchesQuery($0) }.count
    }

    private func matchesQuery(_ row: SessionTransferRow) -> Bool {
        query.isEmpty || "\(row.title) \(row.cwd) \(resultItem(for: row)?.title ?? "")".localizedCaseInsensitiveContains(query)
    }

    var activeForkIDs: Set<String> {
        Set(rows.filter { row in
            guard row.kind == .fork else { return false }
            let res = forkResolutions[row.id] ?? .skip
            return res == .takeSource || res == .keepTarget
        }.map(\.id))
    }

    var effectiveSelectedIDs: Set<String> {
        picked.union(activeForkIDs)
    }

    var isShowingCopyResult: Bool {
        guard let snapshot = completedSnapshot, let operation = lastOperation else { return false }
        return operation.state == .completed && operation.id == snapshot.operationID
            && sourceSpaceID == snapshot.sourceSpaceID && targetSpaceID == snapshot.targetSpaceID
    }

    func resultItem(for row: SessionTransferRow) -> TransferSessionItem? {
        guard isShowingCopyResult, let snapshot = completedSnapshot,
              snapshot.rows.contains(where: { $0.id == row.id && $0.identity == row.identity }) else { return nil }
        return lastOperation?.items.first { $0.id == row.id }
            ?? lastOperation?.items.first { $0.parkedFrom == row.id }
    }

    var canCopy: Bool {
        !isShowingCopyResult && !isWorking && !isWaitingForQuit && !effectiveSelectedIDs.isEmpty
            && sourceSpaceID != targetSpaceID && !sourceSpaceID.isEmpty && !targetSpaceID.isEmpty
            && historyError == nil && !recoveryBlocksTarget
    }
    var canExport: Bool { canCopy }

    var currentEndpointID: String {
        environment?.activeEndpointIDs.first(where: { $0.hasPrefix("profile:") }) ?? "profile:" + store.current
    }

    private var recoveryBlocksTarget: Bool {
        guard let receipt = latestReceipt, receipt.state.needsRecovery else { return false }
        return targetSpaceID == receipt.target.endpointID + "/" + receipt.target.account + "/" + receipt.target.organization
    }

    private func preferredReceipt(_ receipts: [SessionTransferReceipt]) -> SessionTransferReceipt? {
        receipts.first { receipt in
            receipt.state.needsRecovery && targetSpaceID == receipt.target.endpointID + "/" + receipt.target.account + "/" + receipt.target.organization
        } ?? receipts.first
    }

    private func makeEnvironment() throws -> SessionTransferEnvironment {
        if let fixedEnvironment { return fixedEnvironment }
        let current = try confirmedCurrentProfile()
        let endpoints = store.profiles.map { profile -> SessionTransferEndpoint in
            let root = profile.name == current ? liveDir : parkDir.appendingPathComponent(profile.name)
            return SessionTransferEndpoint(id: "profile:" + profile.name, name: profile.name, root: root, marker: currentFile, expectedMarker: current)
        } + [SessionTransferEndpoint(id: "api", name: "API 工作区", root: support.appendingPathComponent("Claude-3p"))]
        var savedIdentities: [String: CLIIdentity] = [:]
        for profile in store.profiles { savedIdentities["profile:" + profile.name] = profile.snapshot?.identity }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SessionTransferEnvironment(endpoints: endpoints, activeEndpointIDs: ["profile:" + current, "api"],
            transcripts: home.appendingPathComponent(".claude/projects"),
            backups: support.appendingPathComponent("ClaudeSwitcher/session-migrations"), savedIdentities: savedIdentities,
            cliMetadataDocument: home.appendingPathComponent(".claude.json"))
    }

    private func clearSelection() {
        completedSnapshot = nil
        lastVerification = nil
        picked = []; forkResolutions = [:]; pendingPlan = nil; pendingRestore = nil; pendingPreserve = nil; confirmation = nil
        preselectMissing = true
        errorMessage = nil; statusMessage = nil; operationStatus = nil
    }

    private func queueRefresh(selectUpdates: Bool = false) {
        refreshID = UUID()
        isWorking = true
        Task { await refresh(selectUpdates: selectUpdates) }
    }

    func setSource(_ id: String) { guard !isWorking, !isWaitingForQuit, id != sourceID else { return }; sourceID = id; sourceSpaceID = ""; clearSelection(); queueRefresh() }
    func setTarget(_ id: String) { guard !isWorking, !isWaitingForQuit, id != targetID else { return }; targetID = id; targetSpaceID = ""; clearSelection(); queueRefresh() }
    func setSourceSpace(_ id: String) { guard !isWorking, !isWaitingForQuit, id != sourceSpaceID else { return }; sourceSpaceID = id; clearSelection(); queueRefresh() }
    func setTargetSpace(_ id: String) { guard !isWorking, !isWaitingForQuit, id != targetSpaceID else { return }; targetSpaceID = id; clearSelection(); queueRefresh() }

    func setUpdates(_ value: Bool) {
        guard !isWorking, !isWaitingForQuit else { return }
        completedSnapshot = nil
        updateExisting = value
        if !value {
            picked.subtract(rows.filter { $0.kind == .update }.map(\.id))
            for row in rows where row.kind == .fork { forkResolutions[row.id] = .skip }
        }
        pendingPlan = nil; confirmation = nil; queueRefresh(selectUpdates: value)
    }

    func setForkResolution(_ id: String, _ resolution: SessionForkResolution) {
        guard !isWorking, !isWaitingForQuit, !isShowingCopyResult,
              rows.contains(where: { $0.id == id && $0.kind == .fork }) else { return }
        forkResolutions[id] = resolution
    }

    func setUseAutoCutoff() {
        guard !writing, !isWaitingForQuit, cutoffMode != .auto else { return }
        cutoffMode = .auto
        showsCustomNewDate = false
        queueRefresh()
    }

    func setNewSessionAge(_ days: Int?) {
        guard !writing, !isWaitingForQuit else { return }
        let next: NewSessionCutoffMode = days.map { .days($0) } ?? .all
        guard next != cutoffMode else { return }
        cutoffMode = next
        showsCustomNewDate = false
        queueRefresh()
    }

    func setCustomNewDate(_ date: Date) {
        guard !writing, !isWaitingForQuit else { return }
        let day = Calendar.current.startOfDay(for: date)
        customNewSince = day
        cutoffMode = .custom(day)
        showsCustomNewDate = true
        queueRefresh()
    }

    func swapDirection() {
        guard !isWorking, !isWaitingForQuit, !sourceID.isEmpty, !targetID.isEmpty, sourceID != targetID,
              locations.contains(where: { $0.id == sourceID }),
              locations.contains(where: { $0.id == targetID }) else { return }
        swap(&sourceID, &targetID)
        swap(&sourceSpaceID, &targetSpaceID)
        clearSelection(); queueRefresh()
    }

    func setPicked(_ id: String, selected: Bool) {
        guard !isWorking, !isWaitingForQuit, !isShowingCopyResult, let row = rows.first(where: { $0.id == id }), row.selectable else { return }
        if selected { picked.insert(id) } else { picked.remove(id) }
    }

    func selectAllVisible() {
        guard !isWorking, !isWaitingForQuit, !isShowingCopyResult else { return }
        let ids = Set(visibleRows.filter(\.selectable).map(\.id))
        if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }

    func beginAnotherCopy() {
        guard !isWorking, !isWaitingForQuit else { return }
        clearSelection(); query = ""; queueRefresh()
    }

    func refresh(selectUpdates: Bool = false) async {
        guard !writing, !isWaitingForQuit else { return }
        let token = UUID(); refreshID = token; isWorking = true
        defer { if refreshID == token { isWorking = false } }
        do {
            let env = try makeEnvironment()
            let loaded = await worker.load(env)
            guard refreshID == token, !writing else { return }
            environment = env; spaces = loaded.spaces; historyError = loaded.historyError
            newestEndpointID = loaded.newestEndpointID
            locations = env.endpoints.map { endpoint in
                TransferLocationOption(
                    id: endpoint.id,
                    name: endpoint.name,
                    isActive: env.activeEndpointIDs.contains(endpoint.id),
                    isNewest: loaded.newestEndpointID == endpoint.id,
                    lastKnownAccountPrefix: loaded.endpointLastKnownAccounts[endpoint.id],
                    latestActivityAt: loaded.endpointActivities[endpoint.id]
                )
            }
            if !locations.contains(where: { $0.id == sourceID }) {
                sourceID = locations.first(where: { $0.id == currentEndpointID })?.id
                    ?? locations.first(where: { $0.id != "api" })?.id ?? ""
            }
            if !locations.contains(where: { $0.id == targetID }) { targetID = "" }
            let a = spaces[sourceID] ?? [], b = spaces[targetID] ?? []
            sourceSpaces = loaded.options[sourceID] ?? []; targetSpaces = loaded.options[targetID] ?? []
            if !a.contains(where: { $0.id == sourceSpaceID }) { sourceSpaceID = a.count == 1 ? a[0].id : "" }
            if !b.contains(where: { $0.id == targetSpaceID }) { targetSpaceID = b.count == 1 ? b[0].id : "" }
            if let last = preferredReceipt(loaded.receipts) { display(last, environment: env) } else { latestReceipt = nil; lastOperation = nil }
            if targetID.isEmpty {
                rows = []; picked = []; forkResolutions = [:]; inferredNewSinceDate = nil
                targetIsActive = false; desktopRunning = false
                statusMessage = nil; errorMessage = historyError
                return
            }
            guard let source = a.first(where: { $0.id == sourceSpaceID }), let target = b.first(where: { $0.id == targetSpaceID }), source.id != target.id else {
                rows = []; forkResolutions = [:]; inferredNewSinceDate = nil
                targetIsActive = false; desktopRunning = false
                errorMessage = loaded.errors[sourceID] ?? loaded.errors[targetID] ?? historyError
                statusMessage = sourceSpaces.isEmpty || targetSpaces.isEmpty ? "请先在相应账号或 API 工作区打开 Code 页，再重新检查。" : "请选择不同的来源和目标空间。"
                return
            }
            inferredNewSinceDate = targetSpaces.first(where: { $0.id == target.id })?.inferredNewSince
            targetIsActive = env.activeEndpointIDs.contains(target.endpoint.id)
            if targetIsActive {
                desktopRunning = (try? await worker.isDesktopRunning(for: target, in: env)) ?? false
            } else {
                desktopRunning = false
            }
            let result = try await worker.rows(env, source: source, target: target, updates: updateExisting, newSince: effectiveNewSince)
            guard refreshID == token, !writing else { return }
            let scope = source.id + "\n" + target.id
            if loadedSelectionScope != scope {
                picked = []; forkResolutions = [:]; preselectMissing = true; loadedSelectionScope = scope
            }
            rows = result
            // Initialize default fork resolutions for newly discovered forks (later effective turn timestamp wins).
            let currentForkIDs = Set(result.filter { $0.kind == .fork }.map(\.id))
            forkResolutions = forkResolutions.filter { currentForkIDs.contains($0.key) }
            for row in result where row.kind == .fork {
                if forkResolutions[row.id] == nil {
                    forkResolutions[row.id] = updateExisting ? (row.fork?.defaultResolution ?? .skip) : .skip
                }
            }
            if preselectMissing {
                picked = Set(visibleRows.filter { $0.selectable && !$0.continuation }.map(\.id))
                preselectMissing = false
            } else {
                picked.formIntersection(result.filter(\.selectable).map(\.id))
            }
            if selectUpdates && updateExisting {
                picked.formUnion(visibleRows.filter { $0.kind == .update && !$0.continuation }.map(\.id))
                for row in visibleRows where row.kind == .fork && forkResolutions[row.id] == .skip {
                    forkResolutions[row.id] = row.fork?.defaultResolution ?? .skip
                }
            }
            statusMessage = operationStatus; errorMessage = historyError
        } catch {
            guard refreshID == token else { return }
            rows = []; picked = []; forkResolutions = [:]; errorMessage = error.localizedDescription
        }
    }

    private func chosen(_ id: String) -> SessionTransferSpace? { spaces.values.flatMap { $0 }.first { $0.id == id } }

    func copySelected() async {
        guard canCopy, let env = environment, let source = chosen(sourceSpaceID), let target = chosen(targetSpaceID) else { return }
        let intent = refreshID
        let selected = effectiveSelectedIDs
        let expectedSourceIdentities = Dictionary(uniqueKeysWithValues: rows.filter { selected.contains($0.id) }.map { ($0.id, $0.identity) })
        isWorking = true; errorMessage = nil; statusMessage = nil; operationStatus = nil
        defer { if refreshID == intent { isWorking = false } }
        do {
            let plan = try await worker.plan(env, source: source, target: target, selected: selected, updates: updateExisting,
                                             expectedSourceIdentities: expectedSourceIdentities, newSince: effectiveNewSince,
                                             forkResolutions: forkResolutions)
            guard refreshID == intent else { statusMessage = "选择或空间已变化，请重新复制。"; return }
            var activeAndRunning = false
            if env.activeEndpointIDs.contains(target.endpoint.id) {
                activeAndRunning = (try? await worker.isDesktopRunning(for: target, in: env)) ?? false
            }
            desktopRunning = activeAndRunning
            if plan.updatedCount > 0 || plan.parkedCount > 0 || activeAndRunning {
                pendingPlan = plan
                let items = plan.changes.map { change in
                    let row = plan.rows.first { $0.id == change.name || $0.id == change.parkedFrom }
                    return TransferSessionItem(id: change.name, title: change.title, cwd: row?.cwd ?? "", kind: change.kind,
                                               continuation: change.parkedFrom == nil && (row?.continuation ?? false),
                                               parkedFrom: change.parkedFrom)
                }
                let title = activeAndRunning ? "目标账号正在运行" : (plan.parkedCount > 0 ? "确认同步并保留旧分支？" : "更新已有会话？")
                var parts: [String] = []
                if plan.addedCount > 0 { parts.append("新增 \(plan.addedCount) 条") }
                if plan.updatedCount > 0 { parts.append("覆盖 \(plan.updatedCount) 条") }
                if plan.parkedCount > 0 { parts.append("另存旧分支 \(plan.parkedCount) 条") }
                let msg = activeAndRunning
                    ? "将\(parts.joined(separator: "、"))。目标账号当前正在运行 Claude，写入期间会锁定切档，可等待你退出 Claude 后自动安全写入。"
                    : "将\(parts.joined(separator: "、"))。旧索引会先自动备份，聊天原文不变。"
                confirmation = SessionTransferConfirmation(
                    title: title, message: msg,
                    buttonTitle: activeAndRunning ? "立即尝试写入" : "确认同步",
                    kind: "copy",
                    items: items.filter(\.continuation) + items.filter { !$0.continuation },
                    addedCount: plan.addedCount, updatedCount: plan.updatedCount,
                    continuationCount: items.filter(\.continuation).count,
                    parkedCount: plan.parkedCount,
                    canWaitForQuit: activeAndRunning
                )
            } else {
                try await execute(plan, environment: env)
                await refresh()
            }
        } catch { await handle(error, environment: env) }
    }

    func confirmAction() async {
        guard !isWorking, !isWaitingForQuit else { errorMessage = "正在处理，请重新确认后再执行。"; cancelConfirmation(); return }
        guard let env = environment else { return }
        let intent = refreshID
        isWorking = true; confirmation = nil; errorMessage = nil
        defer { if refreshID == intent { isWorking = false } }
        do {
            if let plan = pendingPlan { pendingPlan = nil; try await execute(plan, environment: env) }
            else if let restore = pendingRestore {
                pendingRestore = nil
                let current = try makeEnvironment(), loaded = await worker.load(current)
                guard let receipt = loaded.receipts.first(where: { $0.id == restore.0 }),
                      let endpoint = current.endpoints.first(where: { $0.id == receipt.target.endpointID }),
                      let space = loaded.spaces[endpoint.id]?.first(where: { $0.account == receipt.target.account && $0.organization == receipt.target.organization }) else {
                    throw SessionTransferFailure("原目标空间未能确认，未恢复会话。")
                }
                try beginWrite(); defer { endWrite() }
                let result = try await worker.restore(current, id: restore.0, space: space, undo: restore.1)
                lastVerification = nil
                display(result, environment: current); operationStatus = restore.1 ? "已撤销上次复制。" : "已恢复上次未完成的变更。"; statusMessage = operationStatus
                picked = []
            } else if let id = pendingPreserve {
                pendingPreserve = nil
                let current = try makeEnvironment(), loaded = await worker.load(current)
                guard let receipt = loaded.receipts.first(where: { $0.id == id }),
                      let space = loaded.spaces[receipt.target.endpointID]?.first(where: { $0.account == receipt.target.account && $0.organization == receipt.target.organization }) else {
                    throw SessionTransferFailure("原目标空间未能确认，未结束恢复记录。")
                }
                let result = try await worker.keepCurrentData(current, id: id, space: space)
                display(result, environment: current)
                operationStatus = result.message; statusMessage = operationStatus
            }
            await refresh()
        } catch { await handle(error, environment: env) }
    }

    /// Wait for Claude Desktop to exit, settle for 8s while holding Switcher's profile-switch lock,
    /// then revalidate, back up, write, and verify automatically (Section 4 #1–3 & Section 7 #3).
    func waitForQuitAndSync() {
        guard !isWorking, !isWaitingForQuit, let plan = pendingPlan, let env = environment else { return }
        confirmation = nil
        pendingPlan = nil
        errorMessage = nil
        statusMessage = nil
        do {
            try beginWrite(reason: "等待 Claude 退出以同步会话…")
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        waitPhase = .waitingForQuit
        waitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.waitPhase = .idle
                self.waitTask = nil
                self.endWrite()
            }
            do {
                while !Task.isCancelled {
                    let running = try await self.worker.isDesktopRunning(for: plan.target, in: env)
                    self.desktopRunning = running
                    if running {
                        self.waitPhase = .waitingForQuit
                        try await Task.sleep(nanoseconds: self.waitPollNanoseconds)
                        continue
                    }
                    // Claude exited: settle countdown (default 8s), aborting back to waiting if reopened.
                    var restarted = false
                    for remaining in stride(from: self.settleSeconds, through: 1, by: -1) {
                        guard !Task.isCancelled else { return }
                        self.waitPhase = .settling(remaining)
                        try await Task.sleep(nanoseconds: self.waitPollNanoseconds)
                        if try await self.worker.isDesktopRunning(for: plan.target, in: env) {
                            restarted = true
                            self.desktopRunning = true
                            break
                        }
                    }
                    if restarted { continue }
                    guard !Task.isCancelled else { return }
                    self.waitPhase = .writing
                    self.store.busy = "正在同步并核对会话索引…"
                    try await self.performExecuteLocked(plan, environment: env)
                    self.isWorking = true
                    self.waitPhase = .idle
                    self.endWrite()
                    await self.refresh()
                    return
                }
            } catch is CancellationError {
                self.statusMessage = "已取消等待，未写入会话。"
            } catch {
                self.waitPhase = .idle
                self.endWrite()
                await self.handle(error, environment: env)
            }
        }
    }

    func cancelWaiting() {
        guard isWaitingForQuit else { return }
        waitTask?.cancel()
        waitTask = nil
        waitPhase = .idle
        endWrite()
        statusMessage = "已取消等待，未写入会话。"
    }

    func dismissConfirmation() { confirmation = nil }
    func cancelConfirmation() { confirmation = nil; pendingPlan = nil; pendingRestore = nil; pendingPreserve = nil }

    private func beginWrite(reason: String = "正在复制或恢复会话索引…") throws {
        guard !store.updating else { throw SessionTransferFailure("应用正在更新，请稍后复制。") }
        guard store.busy == nil else { throw SessionTransferFailure("账号操作正在进行，请稍后复制。") }
        writing = true; store.busy = reason
    }
    private func endWrite() {
        if writing {
            writing = false
            store.busy = nil
        }
    }

    private func execute(_ plan: SessionTransferPlan, environment env: SessionTransferEnvironment) async throws {
        try beginWrite(); defer { endWrite() }
        try await performExecuteLocked(plan, environment: env)
    }

    private func performExecuteLocked(_ plan: SessionTransferPlan, environment env: SessionTransferEnvironment) async throws {
        // Resolving again catches a profile-directory rotation while a confirmation or wait was open.
        let fresh = try makeEnvironment()
        guard fresh.endpoints == env.endpoints else { throw SessionTransferFailure("账号档案已变化，请重新选择。") }
        let result = try await worker.execute(fresh, plan)
        let verification = try? await worker.verify(fresh, receipt: result, target: plan.target)
        lastVerification = verification
        display(result, environment: fresh); picked = []
        completedSnapshot = SessionCopyResultSnapshot(operationID: result.id, sourceSpaceID: plan.source.id,
            targetSpaceID: plan.target.id, rows: plan.rows, forkResolutions: plan.forkResolutions)
        query = ""
        if result.parkedCount > 0 {
            operationStatus = "已复制\(result.addedCount)条、更新\(result.updatedCount)条、另存旧分支\(result.parkedCount)条会话。"
        } else {
            operationStatus = "已复制\(result.addedCount)条、更新\(result.updatedCount)条会话。"
        }
        statusMessage = operationStatus
        if fresh.activeEndpointIDs.contains(plan.target.endpoint.id) && reopenSeconds > 0 {
            startReopenCountdown()
        }
    }

    private func startReopenCountdown() {
        reopenTask?.cancel()
        reopenCountdown = reopenSeconds
        reopenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.reopenCountdown > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.reopenCountdown = max(0, self.reopenCountdown - 1)
            }
        }
    }

    private func display(_ receipt: SessionTransferReceipt, environment env: SessionTransferEnvironment) {
        latestReceipt = receipt
        let summary: String
        switch receipt.state {
        case .completed:
            summary = receipt.parkedCount > 0
                ? "新增\(receipt.addedCount)条、更新\(receipt.updatedCount)条、另存旧分支\(receipt.parkedCount)条，已完成"
                : "新增\(receipt.addedCount)条、更新\(receipt.updatedCount)条，已完成"
        case .undone: summary = "已撤销，恢复之前的列表"
        case .restored: summary = "复制未完成，本次改动已恢复"
        case .preserved: summary = receipt.message ?? "已保留当前数据并结束记录，未执行恢复"
        case .copying, .restoring, .recoveryRequired: summary = "操作未完成，请先检查恢复记录"
        }
        lastOperation = SessionTransferOperation(id: receipt.id, targetName: receipt.targetName, title: receipt.state.needsRecovery ? "上次操作需要恢复" : "上次同步",
            summary: receipt.targetName + "：" + summary,
            canUndo: receipt.state == .completed, needsRecovery: receipt.state.needsRecovery,
            backupURL: env.backups.appendingPathComponent(receipt.id),
            items: receipt.items.map { TransferSessionItem(id: $0.name, title: $0.title, cwd: $0.cwd ?? "", kind: $0.kind, parkedFrom: $0.parkedFrom) },
            state: receipt.state)
    }

    private func handle(_ error: Error, environment env: SessionTransferEnvironment) async {
        errorMessage = error.localizedDescription
        let loaded = await worker.load(env)
        if let id = (error as? SessionTransferFailure)?.receiptID, let receipt = loaded.receipts.first(where: { $0.id == id }) { display(receipt, environment: env) }
        else if let receipt = preferredReceipt(loaded.receipts) { display(receipt, environment: env) }
        historyError = loaded.historyError
    }

    func requestUndo() {
        guard !isWorking, !isWaitingForQuit, let last = lastOperation, last.canUndo else { return }
        pendingRestore = (last.id, true); pendingPlan = nil; pendingPreserve = nil
        confirmation = SessionTransferConfirmation(title: "撤销上次同步？", message: "仅在目标未被后来修改时恢复；如有新进展会整批停止，不覆盖新数据。", buttonTitle: "确认撤销", kind: "undo", items: last.items)
    }

    func requestRecovery() {
        guard !isWorking, !isWaitingForQuit, let last = lastOperation, last.needsRecovery else { return }
        pendingRestore = (last.id, false); pendingPlan = nil; pendingPreserve = nil
        confirmation = SessionTransferConfirmation(title: "恢复未完成的同步？", message: "先核对原目标与备份。遇到外部新进展就停止，不强行覆盖。", buttonTitle: "检查并恢复", kind: "recovery", items: last.items)
    }

    func requestKeepCurrent() {
        guard !isWorking, !isWaitingForQuit, let last = lastOperation, last.needsRecovery else { return }
        pendingPreserve = last.id; pendingPlan = nil; pendingRestore = nil
        confirmation = SessionTransferConfirmation(title: "保留当前数据并结束恢复？", message: "不会还原或删除任何会话，也不会删除已有备份。这次操作不视为已完整恢复；后续同步仍会重新核验冲突。", buttonTitle: "保留现状", kind: "preserve", items: last.items)
    }

    func showBackup() {
        guard !isWorking, !isWaitingForQuit, let last = lastOperation, let env = environment else { return }
        let intent = refreshID
        backupItems = []; backupInformation = "正在核对备份…"; isWorking = true
        Task {
            defer { if refreshID == intent { isWorking = false } }
            do {
                let receipt = try await worker.backup(env, id: last.id)
                guard refreshID == intent, backupInformation != nil else { return }
                backupItems = receipt.items.map { TransferSessionItem(id: $0.name, title: $0.title, cwd: $0.cwd ?? "", kind: $0.kind, parkedFrom: $0.parkedFrom) }
                backupInformation = "备份已核对；只包含本次索引变更，不包含聊天原文。"
            } catch {
                guard refreshID == intent, backupInformation != nil else { return }
                backupInformation = "备份无法核对：" + error.localizedDescription
            }
        }
    }
    func dismissBackup() { backupInformation = nil }
    func dismissHandoff() { handoffInformation = nil }
    func exportInstructions() async {
        handoffInformation = await generateInstructions()
    }
    /// Produces local text only. Clipboard presentation belongs to the view.
    func generateInstructions() async -> String? {
        guard canExport, let env = environment, let source = chosen(sourceSpaceID), let target = chosen(targetSpaceID) else { return nil }
        let intent = refreshID
        let selected = effectiveSelectedIDs
        let identities = Dictionary(uniqueKeysWithValues: rows.filter { selected.contains($0.id) }.map { ($0.id, $0.identity) })
        isWorking = true; errorMessage = nil
        defer { if refreshID == intent { isWorking = false } }
        do {
            guard FileManager.default.isExecutableFile(atPath: commandURL.path) else {
                throw SessionTransferFailure("未找到备用复制工具，请使用完整构建的应用。")
            }
            let plan = try await worker.plan(env, source: source, target: target, selected: selected, updates: updateExisting,
                                             expectedSourceIdentities: identities, newSince: effectiveNewSince,
                                             forkResolutions: forkResolutions)
            guard refreshID == intent else { throw SessionTransferFailure("选择已变化，请重新生成指令。") }
            return try await worker.saveInstructions(env, plan: plan, command: commandURL)
        } catch { errorMessage = error.localizedDescription; return nil }
    }
}
