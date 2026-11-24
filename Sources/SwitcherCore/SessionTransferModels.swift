import Foundation

public enum SessionTransferKind: String, Codable, Sendable { case add, update, fork, skip, blocked }

public enum SessionForkResolution: String, Codable, Sendable, CaseIterable {
    case takeSource, keepTarget, skip
}

public struct SessionForkDetails: Sendable, Equatable {
    public let sourceCliSessionID: String
    public let targetCliSessionID: String
    public let sourceLastTurnAt: Date?
    public let targetLastTurnAt: Date?
    public let sourceLastActivityAt: Date
    public let targetLastActivityAt: Date
    public let defaultResolution: SessionForkResolution
    public let targetTitle: String
    public var sourceCliPrefix: String { String(sourceCliSessionID.prefix(8)) }
    public var targetCliPrefix: String { String(targetCliSessionID.prefix(8)) }
    public init(sourceCliSessionID: String, targetCliSessionID: String,
                sourceLastTurnAt: Date?, targetLastTurnAt: Date?,
                sourceLastActivityAt: Date, targetLastActivityAt: Date,
                defaultResolution: SessionForkResolution, targetTitle: String) {
        self.sourceCliSessionID = sourceCliSessionID
        self.targetCliSessionID = targetCliSessionID
        self.sourceLastTurnAt = sourceLastTurnAt
        self.targetLastTurnAt = targetLastTurnAt
        self.sourceLastActivityAt = sourceLastActivityAt
        self.targetLastActivityAt = targetLastActivityAt
        self.defaultResolution = defaultResolution
        self.targetTitle = targetTitle
    }
}

public struct SessionTransferSpaceActivity: Sendable, Equatable {
    public let activeCount: Int
    public let latestActivityAt: Date?
    public let latestFileModifiedAt: Date?
    public let earliestActiveActivityAt: Date?
    public let newestTitle: String?
    public var newestTimestamp: Date? {
        switch (latestActivityAt, latestFileModifiedAt) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
    public var inferredNewSince: Date? {
        earliestActiveActivityAt.map { Calendar.current.startOfDay(for: $0) }
    }
    public init(activeCount: Int, latestActivityAt: Date?, latestFileModifiedAt: Date?,
                earliestActiveActivityAt: Date?, newestTitle: String?) {
        self.activeCount = activeCount
        self.latestActivityAt = latestActivityAt
        self.latestFileModifiedAt = latestFileModifiedAt
        self.earliestActiveActivityAt = earliestActiveActivityAt
        self.newestTitle = newestTitle
    }
}

public struct SessionTransferVerification: Codable, Sendable, Equatable {
    public let passed: Bool
    public let checkedItems: Int
    public let missingItems: [String]
    public let archivedItems: [String]
    public let chainMismatches: [String]
    public let duplicateActiveClis: [String]
    public let deadTranscripts: [String]
    public let preexistingDeadTranscriptCount: Int
    public let summary: String
    public init(passed: Bool, checkedItems: Int, missingItems: [String], archivedItems: [String],
                chainMismatches: [String], duplicateActiveClis: [String], deadTranscripts: [String],
                preexistingDeadTranscriptCount: Int, summary: String) {
        self.passed = passed
        self.checkedItems = checkedItems
        self.missingItems = missingItems
        self.archivedItems = archivedItems
        self.chainMismatches = chainMismatches
        self.duplicateActiveClis = duplicateActiveClis
        self.deadTranscripts = deadTranscripts
        self.preexistingDeadTranscriptCount = preexistingDeadTranscriptCount
        self.summary = summary
    }
}

public struct SessionTransferEndpoint: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let root: URL
    public let marker: URL?
    public let expectedMarker: String?
    public init(id: String, name: String, root: URL, marker: URL? = nil, expectedMarker: String? = nil) {
        self.id = id; self.name = name; self.root = root; self.marker = marker; self.expectedMarker = expectedMarker
    }
}

public struct SessionTransferSpace: Codable, Identifiable, Sendable, Equatable {
    public var id: String { endpoint.id + "/" + account + "/" + organization }
    public let endpoint: SessionTransferEndpoint
    public let account: String
    public let organization: String
    public var directory: URL { endpoint.root.appendingPathComponent("claude-code-sessions").appendingPathComponent(account).appendingPathComponent(organization) }
    public var name: String { "账号 \(account.prefix(8)) · 组织 \(organization.prefix(8))" }
    public init(endpoint: SessionTransferEndpoint, account: String, organization: String) {
        self.endpoint = endpoint; self.account = account; self.organization = organization
    }
}

