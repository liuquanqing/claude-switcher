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
        var lastTurnEdgeAt: Double? { Self.number(object["lastTurnEdgeAt"]) }
        var latestUserFrameAt: Double? { Self.number(object["latestUserFrameAt"]) }
        var effectiveTurnAt: Double {
            let turn = max(lastTurnEdgeAt ?? 0, latestUserFrameAt ?? 0)
            if turn > 0 { return turn }
            return time ?? Self.number(object["createdAt"]) ?? 0
        }
        var priorCliSessionIds: [String]? { object["priorCliSessionIds"] as? [String] }
        var priorCliSessionLeftAt: [String: Double] {
            guard let raw = object["priorCliSessionLeftAt"] as? [String: Any] else { return [:] }
            var out: [String: Double] = [:]
            for (k, v) in raw {
                if let n = Self.number(v) { out[k] = n }
            }
            return out
        }
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
        var nonCLI: Set<String> = []
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
    public func spacePreview(_ space: SessionTransferSpace) throws -> (count: Int, title: String?) {
        _ = try Disk.scope(space); _ = try Disk.marker(space.endpoint)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: space.directory, includingPropertiesForKeys: Array(keys))
        var count = 0
        var newest: (file: URL, date: Date)?
        for file in files where Disk.name(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            count += 1
            let date = values.contentModificationDate ?? .distantPast
            if let newest, date < newest.date || (date == newest.date && file.lastPathComponent >= newest.file.lastPathComponent) { continue }
            newest = (file, date)
        }
        guard let newest, let metadata = try? Disk.json(Disk.data(newest.file)),
              let rawTitle = metadata["title"] as? String else { return (count, nil) }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return (count, title.isEmpty ? nil : title)
    }

    public func spaceActivity(_ space: SessionTransferSpace) throws -> SessionTransferSpaceActivity {
        let cat = try catalogue(space)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: space.directory, includingPropertiesForKeys: Array(keys))
        var latestModified: Date?
        for file in files where Disk.name(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let mod = values.contentModificationDate else { continue }
            if latestModified == nil || mod > latestModified! { latestModified = mod }
        }
        var activeCount = 0
        var latestMs: Double?
        var earliestMs: Double?
        var newestTitle: String?
        for index in cat.indexes.values where !removed(index, in: cat) {
            activeCount += 1
            guard let ms = index.time, ms > 0 else { continue }
            if earliestMs == nil || ms < earliestMs! { earliestMs = ms }
            if latestMs == nil || ms > latestMs! {
                latestMs = ms
                let trimmed = index.title.trimmingCharacters(in: .whitespacesAndNewlines)
                newestTitle = trimmed.isEmpty ? nil : trimmed
            }
        }
        return SessionTransferSpaceActivity(
            activeCount: activeCount,
            latestActivityAt: latestMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            latestFileModifiedAt: latestModified,
            earliestActiveActivityAt: earliestMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            newestTitle: newestTitle
        )
    }

    public func inferredNewSince(for space: SessionTransferSpace) throws -> Date? {
        try spaceActivity(space).inferredNewSince
    }

    public static func lastKnownAccountUUID(in endpointRoot: URL) -> String? {
        let config = endpointRoot.appendingPathComponent("config.json")
        guard let data = try? Disk.optionalData(config), let obj = try? Disk.json(data),
              let uuid = (obj["lastKnownAccountUuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty else { return nil }
        return uuid
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
                if let j = metadata,
                   let sid = j["sessionId"] as? String, Disk.segment(sid),
                   j["cliSessionId"] == nil || j["cliSessionId"] is NSNull {
                    result.nonCLI.insert(name)
                    result.fallback[name] = SessionTransferRow(id: name, title: j["title"] as? String ?? name,
                        cwd: j["cwd"] as? String ?? "", lastActivity: Date(timeIntervalSince1970: (Index.number(j["lastActivityAt"]) ?? 0) / 1000),
                        kind: .skip, reason: "无本地正文链（草稿或非本地会话），跳过。")
                    continue
                }
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
        index.archived || listed(index, in: c)
    }
    func listed(_ index: Index, in c: Catalogue) -> Bool {
        c.archived.contains(index.logical) || [index.cli, index.logical, index.cli + ".json", index.logical + ".json"].contains(where: c.deleted.contains)
    }
    func removedInTarget(_ source: Index, _ target: Catalogue) -> Bool {
        listed(source, in: target) || target.indexes.values.contains { old in
            (old.logical == source.logical || old.cli == source.cli || old.name == source.name) && removed(old, in: target)
        }
    }
    func hasTranscript(_ cli: String) throws -> Bool { try transcript(cli) != nil }
    func transcript(_ cli: String) throws -> URL? {
        guard Disk.segment(cli) else { return nil }
        let projects = try Disk.directories(transcripts)
        var matches: [URL] = []
        for project in projects {
            let file = project.appendingPathComponent(cli + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try Disk.identity(file, directory: false)
                guard FileManager.default.isReadableFile(atPath: file.path) else { throw SessionTransferFailure("引用的原文不可读取。") }
                matches.append(file)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func modifiedMilliseconds(_ file: URL) throws -> Double {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw SessionTransferFailure("引用的原文不可读取。") }
        return Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
    }
    static let continuationFields = ["cliSessionId", "priorCliSessionIds", "priorCliSessionLeftAt", "rewindEdges", "transcriptModelStates",
                                     "lastAssistantCliSessionId", "lastAssistantUuid", "postTurnSummary", "postTurnSummaryFor",
                                     "completedTurns", "lastActivityAt", "lastTurnEdgeAt", "latestUserFrameAt"]
    static let unsupportedBindings = ["accountUuid", "accountUUID", "accountId", "account_uuid", "organizationUuid", "organizationId", "organization_uuid", "orgUuid",
                                      "oauthAccount", "claudeAiOauth", "accessToken", "refreshToken", "apiKey", "providerConfig", "gatewayConfig"]
    static let transientKeys = ["remoteMcpServersConfig", "bridgeSessionIds", "armedWorkAtQuit", "remoteControlAutoEligible", "steeredByRemoteClient"]
    static func formatLocalDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func deterministicCloneSessionID(seed: String) -> String {
        let digest = Disk.hash(Data(seed.utf8))
        let chars = Array(digest.prefix(32))
        let p1 = String(chars[0..<8])
        let p2 = String(chars[8..<12])
        let p3 = "5" + String(chars[13..<16])
        let variantNibbles: [Character] = ["8", "9", "a", "b"]
        let variant = variantNibbles[(Int(String(chars[16]), radix: 16) ?? 0) % 4]
        let p4 = String(variant) + String(chars[17..<20])
        let p5 = String(chars[20..<32])
        return "local_\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }
    static func parkedTitle(base rawTitle: String, cli: String, account: String) -> String {
        let base = rawTitle.components(separatedBy: "｜旧分支").first ?? rawTitle
        return "\(base)｜旧分支 \(cli.prefix(8))（\(account.prefix(4))）"
    }
    func forkDetails(_ source: Index, target old: Index) -> SessionForkDetails {
        let srcEff = source.effectiveTurnAt
        let dstEff = old.effectiveTurnAt
        let defaultRes: SessionForkResolution = dstEff > srcEff ? .keepTarget : .takeSource
        return SessionForkDetails(
            sourceCliSessionID: source.cli,
            targetCliSessionID: old.cli,
            sourceLastTurnAt: srcEff > 0 ? Date(timeIntervalSince1970: srcEff / 1000) : nil,
            targetLastTurnAt: dstEff > 0 ? Date(timeIntervalSince1970: dstEff / 1000) : nil,
            sourceLastActivityAt: Date(timeIntervalSince1970: (source.time ?? 0) / 1000),
            targetLastActivityAt: Date(timeIntervalSince1970: (old.time ?? 0) / 1000),
            defaultResolution: defaultRes,
            targetTitle: old.title
        )
    }
    func continuation(_ source: Index, from old: Index, updates: Bool) throws -> (SessionTransferKind, String, Data?, SessionForkDetails?) {
        guard old.cwd == source.cwd else { return (.blocked, "两边项目路径不同，不覆盖。", nil, nil) }
        let details = forkDetails(source, target: old)
        // Target moved on from source's chain? Only "target ahead" if source stopped before target left it (R3: 11-10 BP).
        if let targetChain = old.priorCliSessionIds, targetChain.contains(source.cli) {
            if let leftAt = old.priorCliSessionLeftAt[source.cli],
               let sd = source.time, sd <= leftAt,
               let sourceTranscript = try transcript(source.cli),
               try modifiedMilliseconds(sourceTranscript) <= leftAt {
                return (.skip, "目标进度较新，保留目标。", nil, nil)
            }
            return (.fork, "来源在目标离开旧链后继续聊过，已分叉。", nil, details)
        }
        // Source moved on from target's chain? Only linear continuation if target stopped <= leftAt (R1 & R7).
        // Never compare completedTurns across identities: turn counters are per-identity and incomparable.
        if let chain = source.priorCliSessionIds, chain.contains(old.cli) {
            if let oldPrior = old.object["priorCliSessionIds"] {
                guard let oldPriorList = oldPrior as? [String],
                      let idx = chain.firstIndex(of: old.cli),
                      Array(chain.prefix(idx)) == oldPriorList else {
                    return (.fork, "历史链前缀不一致，已分叉。", nil, details)
                }
            }
            guard let leftAt = source.priorCliSessionLeftAt[old.cli] else {
                return (.fork, "缺少切换时刻，无法确认是否分叉，请按分叉处理。", nil, details)
            }
            guard let dd = old.time else {
                return (.fork, "目标缺少活动时间，无法确认是否分叉，请按分叉处理。", nil, details)
            }
            guard dd <= leftAt else {
                return (.fork, "目标在来源离开旧链后继续聊过，已分叉。", nil, details)
            }
            if let oldTranscript = try transcript(old.cli), try modifiedMilliseconds(oldTranscript) > leftAt {
                return (.fork, "旧链原文在切换后仍有写入，已分叉。", nil, details)
            }
            guard updates else { return (.skip, "目标停在旧记录；开启更新后可接上。", nil, nil) }
            var object = old.object
            // The segment chain is one unit: references, rewind edges, model state and progress
            // move together. Titles, settings, connectors and unknown target fields stay with the target.
            for key in Self.continuationFields { object[key] = source.object[key] }
            return (.update, "来源换了新记录继续聊过，勾选后目标会接上，标题与设置保留。", try Disk.encode(object), nil)
        }
        // Neither chain contains the other -> FORK (Section 3).
        return (.fork, "两边对话链互不相关，已分叉。", nil, details)
    }
    func row(_ index: Index, _ kind: SessionTransferKind, _ reason: String, continuation: Bool = false,
             fork: SessionForkDetails? = nil, skippedByCutoff: Bool = false) -> SessionTransferRow {
        SessionTransferRow(id: index.name, title: index.title, cwd: index.cwd,
            lastActivity: Date(timeIntervalSince1970: (index.time ?? Index.number(index.object["createdAt"]) ?? 0) / 1000), kind: kind, reason: reason,
            identity: index.identity, continuation: continuation, fork: fork, skippedByCutoff: skippedByCutoff)
    }
    func decision(_ source: Index, sourceCatalogue: Catalogue, target: Catalogue, updates: Bool, newSince: Date? = nil) throws -> (SessionTransferRow, SessionTransferChange?) {
        func result(_ kind: SessionTransferKind, _ reason: String, before: Data? = nil, after: Data? = nil, destinationTitle: String? = nil,
                    continuation: Bool = false, fork: SessionForkDetails? = nil, skippedByCutoff: Bool = false) -> (SessionTransferRow, SessionTransferChange?) {
            (row(source, kind, reason, continuation: continuation, fork: fork, skippedByCutoff: skippedByCutoff),
             after.map { SessionTransferChange(name: source.name, title: destinationTitle ?? source.title, kind: kind, before: before, after: $0) })
        }
        if removed(source, in: sourceCatalogue) {
            return result(.skip, removedInTarget(source, target) ? "两边都已归档或删除，保持现状。" : "来源已归档或删除，不复制。")
        }
        if listed(source, in: target) { return result(.skip, "目标已归档或删除，保留目标状态。") }
        do {
            guard try hasTranscript(source.cli) else { return result(.blocked, "聊天记录文件缺失或重复，无法复制。") }
            if let value = source.object["priorCliSessionIds"] {
                guard let previous = value as? [String], previous.allSatisfy(Disk.segment) else { return result(.blocked, "历史分段标识格式未支持。") }
                for id in Set(previous) where id != source.cli {
                    guard try hasTranscript(id) else { return result(.blocked, "早期聊天记录文件缺失，无法复制。") }
                }
            }
        } catch { return result(.blocked, "引用原文不可读取，保留该会话不改。") }
        guard target.unreadable.isEmpty else { return result(.blocked, "目标里有无法读取的记录，为免误判，暂不复制。") }
        if target.nonCLI.contains(source.name) { return result(.blocked, "目标已有同名非本地会话，不覆盖。") }
        let primaryMatches = target.indexes.values.filter { $0.logical == source.logical || $0.name == source.name }
        guard primaryMatches.count <= 1 else { return result(.blocked, "目标有多个相关会话，无法唯一确认，保留现状。") }
        if let old = primaryMatches.first {
            if removed(old, in: target) { return result(.skip, "目标已归档或删除，保留目标状态。") }
            if old.logical == source.logical, old.cli != source.cli, old.name == source.name {
                let (kind, reason, after, forkInfo) = try continuation(source, from: old, updates: updates)
                return result(kind, reason, before: after == nil ? nil : old.bytes, after: after, destinationTitle: old.title, continuation: kind == .update, fork: forkInfo)
            }
            guard old.logical == source.logical else {
                return result(.blocked, "目标同名文件属于不同会话，不覆盖。")
            }
            guard old.cli == source.cli else {
                return result(.blocked, "无法确认是同一段对话，不覆盖。")
            }
            guard old.name == source.name else { return result(.skip, "目标已有同一会话，保留目标条目。") }
            guard old.cwd == source.cwd else { return result(.blocked, "两边项目路径不同，不覆盖。") }
            // R2 & R6: On the same chain, check lastActivityAt BEFORE turns.
            // If target was active later, target is newer even if source has more turns (turns are per-identity).
            if let sd = source.time, let dd = old.time, dd > sd {
                return result(.skip, "目标进度较新，保留目标。")
            }
            if source.turns == nil, old.turns == nil, let sd = source.time, old.time == sd {
                return result(.skip, "目标已同步，无需重复复制。")
            }
            guard let st = source.turns, let dt = old.turns, source.time != nil, old.time != nil else {
                return result(.blocked, "缺少可比较的进度，不覆盖。")
            }
            if dt > st { return result(.skip, "目标进度较新，保留目标。") }
            if dt == st { return result(.skip, "目标已同步，无需重复复制。") }
            guard updates else { return result(.skip, "目标已有这段会话；开启更新后可同步列表进度。") }
            var object = old.object
            // Only same-segment progress is portable here. Titles, projects, connectors,
            // unknown target fields and all transcript content remain owned by target.
            object["completedTurns"] = source.object["completedTurns"]
            object["lastActivityAt"] = source.object["lastActivityAt"]
            if let edge = source.object["lastTurnEdgeAt"] { object["lastTurnEdgeAt"] = edge }
            if let frame = source.object["latestUserFrameAt"] { object["latestUserFrameAt"] = frame }
            let after = try Disk.encode(object)
            return result(.update, "只更新同一会话的列表进度；旧索引自动备份。", before: old.bytes, after: after, destinationTitle: old.title)
        }
        // R5 (11-13): Target has no entry with this sessionId/filename, but another target entry
        // already references the same cliSessionId (e.g. a parked 旧分支 clone). Skip to avoid duplicates.
        let cliMatches = target.indexes.values.filter { $0.cli == source.cli }
        if !cliMatches.isEmpty {
            if cliMatches.contains(where: { removed($0, in: target) }) {
                return result(.skip, "目标已归档或删除，保留目标状态。")
            }
            return result(.skip, "目标已有条目引用同一正文链，跳过以避免重复。")
        }
        if let newSince {
            let activity = Date(timeIntervalSince1970: (source.time ?? Index.number(source.object["createdAt"]) ?? 0) / 1000)
            if activity < newSince {
                return result(.skip, "早于新增截止日期（\(Self.formatLocalDay(newSince))），跳过。", skippedByCutoff: true)
            }
        }
        guard !Self.unsupportedBindings.contains(where: { source.object[$0] != nil }) else {
            return result(.blocked, "此索引含未适配的账号或认证绑定，暂不自动跨空间复制。")
        }
        var object = source.object
        for key in Self.transientKeys { object.removeValue(forKey: key) }
        return result(.add, "新增会话索引，原文保持共享。", after: try Disk.encode(object))
    }
    struct Snapshot {
        let rows: [SessionTransferRow]
        let changes: [String: SessionTransferChange]
        let source: Catalogue
        let target: Catalogue
    }
    func snapshot(source: SessionTransferSpace, target: SessionTransferSpace, updates: Bool, newSince: Date? = nil) throws -> Snapshot {
        let a = try Disk.scope(source), b = try Disk.scope(target)
        guard a.directoryIdentity != b.directoryIdentity else { throw SessionTransferFailure("来源和目标是同一个空间。") }
        let sc = try catalogue(source), tc = try catalogue(target)
        var rows: [SessionTransferRow] = [], changes: [String: SessionTransferChange] = [:]
        for index in sc.indexes.values {
            let value = try decision(index, sourceCatalogue: sc, target: tc, updates: updates, newSince: newSince)
            rows.append(value.0); changes[index.name] = value.1
        }
        for name in sc.unreadable {
            rows.append(sc.fallback[name] ?? SessionTransferRow(id: name, title: name, cwd: "", lastActivity: .distantPast, kind: .blocked, reason: "索引无法读取或格式尚未支持。"))
        }
        for name in sc.nonCLI {
            if let fallback = sc.fallback[name] { rows.append(fallback) }
        }
        rows.sort { $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }
        return Snapshot(rows: rows, changes: changes, source: sc, target: tc)
    }
    public func rows(source: SessionTransferSpace, target: SessionTransferSpace, updateExisting: Bool, newSince: Date? = nil) throws -> [SessionTransferRow] {
        try snapshot(source: source, target: target, updates: updateExisting, newSince: newSince).rows
    }
    func sanitizedCopy(_ source: Index) throws -> [String: Any] {
        guard !Self.unsupportedBindings.contains(where: { source.object[$0] != nil }) else {
            throw SessionTransferFailure("此索引含未适配的账号或认证绑定，暂不自动跨空间复制。")
        }
        var object = source.object
        for key in Self.transientKeys { object.removeValue(forKey: key) }
        return object
    }
    func allocateCloneID(seed: String, usedNames: inout Set<String>, target: Catalogue) -> String {
        var attempt = 0
        while true {
            let candidate = Self.deterministicCloneSessionID(seed: attempt == 0 ? seed : "\(seed)#\(attempt)")
            let filename = candidate + ".json"
            if !usedNames.contains(filename), target.indexes[filename] == nil, !target.unreadable.contains(filename) {
                usedNames.insert(filename)
                return candidate
            }
            attempt += 1
        }
    }
    public func plan(source: SessionTransferSpace, target: SessionTransferSpace, selected: Set<String>, updateExisting: Bool,
                     expectedSourceIdentities: [String: String]? = nil, newSince: Date? = nil,
                     forkResolutions: [String: SessionForkResolution] = [:]) throws -> SessionTransferPlan {
        guard !selected.isEmpty else { throw SessionTransferFailure("请先选择会话。") }
        let ss = try Disk.scope(source), ts = try Disk.scope(target)
        let sm = try Disk.marker(source.endpoint), tm = try Disk.marker(target.endpoint)
        let state = try snapshot(source: source, target: target, updates: updateExisting, newSince: newSince)
        if let expectedSourceIdentities {
            guard selected.allSatisfy({ name in
                guard let expected = expectedSourceIdentities[name], let actual = state.source.indexes[name]?.identity else { return false }
                return expected == actual
            }) else { throw SessionTransferFailure("来源会话已变化，请重新检查后选择。") }
        }
        let chosenRows = state.rows.filter { selected.contains($0.id) }
        guard chosenRows.count == selected.count else { throw SessionTransferFailure("所选会话已变化，请重新选择。") }
        guard !chosenRows.contains(where: { $0.kind == .blocked }) else { throw SessionTransferFailure("所选会话存在冲突或不可用项，请重新检查。") }
        var logical: Set<String> = [], cli: Set<String> = []
        for name in selected {
            guard let item = state.source.indexes[name], logical.insert(item.logical).inserted, cli.insert(item.cli).inserted else {
                throw SessionTransferFailure("所选会话存在重复身份，请分开处理。")
            }
        }
        // Validate fork selections upfront: never silently resolve a fork without an explicit resolution.
        var activeForkTakeSource: Set<String> = []
        var activeForkKeepTarget: Set<String> = []
        for row in chosenRows where row.kind == .fork {
            guard let resolution = forkResolutions[row.id] else {
                throw SessionTransferFailure("所选分叉会话尚未指定处理方式，请先选择以源为主、以目标为主或暂不处理。")
            }
            switch resolution {
            case .takeSource: activeForkTakeSource.insert(row.id)
            case .keepTarget: activeForkKeepTarget.insert(row.id)
            case .skip: break
            }
        }
        var changes: [SessionTransferChange] = []
        var overwrittenTargetNames: Set<String> = activeForkTakeSource
        var incomingClis: Set<String> = []
        for name in selected.sorted() {
            if let c = state.changes[name] {
                changes.append(c)
                if c.kind == .update { overwrittenTargetNames.insert(name) }
                if let item = state.source.indexes[name] { incomingClis.insert(item.cli) }
            }
        }
        for name in activeForkTakeSource {
            if let item = state.source.indexes[name] { incomingClis.insert(item.cli) }
        }
        // Chains still reachable in target after this sync (untouched target entries + incoming active entries).
        var reachable: Set<String> = Set(state.target.indexes.values.filter { !overwrittenTargetNames.contains($0.name) }.map(\.cli))
        reachable.formUnion(incomingClis)
        var usedNames: Set<String> = Set(changes.map(\.name))
        for name in selected.sorted() {
            guard let row = chosenRows.first(where: { $0.id == name }), row.kind == .fork,
                  let srcItem = state.source.indexes[name], let dstItem = state.target.indexes[name] else { continue }
            if activeForkTakeSource.contains(name) {
                var nextObj = try sanitizedCopy(srcItem)
                if let targetMcp = dstItem.object["remoteMcpServersConfig"] { nextObj["remoteMcpServersConfig"] = targetMcp }
                let afterBytes = try Disk.encode(nextObj)
                usedNames.insert(name)
                changes.append(SessionTransferChange(name: name, title: srcItem.title, kind: .update, before: dstItem.bytes, after: afterBytes))
                if !reachable.contains(dstItem.cli) {
                    let cloneID = allocateCloneID(seed: "\(name)\n\(dstItem.cli)\n\(target.account)\ntakeSource", usedNames: &usedNames, target: state.target)
                    var cloneObj = dstItem.object
                    let cloneTitle = Self.parkedTitle(base: dstItem.title, cli: dstItem.cli, account: target.account)
                    cloneObj["sessionId"] = cloneID
                    cloneObj["title"] = cloneTitle
                    cloneObj["titleSource"] = "user"
                    let cloneBytes = try Disk.encode(cloneObj)
                    changes.append(SessionTransferChange(name: cloneID + ".json", title: cloneTitle, kind: .add, before: nil, after: cloneBytes, parkedFrom: name))
                    reachable.insert(dstItem.cli)
                }
            } else if activeForkKeepTarget.contains(name) {
                if !reachable.contains(srcItem.cli) {
                    var cloneObj = try sanitizedCopy(srcItem)
                    let cloneID = allocateCloneID(seed: "\(name)\n\(srcItem.cli)\n\(source.account)\nkeepTarget", usedNames: &usedNames, target: state.target)
                    let cloneTitle = Self.parkedTitle(base: srcItem.title, cli: srcItem.cli, account: source.account)
                    cloneObj["sessionId"] = cloneID
                    cloneObj["title"] = cloneTitle
                    cloneObj["titleSource"] = "user"
                    let cloneBytes = try Disk.encode(cloneObj)
                    changes.append(SessionTransferChange(name: cloneID + ".json", title: cloneTitle, kind: .add, before: nil, after: cloneBytes, parkedFrom: name))
                    reachable.insert(srcItem.cli)
                }
            }
        }
        guard !changes.isEmpty else { throw SessionTransferFailure("这些会话已存在，无需复制。") }
        var inputParts = selected.sorted().flatMap { name -> [String] in
            let row = chosenRows.first { $0.id == name }!
            let sourceHash = state.source.indexes[name].map { Disk.hash($0.bytes) } ?? "missing"
            let res = forkResolutions[name]?.rawValue ?? "none"
            return [name, row.kind.rawValue, res, sourceHash]
        }
        if let newSince { inputParts.append("newSince:\(Int64(newSince.timeIntervalSince1970))") }
        for c in changes {
            inputParts.append("change:\(c.name):\(c.kind.rawValue):\(c.before.map(Disk.hash) ?? "absent"):\(Disk.hash(c.after)):\(c.parkedFrom ?? "")")
        }
        let signature = Disk.hash(Data(inputParts.joined(separator: "\n").utf8))
        return SessionTransferPlan(source: source, target: target, selected: selected, updateExisting: updateExisting,
            newSince: newSince, forkResolutions: forkResolutions, rows: state.rows, changes: changes,
            sourceScope: ss, targetScope: ts, sourceMarker: sm, targetMarker: tm, signature: signature)
    }
    public func revalidate(_ plan: SessionTransferPlan) throws {
        let fresh = try self.plan(source: plan.source, target: plan.target, selected: plan.selected, updateExisting: plan.updateExisting,
                                  newSince: plan.newSince, forkResolutions: plan.forkResolutions)
        guard fresh.sourceScope == plan.sourceScope, fresh.targetScope == plan.targetScope,
              fresh.sourceMarker == plan.sourceMarker, fresh.targetMarker == plan.targetMarker,
              fresh.signature == plan.signature else { throw SessionTransferFailure("来源或目标已变化，请重新检查后复制。") }
    }
    /// Post-write verification per Section 4 #6:
    /// every receipt item exists in target pointing to the expected chain (or a linear continuation),
    /// is not archived/deleted, zero duplicate active cliSessionIds, and zero dead transcripts among written items.
    public func verifyAfterExecute(_ receipt: SessionTransferReceipt, in space: SessionTransferSpace) throws -> SessionTransferVerification {
        try assertTarget(space, for: receipt)
        let backupEntries = try verifyBackup(receipt)
        let cat = try catalogue(space)
        var missingItems: [String] = []
        var archivedItems: [String] = []
        var chainMismatches: [String] = []
        var deadTranscripts: [String] = []
        var writtenNames: Set<String> = []
        for (item, _, afterBytes) in backupEntries {
            writtenNames.insert(item.name)
            let expectedObj = try Disk.json(afterBytes)
            let expectedCli = expectedObj["cliSessionId"] as? String ?? ""
            guard let actual = cat.indexes[item.name] else {
                missingItems.append(item.name)
                continue
            }
            if removed(actual, in: cat) {
                archivedItems.append(item.name)
            }
            let chainMatches = actual.cli == expectedCli || (actual.priorCliSessionIds?.contains(expectedCli) == true)
            if !chainMatches {
                chainMismatches.append(item.name)
            }
            if (try? hasTranscript(actual.cli)) != true {
                deadTranscripts.append(item.name)
            }
        }
        var cliCounts: [String: Int] = [:]
        var preexistingDead = 0
        for index in cat.indexes.values where !removed(index, in: cat) {
            cliCounts[index.cli, default: 0] += 1
            if !writtenNames.contains(index.name), (try? hasTranscript(index.cli)) != true {
                preexistingDead += 1
            }
        }
        let duplicateActiveClis = cliCounts.filter { $0.value > 1 }.keys.sorted()
        let passed = missingItems.isEmpty && archivedItems.isEmpty && chainMismatches.isEmpty
            && duplicateActiveClis.isEmpty && deadTranscripts.isEmpty
        let summary: String
        if passed {
            summary = "核对通过：\(backupEntries.count) 条链匹配，0 重复，0 失效引用。"
        } else {
            var issues: [String] = []
            if !missingItems.isEmpty { issues.append("缺失 \(missingItems.count) 条") }
            if !archivedItems.isEmpty { issues.append("被归档 \(archivedItems.count) 条") }
            if !chainMismatches.isEmpty { issues.append("链不匹配 \(chainMismatches.count) 条") }
            if !duplicateActiveClis.isEmpty { issues.append("重复正文链 \(duplicateActiveClis.count) 组") }
            if !deadTranscripts.isEmpty { issues.append("失效引用 \(deadTranscripts.count) 条") }
            summary = "核对发现异常：\(issues.joined(separator: "、"))。"
        }
        return SessionTransferVerification(
            passed: passed,
            checkedItems: backupEntries.count,
            missingItems: missingItems,
            archivedItems: archivedItems,
            chainMismatches: chainMismatches,
            duplicateActiveClis: duplicateActiveClis,
            deadTranscripts: deadTranscripts,
            preexistingDeadTranscriptCount: preexistingDead,
            summary: summary
        )
    }
}
