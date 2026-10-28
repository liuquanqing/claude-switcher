import Foundation
import CoreFoundation

public struct SessionTransferService {
    public let transcripts: URL
    public let backups: URL
    let io: SessionTransferIO
    public init(transcripts: URL, backups: URL, io: SessionTransferIO = .init()) {
        self.transcripts = transcripts; self.backups = backups; self.io = io
    }
    typealias Disk = SessionTransferDisk
    struct Index {
        let name: String
        let bytes: Data
        let object: [String: Any]
        let logical: String
        let cli: String
        let cwd: String
        var title: String { object["title"] as? String ?? name }
        var identity: String { Disk.hash(Data((logical + "\n" + cli).utf8)) }
        var turns: Double? { Self.number(object["completedTurns"], integer: true) }
        var time: Double? { Self.number(object["lastActivityAt"]) }
        var archived: Bool { object["isArchived"] as? Bool == true || object["isDeleted"] as? Bool == true }
        static func number(_ value: Any?, integer: Bool = false) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let x = n.doubleValue
            guard x.isFinite, x >= 0, x <= (integer ? Double(Int.max) : Date.distantFuture.timeIntervalSince1970 * 1000), !integer || x.rounded() == x else { return nil }
            return x
        }
        init(name: String, bytes: Data) throws {
            guard Disk.name(name) else { throw SessionTransferFailure("索引文件名无效。") }
            let j = try Disk.json(bytes)
            guard let logical = j["sessionId"] as? String, Disk.segment(logical),
                  let cli = j["cliSessionId"] as? String, Disk.segment(cli),
                  let cwd = j["cwd"] as? String, !cwd.isEmpty else {
                throw SessionTransferFailure("索引缺少可确认的会话标识或项目路径。")
            }
            if j["completedTurns"] != nil && Self.number(j["completedTurns"], integer: true) == nil { throw SessionTransferFailure("会话轮数字段格式未支持。") }
            if j["lastActivityAt"] != nil && Self.number(j["lastActivityAt"]) == nil { throw SessionTransferFailure("会话时间字段格式未支持。") }
            for field in ["isArchived", "isDeleted"] {
                if let value = j[field] {
                    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw SessionTransferFailure("归档/删除字段格式未支持。") }
                }
            }
            self.name = name; self.bytes = bytes; object = j; self.logical = logical; self.cli = cli; self.cwd = cwd
        }
    }
    struct Catalogue {
        var indexes: [String: Index] = [:]
        var unreadable: Set<String> = []
        var fallback: [String: SessionTransferRow] = [:]
        var deleted: Set<String> = []
        var archived: Set<String> = []
    }
    public func spaces(in endpoint: SessionTransferEndpoint) throws -> [SessionTransferSpace] {
        _ = try Disk.identity(endpoint.root, directory: true)
        _ = try Disk.marker(endpoint)
        let sessions = endpoint.root.appendingPathComponent("claude-code-sessions")
        if !FileManager.default.fileExists(atPath: sessions.path) { return [] }
        return try Disk.directories(sessions).flatMap { account in
            try Disk.directories(account).map { SessionTransferSpace(endpoint: endpoint, account: account.lastPathComponent, organization: $0.lastPathComponent) }
        }
    }
    func catalogue(_ space: SessionTransferSpace) throws -> Catalogue {
        _ = try Disk.scope(space); _ = try Disk.marker(space.endpoint)
        var result = Catalogue()
        for file in try FileManager.default.contentsOfDirectory(at: space.directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix("deleted_") { result.deleted.insert(String(name.dropFirst(8))); continue }
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            var metadata: [String: Any]?
            do {
                let bytes = try Disk.data(file); metadata = try Disk.json(bytes)
                result.indexes[name] = try Index(name: name, bytes: bytes)
            } catch {
                result.unreadable.insert(name)
                if let j = metadata {
                    result.fallback[name] = SessionTransferRow(id: name, title: j["title"] as? String ?? name,
                        cwd: j["cwd"] as? String ?? "", lastActivity: Date(timeIntervalSince1970: (Index.number(j["lastActivityAt"]) ?? 0) / 1000),
                        kind: .blocked, reason: "索引格式尚未支持，保留原会话不改。")
                }
            }
        }
        if let bytes = try Disk.optionalData(space.directory.appendingPathComponent("archived-sessions.idx")) {
            let j = try Disk.json(bytes)
            guard let values = j["archived"] as? [String] else { throw SessionTransferFailure("归档列表无法确认，未修改会话。") }
            result.archived = Set(values)
        }
        return result
    }
    func removed(_ index: Index, in c: Catalogue) -> Bool {
        index.archived || c.archived.contains(index.logical) || [index.cli, index.logical, index.cli + ".json", index.logical + ".json"].contains(where: c.deleted.contains)
    }
    func hasTranscript(_ cli: String) throws -> Bool {
        guard Disk.segment(cli) else { return false }
        let projects = try Disk.directories(transcripts)
        var matches = 0
        for project in projects {
            let file = project.appendingPathComponent(cli + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try Disk.identity(file, directory: false)
                guard FileManager.default.isReadableFile(atPath: file.path) else { throw SessionTransferFailure("引用的原文不可读取。") }
                matches += 1
            }
        }
        return matches == 1
    }
    func row(_ index: Index, _ kind: SessionTransferKind, _ reason: String) -> SessionTransferRow {
        SessionTransferRow(id: index.name, title: index.title, cwd: index.cwd,
            lastActivity: Date(timeIntervalSince1970: (index.time ?? Index.number(index.object["createdAt"]) ?? 0) / 1000), kind: kind, reason: reason, identity: index.identity)
    }
    func decision(_ source: Index, sourceCatalogue: Catalogue, target: Catalogue, updates: Bool) throws -> (SessionTransferRow, SessionTransferChange?) {
        func result(_ kind: SessionTransferKind, _ reason: String, before: Data? = nil, after: Data? = nil) -> (SessionTransferRow, SessionTransferChange?) {
            (row(source, kind, reason), after.map { SessionTransferChange(name: source.name, title: source.title, kind: kind, before: before, after: $0) })
        }
        if removed(source, in: sourceCatalogue) || removed(source, in: target) { return result(.blocked, "归档或删除的会话不自动带回。") }
        do {
            guard try hasTranscript(source.cli) else { return result(.blocked, "引用原文缺失或不唯一，不能只复制空索引。") }
            if let value = source.object["priorCliSessionIds"] {
                guard let previous = value as? [String], previous.allSatisfy(Disk.segment) else { return result(.blocked, "历史分段标识格式未支持。") }
                for id in Set(previous) where id != source.cli {
                    guard try hasTranscript(id) else { return result(.blocked, "历史分段原文缺失，暂不自动复制。") }
                }
            }
        } catch { return result(.blocked, "引用原文不可读取，保留该会话不改。") }
        guard target.unreadable.isEmpty else { return result(.blocked, "目标有不可读索引，不能把未知记录当作不存在。") }
        let related = target.indexes.values.filter { $0.logical == source.logical || $0.cli == source.cli || $0.name == source.name }
        guard related.count <= 1 else { return result(.blocked, "目标有多个相关会话，无法唯一确认，保留现状。") }
        if let old = related.first {
            if removed(old, in: target) { return result(.blocked, "目标已归档或删除，保留目标状态。") }
            guard old.logical == source.logical, old.cli == source.cli else {
                return result(.blocked, "同名、分支或续接关系未能确认，不覆盖目标。")
            }
            guard old.name == source.name else { return result(.skip, "目标已有同一会话，保留目标条目。") }
            guard old.cwd == source.cwd else { return result(.blocked, "项目路径不同，不自动改写目标会话。") }
            guard let st = source.turns, let dt = old.turns, let sd = source.time, let dd = old.time else {
                return result(.blocked, "进度字段不完整，不能安全更新。")
            }
            if dt > st || dd > sd { return result(.skip, "目标进度较新，保留目标。") }
            if dt == st && dd == sd { return result(.skip, "目标已同步，无需重复复制。") }
            guard updates else { return result(.skip, "目标已有这段会话；开启更新后可同步列表进度。") }
            var object = old.object
            // Only same-segment progress is portable here. Titles, projects, connectors,
            // unknown target fields and all transcript content remain owned by target.
            object["completedTurns"] = source.object["completedTurns"]
            object["lastActivityAt"] = source.object["lastActivityAt"]
            let after = try Disk.encode(object)
            return result(.update, "只更新同一会话的列表进度；旧索引自动备份。", before: old.bytes, after: after)
        }
        let unsupportedBindings = ["accountUuid", "accountUUID", "accountId", "account_uuid", "organizationUuid", "organizationId", "organization_uuid", "orgUuid",
                                   "oauthAccount", "claudeAiOauth", "accessToken", "refreshToken", "apiKey", "providerConfig", "gatewayConfig"]
        guard !unsupportedBindings.contains(where: { source.object[$0] != nil }) else {
            return result(.blocked, "此索引含未适配的账号或认证绑定，暂不自动跨空间复制。")
        }
        var object = source.object
        for key in ["remoteMcpServersConfig", "bridgeSessionIds", "armedWorkAtQuit", "remoteControlAutoEligible", "steeredByRemoteClient"] { object.removeValue(forKey: key) }
        return result(.add, "新增会话索引，原文保持共享。", after: try Disk.encode(object))
    }
    struct Snapshot {
        let rows: [SessionTransferRow]
        let changes: [String: SessionTransferChange]
        let source: Catalogue
    }
    func snapshot(source: SessionTransferSpace, target: SessionTransferSpace, updates: Bool) throws -> Snapshot {
        let a = try Disk.scope(source), b = try Disk.scope(target)
        guard a.directoryIdentity != b.directoryIdentity else { throw SessionTransferFailure("来源和目标是同一个空间。") }
        let sc = try catalogue(source), tc = try catalogue(target)
        var rows: [SessionTransferRow] = [], changes: [String: SessionTransferChange] = [:]
        for index in sc.indexes.values {
            let value = try decision(index, sourceCatalogue: sc, target: tc, updates: updates)
            rows.append(value.0); changes[index.name] = value.1
        }
        for name in sc.unreadable {
            rows.append(sc.fallback[name] ?? SessionTransferRow(id: name, title: name, cwd: "", lastActivity: .distantPast, kind: .blocked, reason: "索引无法读取或格式尚未支持。"))
        }
        rows.sort { $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }
        return Snapshot(rows: rows, changes: changes, source: sc)
    }
    public func rows(source: SessionTransferSpace, target: SessionTransferSpace, updateExisting: Bool) throws -> [SessionTransferRow] {
        try snapshot(source: source, target: target, updates: updateExisting).rows
    }
    public func plan(source: SessionTransferSpace, target: SessionTransferSpace, selected: Set<String>, updateExisting: Bool, expectedSourceIdentities: [String: String]? = nil) throws -> SessionTransferPlan {
        guard !selected.isEmpty else { throw SessionTransferFailure("请先选择会话。") }
        let ss = try Disk.scope(source), ts = try Disk.scope(target)
        let sm = try Disk.marker(source.endpoint), tm = try Disk.marker(target.endpoint)
        let state = try snapshot(source: source, target: target, updates: updateExisting)
        if let expectedSourceIdentities {
            guard selected.allSatisfy({ name in
                guard let expected = expectedSourceIdentities[name], let actual = state.source.indexes[name]?.identity else { return false }
                return expected == actual
            }) else { throw SessionTransferFailure("来源会话已变化，请重新检查后选择。") }
        }
        let chosenRows = state.rows.filter { selected.contains($0.id) }
        guard chosenRows.count == selected.count else { throw SessionTransferFailure("所选会话已变化，请重新选择。") }
        guard !chosenRows.contains(where: { $0.kind == .blocked }) else { throw SessionTransferFailure("所选会话存在冲突或不可用项，请重新检查。") }
        let changes = selected.sorted().compactMap { state.changes[$0] }
        guard !changes.isEmpty else { throw SessionTransferFailure("这些会话已存在，无需复制。") }
        var logical: Set<String> = [], cli: Set<String> = []
        for name in selected {
            guard let item = state.source.indexes[name], logical.insert(item.logical).inserted, cli.insert(item.cli).inserted else {
                throw SessionTransferFailure("所选会话存在重复身份，请分开处理。")
            }
        }
        let inputParts = selected.sorted().flatMap { name -> [String] in
            let row = chosenRows.first { $0.id == name }!
            let sourceHash = state.source.indexes[name].map { Disk.hash($0.bytes) } ?? "missing"
            let c = state.changes[name]
            return [name, row.kind.rawValue, sourceHash, c?.before.map(Disk.hash) ?? "absent", c.map { Disk.hash($0.after) } ?? "skip"]
        }
        let signature = Disk.hash(Data(inputParts.joined(separator: "\n").utf8))
        return SessionTransferPlan(source: source, target: target, selected: selected, updateExisting: updateExisting,
            rows: state.rows, changes: changes, sourceScope: ss, targetScope: ts, sourceMarker: sm, targetMarker: tm, signature: signature)
    }
    public func revalidate(_ plan: SessionTransferPlan) throws {
        let fresh = try self.plan(source: plan.source, target: plan.target, selected: plan.selected, updateExisting: plan.updateExisting)
        guard fresh.sourceScope == plan.sourceScope, fresh.targetScope == plan.targetScope,
              fresh.sourceMarker == plan.sourceMarker, fresh.targetMarker == plan.targetMarker,
              fresh.signature == plan.signature else { throw SessionTransferFailure("来源或目标已变化，请重新检查后复制。") }
    }
}
