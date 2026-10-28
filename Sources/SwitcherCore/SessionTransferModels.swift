import Foundation

public enum SessionTransferKind: String, Codable, Sendable { case add, update, skip, blocked }

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
    public var selectable: Bool { kind == .add || kind == .update }
    public init(id: String, title: String, cwd: String, lastActivity: Date, kind: SessionTransferKind, reason: String, identity: String = "") {
        self.id = id; self.title = title; self.cwd = cwd; self.lastActivity = lastActivity; self.kind = kind; self.reason = reason; self.identity = identity
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
}

public struct SessionTransferPlan: Sendable {
    public let source: SessionTransferSpace
    public let target: SessionTransferSpace
    public let selected: Set<String>
    public let updateExisting: Bool
    public let rows: [SessionTransferRow]
    public let changes: [SessionTransferChange]
    public var addedCount: Int { changes.filter { $0.kind == .add }.count }
    public var updatedCount: Int { changes.filter { $0.kind == .update }.count }
    public var skippedCount: Int { selected.count - changes.count }
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
    public var addedCount: Int { items.filter { $0.kind == .add }.count }
    public var updatedCount: Int { items.filter { $0.kind == .update }.count }
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
