import AppKit
import SwiftUI
import Combine
import SwitcherCore

struct TransferLocationOption: Identifiable, Sendable { let id: String; let name: String }
struct TransferSpaceOption: Identifiable, Sendable {
    let space: SessionTransferSpace
    let matchesProfile: Bool
    let profileName: String?
    let accountName: String?
    let organizationName: String?
    let count: Int?
    let title: String?
    var accountEmail: String? = nil
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
}

private struct SessionCopyResultSnapshot {
    let operationID: String
    let sourceSpaceID: String
    let targetSpaceID: String
    let rows: [SessionTransferRow]
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
    func load(_ env: SessionTransferEnvironment) -> SessionTransferLoaded {
        let engine = service(env)
        var spaces: [String: [SessionTransferSpace]] = [:], errors: [String: String] = [:]
        var options: [String: [TransferSpaceOption]] = [:]
        let localNames = TransferAccountNames(document: env.cliMetadataDocument)
        for endpoint in env.endpoints {
            do {
                let discovered = try engine.spaces(in: endpoint)
                spaces[endpoint.id] = discovered
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
                    let preview = discovered.count > 1 ? try? engine.spacePreview(space) : nil
                    return TransferSpaceOption(space: space, matchesProfile: matches, profileName: profileName,
                        accountName: (accountMatches ? localNames?.account : nil)
                            ?? (accountProfiles.count == 1 ? accountProfiles.first?.name : nil),
                        organizationName: organizationMatches ? localNames?.organization : nil,
                        count: preview?.count, title: preview?.title, accountEmail: email)
                }
            }
            catch { spaces[endpoint.id] = []; errors[endpoint.id] = error.localizedDescription }
        }
        do { return SessionTransferLoaded(spaces: spaces, options: options, errors: errors, receipts: try engine.receipts(), historyError: nil) }
        catch { return SessionTransferLoaded(spaces: spaces, options: options, errors: errors, receipts: [], historyError: "备份记录无法确认，已停止新复制。备份位置：\(env.backups.path)") }
    }
    func rows(_ env: SessionTransferEnvironment, source: SessionTransferSpace, target: SessionTransferSpace, updates: Bool) throws -> [SessionTransferRow] {
        try service(env).rows(source: source, target: target, updateExisting: updates)
    }
    func plan(_ env: SessionTransferEnvironment, source: SessionTransferSpace, target: SessionTransferSpace, selected: Set<String>, updates: Bool, expectedSourceIdentities: [String: String]) async throws -> SessionTransferPlan {
        await beforePlan()
        return try service(env).plan(source: source, target: target, selected: selected, updateExisting: updates, expectedSourceIdentities: expectedSourceIdentities)
    }
    private func idle(_ env: SessionTransferEnvironment, _ target: SessionTransferSpace) throws {
        if env.activeEndpointIDs.contains(target.endpoint.id), try runningProbe() {
            throw SessionTransferFailure("请先保存工作并自行退出 Claude，再重新检查后复制；本工具不会自动结束桌面或 CLI 任务。")
        }
    }
    func execute(_ env: SessionTransferEnvironment, _ plan: SessionTransferPlan) throws -> SessionTransferReceipt {
        try service(env).execute(plan, requireIdle: { try self.idle(env, plan.target) })
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
    @Published var query = ""
    @Published private(set) var updateExisting = true
    @Published private(set) var newSessionAgeDays: Int? = 30
    @Published private(set) var customNewSince: Date?
    @Published var showsCustomNewDate = false
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmation: SessionTransferConfirmation?
    @Published private(set) var lastOperation: SessionTransferOperation?
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
    private var loadedNewSessionAgeDays: Int??
    private let demoRoot: URL?
    private let commandURL: URL

    init(store: Store, testEnvironment: SessionTransferEnvironment? = nil, worker: SessionTransferWorker? = nil, commandURL: URL? = nil) {
        self.store = store
        self.commandURL = commandURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeSessionTransfer")
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
    deinit { if let demoRoot { try? FileManager.default.removeItem(at: demoRoot) } }
    var visibleRows: [SessionTransferRow] {
        let displayed = isShowingCopyResult ? completedSnapshot?.rows ?? rows : rows
        return displayed.filter { row in
            matchesQuery(row) && newAdditionsIncludes(row)
        }
    }
    var hiddenOlderAdditionsCount: Int {
        guard !isShowingCopyResult else { return 0 }
        return rows.filter { $0.kind == .add && matchesQuery($0) && !newAdditionsIncludes($0) }.count
    }
    private func matchesQuery(_ row: SessionTransferRow) -> Bool {
        query.isEmpty || "\(row.title) \(row.cwd) \(resultItem(for: row)?.title ?? "")".localizedCaseInsensitiveContains(query)
    }
    private var newAdditionsCutoff: Date {
        if showsCustomNewDate, let customNewSince { return customNewSince }
        guard let newSessionAgeDays else { return .distantPast }
        return Date().addingTimeInterval(-Double(newSessionAgeDays) * 86400)
    }
    private func newAdditionsIncludes(_ row: SessionTransferRow) -> Bool {
        row.kind != .add || newSessionAgeDays == nil || row.lastActivity >= newAdditionsCutoff
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
    }
    var canCopy: Bool { !isShowingCopyResult && !isWorking && !picked.isEmpty && sourceSpaceID != targetSpaceID && !sourceSpaceID.isEmpty && !targetSpaceID.isEmpty && historyError == nil && !recoveryBlocksTarget }
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
        picked = []; pendingPlan = nil; pendingRestore = nil; pendingPreserve = nil; confirmation = nil
        preselectMissing = true
        errorMessage = nil; statusMessage = nil; operationStatus = nil
    }
    private func queueRefresh(selectUpdates: Bool = false) {
        refreshID = UUID() // invalidate an older in-flight scan before the next Task starts
        isWorking = true
        Task { await refresh(selectUpdates: selectUpdates) }
    }
    func setSource(_ id: String) { guard !isWorking, id != sourceID else { return }; sourceID = id; sourceSpaceID = ""; clearSelection(); queueRefresh() }
    func setTarget(_ id: String) { guard !isWorking, id != targetID else { return }; targetID = id; targetSpaceID = ""; clearSelection(); queueRefresh() }
    func setSourceSpace(_ id: String) { guard !isWorking, id != sourceSpaceID else { return }; sourceSpaceID = id; clearSelection(); queueRefresh() }
    func setTargetSpace(_ id: String) { guard !isWorking, id != targetSpaceID else { return }; targetSpaceID = id; clearSelection(); queueRefresh() }
    func setUpdates(_ value: Bool) {
        guard !isWorking else { return }
        completedSnapshot = nil
        updateExisting = value
        if !value { picked.subtract(rows.filter { $0.kind == .update }.map(\.id)) }
        pendingPlan = nil; confirmation = nil; queueRefresh(selectUpdates: value)
    }
    func setNewSessionAge(_ days: Int?) {
        guard !writing, days != newSessionAgeDays else { return }
        newSessionAgeDays = days
        showsCustomNewDate = false
        picked.subtract(rows.filter { $0.kind == .add && !newAdditionsIncludes($0) }.map(\.id))
    }
    func setCustomNewDate(_ date: Date) {
        guard !writing else { return }
        customNewSince = Calendar.current.startOfDay(for: date)
        showsCustomNewDate = true
    }
    func swapDirection() {
        guard !isWorking, !sourceID.isEmpty, !targetID.isEmpty, sourceID != targetID,
              locations.contains(where: { $0.id == sourceID }),
              locations.contains(where: { $0.id == targetID }) else { return }
        swap(&sourceID, &targetID)
        swap(&sourceSpaceID, &targetSpaceID)
        clearSelection(); queueRefresh()
    }
    func setPicked(_ id: String, selected: Bool) {
        guard !isWorking, !isShowingCopyResult, let row = rows.first(where: { $0.id == id }), row.selectable else { return }
        if selected { picked.insert(id) } else { picked.remove(id) }
    }
    func selectAllVisible() {
        guard !isWorking, !isShowingCopyResult else { return }
        let ids = Set(visibleRows.filter(\.selectable).map(\.id))
        if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }
    func beginAnotherCopy() {
        guard !isWorking else { return }
        clearSelection(); query = ""; queueRefresh()
    }
    func refresh(selectUpdates: Bool = false) async {
        guard !writing else { return }
        let token = UUID(); refreshID = token; isWorking = true
        defer { if refreshID == token { isWorking = false } }
        do {
            let env = try makeEnvironment()
            let loaded = await worker.load(env)
            guard refreshID == token, !writing else { return }
            environment = env; spaces = loaded.spaces; historyError = loaded.historyError
            locations = env.endpoints.map { TransferLocationOption(id: $0.id, name: $0.name) }
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
                rows = []; picked = []; statusMessage = nil; errorMessage = historyError
                return
            }
            guard let source = a.first(where: { $0.id == sourceSpaceID }), let target = b.first(where: { $0.id == targetSpaceID }), source.id != target.id else {
                rows = []; errorMessage = loaded.errors[sourceID] ?? loaded.errors[targetID] ?? historyError
                statusMessage = sourceSpaces.isEmpty || targetSpaces.isEmpty ? "请先在相应账号或 API 工作区打开 Code 页，再重新检查。" : "请选择不同的来源和目标空间。"
                return
            }
            let result = try await worker.rows(env, source: source, target: target, updates: updateExisting)
            guard refreshID == token, !writing else { return }
            let scope = source.id + "\n" + target.id
            if loadedSelectionScope != scope {
                picked = []; preselectMissing = true; loadedSelectionScope = scope
            }
            rows = result
            if preselectMissing {
                picked = Set(visibleRows.filter { $0.selectable && !$0.continuation && newAdditionsIncludes($0) }.map(\.id))
                preselectMissing = false
            } else {
                picked.formIntersection(result.filter(\.selectable).map(\.id))
            }
            if selectUpdates && updateExisting {
                picked.formUnion(visibleRows.filter { $0.kind == .update && !$0.continuation }.map(\.id))
            }
            statusMessage = operationStatus; errorMessage = historyError
        } catch {
            guard refreshID == token else { return }
            rows = []; picked = []; errorMessage = error.localizedDescription
        }
    }
    private func chosen(_ id: String) -> SessionTransferSpace? { spaces.values.flatMap { $0 }.first { $0.id == id } }
    func copySelected() async {
        guard canCopy, let env = environment, let source = chosen(sourceSpaceID), let target = chosen(targetSpaceID) else { return }
        let intent = refreshID
        let expectedSourceIdentities = Dictionary(uniqueKeysWithValues: rows.filter { picked.contains($0.id) }.map { ($0.id, $0.identity) })
        isWorking = true; errorMessage = nil; statusMessage = nil; operationStatus = nil
        defer { if refreshID == intent { isWorking = false } }
        do {
            let plan = try await worker.plan(env, source: source, target: target, selected: picked, updates: updateExisting, expectedSourceIdentities: expectedSourceIdentities)
            guard refreshID == intent else { statusMessage = "选择或空间已变化，请重新复制。"; return }
            if plan.updatedCount > 0 {
                pendingPlan = plan
                let items = plan.changes.map { change in
                    let row = plan.rows.first { $0.id == change.name }
                    return TransferSessionItem(id: change.name, title: change.title, cwd: row?.cwd ?? "", kind: change.kind, continuation: row?.continuation ?? false)
                }
                confirmation = SessionTransferConfirmation(title: "更新已有会话？", message: "将新增\(plan.addedCount)条、更新\(plan.updatedCount)条列表索引。旧索引会先自动备份，聊天原文不变。", buttonTitle: "确认复制", kind: "copy",
                    items: items.filter(\.continuation) + items.filter { !$0.continuation }, addedCount: plan.addedCount, updatedCount: plan.updatedCount,
                    continuationCount: items.filter(\.continuation).count)
            } else { try await execute(plan, environment: env); await refresh() }
        } catch { await handle(error, environment: env) }
    }
    func confirmAction() async {
        guard !isWorking else { errorMessage = "正在处理，请重新确认后再执行。"; cancelConfirmation(); return }
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
    func dismissConfirmation() { confirmation = nil }
    func cancelConfirmation() { confirmation = nil; pendingPlan = nil; pendingRestore = nil; pendingPreserve = nil }
    private func beginWrite() throws {
        guard !store.updating else { throw SessionTransferFailure("应用正在更新，请稍后复制。") }
        guard store.busy == nil else { throw SessionTransferFailure("账号操作正在进行，请稍后复制。") }
        writing = true; store.busy = "正在复制或恢复会话索引…"
    }
    private func endWrite() { writing = false; store.busy = nil }
    private func execute(_ plan: SessionTransferPlan, environment env: SessionTransferEnvironment) async throws {
        try beginWrite(); defer { endWrite() }
        // Resolving again catches a profile-directory rotation while an update confirmation was open.
        let fresh = try makeEnvironment()
        guard fresh.endpoints == env.endpoints else { throw SessionTransferFailure("账号档案已变化，请重新选择。") }
        let result = try await worker.execute(fresh, plan)
        display(result, environment: fresh); picked = []
        completedSnapshot = SessionCopyResultSnapshot(operationID: result.id, sourceSpaceID: plan.source.id,
            targetSpaceID: plan.target.id, rows: plan.rows)
        query = ""
        operationStatus = "已复制\(result.addedCount)条、更新\(result.updatedCount)条会话。"; statusMessage = operationStatus
    }
    private func display(_ receipt: SessionTransferReceipt, environment env: SessionTransferEnvironment) {
        latestReceipt = receipt
        let summary: String
        switch receipt.state {
        case .completed: summary = "新增\(receipt.addedCount)条、更新\(receipt.updatedCount)条，已完成"
        case .undone: summary = "已撤销，恢复之前的列表"
        case .restored: summary = "复制未完成，本次改动已恢复"
        case .preserved: summary = receipt.message ?? "已保留当前数据并结束记录，未执行恢复"
        case .copying, .restoring, .recoveryRequired: summary = "操作未完成，请先检查恢复记录"
        }
        lastOperation = SessionTransferOperation(id: receipt.id, targetName: receipt.targetName, title: receipt.state.needsRecovery ? "上次操作需要恢复" : "上次复制",
            summary: receipt.targetName + "：" + summary,
            canUndo: receipt.state == .completed, needsRecovery: receipt.state.needsRecovery,
            backupURL: env.backups.appendingPathComponent(receipt.id),
            items: receipt.items.map { TransferSessionItem(id: $0.name, title: $0.title, cwd: $0.cwd ?? "", kind: $0.kind) }, state: receipt.state)
    }
    private func handle(_ error: Error, environment env: SessionTransferEnvironment) async {
        errorMessage = error.localizedDescription
        let loaded = await worker.load(env)
        if let id = (error as? SessionTransferFailure)?.receiptID, let receipt = loaded.receipts.first(where: { $0.id == id }) { display(receipt, environment: env) }
        else if let receipt = preferredReceipt(loaded.receipts) { display(receipt, environment: env) }
        historyError = loaded.historyError
    }
    func requestUndo() {
        guard !isWorking, let last = lastOperation, last.canUndo else { return }
        pendingRestore = (last.id, true); pendingPlan = nil; pendingPreserve = nil
        confirmation = SessionTransferConfirmation(title: "撤销上次复制？", message: "仅在目标未被后来修改时恢复；如有新进展会整批停止，不覆盖新数据。", buttonTitle: "确认撤销", kind: "undo", items: last.items)
    }
    func requestRecovery() {
        guard !isWorking, let last = lastOperation, last.needsRecovery else { return }
        pendingRestore = (last.id, false); pendingPlan = nil; pendingPreserve = nil
        confirmation = SessionTransferConfirmation(title: "恢复未完成的复制？", message: "先核对原目标与备份。遇到外部新进展就停止，不强行覆盖。", buttonTitle: "检查并恢复", kind: "recovery", items: last.items)
    }
    func requestKeepCurrent() {
        guard !isWorking, let last = lastOperation, last.needsRecovery else { return }
        pendingPreserve = last.id; pendingPlan = nil; pendingRestore = nil
        confirmation = SessionTransferConfirmation(title: "保留当前数据并结束恢复？", message: "不会还原或删除任何会话，也不会删除已有备份。这次操作不视为已完整恢复；后续复制仍会重新核验冲突。", buttonTitle: "保留现状", kind: "preserve", items: last.items)
    }
    func showBackup() {
        guard !isWorking, let last = lastOperation, let env = environment else { return }
        let intent = refreshID
        backupItems = []; backupInformation = "正在核对备份…"; isWorking = true
        Task {
            defer { if refreshID == intent { isWorking = false } }
            do {
                let receipt = try await worker.backup(env, id: last.id)
                guard refreshID == intent, backupInformation != nil else { return }
                backupItems = receipt.items.map { TransferSessionItem(id: $0.name, title: $0.title, cwd: $0.cwd ?? "", kind: $0.kind) }
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
        let identities = Dictionary(uniqueKeysWithValues: rows.filter { picked.contains($0.id) }.map { ($0.id, $0.identity) })
        isWorking = true; errorMessage = nil
        defer { if refreshID == intent { isWorking = false } }
        do {
            guard FileManager.default.isExecutableFile(atPath: commandURL.path) else {
                throw SessionTransferFailure("未找到备用复制工具，请使用完整构建的应用。")
            }
            let plan = try await worker.plan(env, source: source, target: target, selected: picked, updates: updateExisting, expectedSourceIdentities: identities)
            guard refreshID == intent else { throw SessionTransferFailure("选择已变化，请重新生成指令。") }
            return try await worker.saveInstructions(env, plan: plan, command: commandURL)
        } catch { errorMessage = error.localizedDescription; return nil }
    }
}