public struct SessionTransferRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String
    public var project: String { (cwd as NSString).lastPathComponent }
    public let lastActivity: Date
    public let kind: SessionTransferKind
    public let reason: String
    public let identity: String
    public let continuation: Bool
    public let fork: SessionForkDetails?
    public let skippedByCutoff: Bool
    public var selectable: Bool { kind == .add || kind == .update }
    public var isFork: Bool { kind == .fork }
    public init(id: String, title: String, cwd: String, lastActivity: Date, kind: SessionTransferKind, reason: String,
                identity: String = "", continuation: Bool = false, fork: SessionForkDetails? = nil, skippedByCutoff: Bool = false) {
        self.id = id; self.title = title; self.cwd = cwd; self.lastActivity = lastActivity; self.kind = kind; self.reason = reason; self.identity = identity
        self.continuation = continuation; self.fork = fork; self.skippedByCutoff = skippedByCutoff
    }
}

public struct SessionTransferScope: Codable, Sendable, Equatable {
    public let endpointID: String
    public let account: String
    public let organization: String
    public let rootIdentity: String
    public let accountIdentity: String
    public let directoryIdentity: String
}

public struct SessionTransferChange: Sendable, Equatable {
    public let name: String
    public let title: String
    public let kind: SessionTransferKind
    public let before: Data?
    public let after: Data
    public let parkedFrom: String?
    public init(name: String, title: String, kind: SessionTransferKind, before: Data?, after: Data, parkedFrom: String? = nil) {
        self.name = name; self.title = title; self.kind = kind; self.before = before; self.after = after; self.parkedFrom = parkedFrom
    }
}

public struct SessionTransferPlan: Sendable {
    public let source: SessionTransferSpace
    public let target: SessionTransferSpace
    public let selected: Set<String>
    public let updateExisting: Bool
    public let newSince: Date?
    public let forkResolutions: [String: SessionForkResolution]
    public let rows: [SessionTransferRow]
    public let changes: [SessionTransferChange]
    public var addedCount: Int { changes.filter { $0.kind == .add && $0.parkedFrom == nil }.count }
    public var updatedCount: Int { changes.filter { $0.kind == .update }.count }
    public var parkedCount: Int { changes.filter { $0.parkedFrom != nil }.count }
    public var skippedCount: Int { max(0, selected.count - changes.filter { $0.parkedFrom == nil }.count) }
    let sourceScope: SessionTransferScope
    let targetScope: SessionTransferScope
    let sourceMarker: String?
    let targetMarker: String?
    let signature: String
}

public enum SessionTransferReceiptState: String, Codable, Sendable {
    case copying, completed, restoring, restored, recoveryRequired, undone, preserved
    public var needsRecovery: Bool { self == .copying || self == .restoring || self == .recoveryRequired }
}

public struct SessionTransferReceiptItem: Codable, Sendable, Equatable {
    public let name: String
    public let title: String
    public let kind: SessionTransferKind
    public let cwd: String?
    public let beforeHash: String?
    public let afterHash: String
    public let beforeFile: String?
    public let afterFile: String
    public let parkedFrom: String?
    public init(name: String, title: String, kind: SessionTransferKind, cwd: String?,
                beforeHash: String?, afterHash: String, beforeFile: String?, afterFile: String, parkedFrom: String? = nil) {
        self.name = name; self.title = title; self.kind = kind; self.cwd = cwd
        self.beforeHash = beforeHash; self.afterHash = afterHash; self.beforeFile = beforeFile; self.afterFile = afterFile
        self.parkedFrom = parkedFrom
    }
}

public struct SessionTransferReceipt: Codable, Identifiable, Sendable {
    public let version: Int
    public let id: String
    public let createdAt: Date
    public let target: SessionTransferScope
    public let targetName: String
    public let items: [SessionTransferReceiptItem]
    public var state: SessionTransferReceiptState
    public var undoRequested: Bool
    public var message: String?
    public var addedCount: Int { items.filter { $0.kind == .add && $0.parkedFrom == nil }.count }
    public var updatedCount: Int { items.filter { $0.kind == .update }.count }
    public var parkedCount: Int { items.filter { $0.parkedFrom != nil }.count }
}

public enum SessionTransferWriteMode: Equatable, Sendable { case create, replace }
public struct SessionTransferIO {
    public var write: (Data, URL, SessionTransferWriteMode) throws -> Void
    public var remove: (URL) throws -> Void
    public init(write: @escaping (Data, URL, SessionTransferWriteMode) throws -> Void = SessionTransferDisk.write,
                remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.write = write; self.remove = remove
    }
}

public struct SessionTransferFailure: Error, LocalizedError {
    public let message: String
    public let receiptID: String?
    public init(_ message: String, receiptID: String? = nil) { self.message = message; self.receiptID = receiptID }
    public var errorDescription: String? { message }
}
