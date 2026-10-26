import Foundation

public struct ThreadInfo: Identifiable, Hashable {
    public var id: String { account + "/" + organization + "/" + file.lastPathComponent }
    public let file: URL
    public let title: String
    public let cwd: String
    public let lastActivity: Date
    public let archived: Bool
    public let account: String
    public let organization: String
    public var project: String { (cwd as NSString).lastPathComponent }
    public init(file: URL, title: String, cwd: String, lastActivity: Date, archived: Bool, account: String, organization: String) {
        self.file = file; self.title = title; self.cwd = cwd; self.lastActivity = lastActivity
        self.archived = archived; self.account = account; self.organization = organization
    }
}

public struct ThreadDestination: Identifiable, Hashable {
    public var id: String { account + "/" + organization }
    public let directory: URL
    public let account: String
    public let organization: String
    public var label: String { "组织 " + organization.prefix(8) }
    public init(directory: URL, account: String, organization: String) {
        self.directory = directory; self.account = account; self.organization = organization
    }
}

public struct ThreadScan {
    public var threads: [ThreadInfo]
    public var unreadable: Int
    public init(threads: [ThreadInfo], unreadable: Int) { self.threads = threads; self.unreadable = unreadable }
}

public struct ThreadRepository {
    private let fm = FileManager.default
    public init() {}
    private func directories(_ parent: URL) throws -> [URL] {
        guard fm.fileExists(atPath: parent.path) else { return [] }
        return try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            .filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public func scan(_ profile: URL) throws -> ThreadScan {
        var threads: [ThreadInfo] = [], unreadable = 0
        let root = profile.appendingPathComponent("claude-code-sessions")
        for account in try directories(root) {
            for org in try directories(account) {
                for file in try fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)
                    where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                          let data = try? Data(contentsOf: file),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let cwd = json["cwd"] as? String else { unreadable += 1; continue }
                    let time = (json["lastActivityAt"] as? Double) ?? (json["createdAt"] as? Double) ?? 0
                    threads.append(ThreadInfo(file: file, title: json["title"] as? String ?? "Untitled", cwd: cwd,
                                              lastActivity: Date(timeIntervalSince1970: time / 1000), archived: json["isArchived"] as? Bool ?? false,
                                              account: account.lastPathComponent, organization: org.lastPathComponent))
                }
            }
        }
        return ThreadScan(threads: threads.sorted { $0.lastActivity > $1.lastActivity }, unreadable: unreadable)
    }

    public func destinations(_ profile: URL) throws -> [ThreadDestination] {
        let accounts = try directories(profile.appendingPathComponent("claude-code-sessions"))
        let config = profile.appendingPathComponent("config.json")
        var preferred: String?
        if fm.fileExists(atPath: config.path) {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else {
                throw SafetyError("目标账号配置格式异常。")
            }
            preferred = json["lastKnownAccountUuid"] as? String
        }
        let account: URL
        if let preferred {
            guard let match = accounts.first(where: { $0.lastPathComponent == preferred }) else {
                throw SafetyError("目标登录账号没有 Code 会话目录，请先登录并打开 Code 标签页。")
            }
            account = match
        } else {
            guard accounts.count == 1, let only = accounts.first else {
                throw SafetyError("目标账号信息不明确，请先登录并打开 Code 标签页。")
            }
            account = only
        }
        return try directories(account).map {
            ThreadDestination(directory: $0, account: account.lastPathComponent, organization: $0.lastPathComponent)
        }
    }

    public func copy(_ threads: [ThreadInfo], to destination: ThreadDestination,
                     write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> (copied: Int, skipped: Int) {
        var plan: [(URL, Data)] = [], identities: [String: String] = [:], skipped = 0
        let boundKeys = ["remoteMcpServersConfig", "bridgeSessionIds", "armedWorkAtQuit",
                         "remoteControlAutoEligible", "steeredByRemoteClient"]
        for thread in threads {
            guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: thread.file)) as? [String: Any],
                  let identity = json["cliSessionId"] as? String, !identity.isEmpty else {
                throw SafetyError("选中的会话缺少 cliSessionId，已停止复制。")
            }
            let name = thread.file.lastPathComponent, output = destination.directory.appendingPathComponent(name)
            if let planned = identities[name] {
                guard planned == identity else { throw SafetyError("所选会话文件名冲突，请分开复制。") }
                skipped += 1; continue
            }
            identities[name] = identity
            if fm.fileExists(atPath: output.path) {
                guard (try? output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
                      existing["cliSessionId"] as? String == identity else {
                    throw SafetyError("目标存在同名但不同身份或无法读取的会话，拒绝覆盖。")
                }
                skipped += 1; continue
            }
            boundKeys.forEach { json.removeValue(forKey: $0) }
            plan.append((output, try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])))
        }
        var created: [URL] = []
        do {
            for (output, data) in plan {
                // The live destination is closed by the caller; parked profiles are inactive.
                guard !fm.fileExists(atPath: output.path) else { throw SafetyError("复制期间目标出现同名文件，已停止。") }
                created.append(output)
                try write(data, output)
            }
        } catch {
            for file in created {
                do { if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) } }
                catch { throw SafetyError("复制失败且部分新建索引未能清理；源会话未改动，请检查目标组织。") }
            }
            throw error
        }
        return (plan.count, skipped)
    }
}
