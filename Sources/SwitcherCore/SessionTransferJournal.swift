import Foundation

extension SessionTransferService {
    func folder(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw SessionTransferFailure("备份记录标识无效。") }
        return backups.appendingPathComponent(id)
    }
    func save(_ receipt: SessionTransferReceipt) throws {
        let dir = try folder(receipt.id)
        _ = try Disk.identity(dir, directory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let file = dir.appendingPathComponent("receipt.json")
        try io.write(data, file, .replace)
        guard try Disk.data(file) == data else { throw SessionTransferFailure("操作收据回读失败，未确认完成。") }
    }
    public func loadReceipt(_ id: String) throws -> SessionTransferReceipt {
        _ = try Disk.identity(backups, directory: true)
        let dir = try folder(id); _ = try Disk.identity(dir, directory: true)
        let value = try JSONDecoder().decode(SessionTransferReceipt.self, from: Disk.data(dir.appendingPathComponent("receipt.json")))
        guard value.version == 1, value.id == id, !value.items.isEmpty,
              Set(value.items.map(\.name)).count == value.items.count,
              value.items.allSatisfy({ Disk.name($0.name) && [.add, .update].contains($0.kind) }) else {
            throw SessionTransferFailure("备份清单无法确认，未操作目标。")
        }
        for (i, item) in value.items.enumerated() {
            guard item.afterFile == "after-\(i).json",
                  item.beforeFile == (item.beforeHash == nil ? nil : "before-\(i).json"),
                  (item.kind == .add) == (item.beforeHash == nil) else {
                throw SessionTransferFailure("备份清单路径或前态无效。")
            }
        }
        return value
    }
    public func receipts() throws -> [SessionTransferReceipt] {
        if !FileManager.default.fileExists(atPath: backups.path) { return [] }
        return try Disk.directories(backups).map { dir in
            guard UUID(uuidString: dir.lastPathComponent) != nil else { throw SessionTransferFailure("备份目录中有无法确认的记录，请检查备份位置。") }
            return try loadReceipt(dir.lastPathComponent)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func backupFolder(_ receipt: SessionTransferReceipt) throws -> URL { try folder(receipt.id) }
    public func checkedBackup(_ id: String) throws -> SessionTransferReceipt {
        let receipt = try loadReceipt(id)
        _ = try verifyBackup(receipt)
        return receipt
    }
    func verifyBackup(_ receipt: SessionTransferReceipt) throws -> [(SessionTransferReceiptItem, Data?, Data)] {
        let dir = try folder(receipt.id)
        return try receipt.items.map { item in
            let after = try Disk.data(dir.appendingPathComponent(item.afterFile))
            guard Disk.hash(after) == item.afterHash else { throw SessionTransferFailure("备份校验不一致，不操作目标。", receiptID: receipt.id) }
            let before = try item.beforeFile.map { try Disk.data(dir.appendingPathComponent($0)) }
            guard before.map(Disk.hash) == item.beforeHash else { throw SessionTransferFailure("旧索引备份不完整，不操作目标。", receiptID: receipt.id) }
            return (item, before, after)
        }
    }
    func assertTarget(_ space: SessionTransferSpace, for receipt: SessionTransferReceipt) throws {
        guard try Disk.scope(space) == receipt.target else { throw SessionTransferFailure("原目标空间已变化，不能把旧备份恢复到当前路径。", receiptID: receipt.id) }
        _ = try Disk.marker(space.endpoint)
    }
    func existingReceiptsAllowCopy(to scope: SessionTransferScope) throws {
        guard try !receipts().contains(where: { $0.target == scope && $0.state.needsRecovery }) else {
            throw SessionTransferFailure("该目标有尚未完成的操作，请先查看并处理恢复记录。")
        }
    }
    public func execute(_ plan: SessionTransferPlan, requireIdle: () throws -> Void = {}) throws -> SessionTransferReceipt {
        try requireIdle()
        try revalidate(plan)
        try existingReceiptsAllowCopy(to: plan.targetScope)
        try Disk.ensurePrivateDirectory(backups)
        let id = UUID().uuidString, dir = try folder(id)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw SessionTransferFailure("备份标识冲突，未开始复制。") }
        try Disk.ensurePrivateDirectory(dir)
        var items: [SessionTransferReceiptItem] = []
        do {
            for (i, change) in plan.changes.enumerated() {
                let beforeFile = change.before == nil ? nil : "before-\(i).json", afterFile = "after-\(i).json"
                if let bytes = change.before, let name = beforeFile { try io.write(bytes, dir.appendingPathComponent(name), .create) }
                try io.write(change.after, dir.appendingPathComponent(afterFile), .create)
                items.append(SessionTransferReceiptItem(name: change.name, title: change.title, kind: change.kind,
                    cwd: try Disk.json(change.after)["cwd"] as? String,
                    beforeHash: change.before.map(Disk.hash), afterHash: Disk.hash(change.after), beforeFile: beforeFile, afterFile: afterFile))
            }
            var receipt = SessionTransferReceipt(version: 1, id: id, createdAt: Date(), target: plan.targetScope,
                targetName: plan.target.endpoint.name, items: items, state: .copying, undoRequested: false, message: nil)
            _ = try verifyBackup(receipt)
            try requireIdle(); try revalidate(plan)
            try save(receipt)
            // Receipt is durable before the first target change. Recovery uses byte hashes,
            // so a process interruption needs no guessed per-file progress counter.
            var written: Set<String> = []
            var attemptedUpdates: Set<String> = []
            do {
                for change in plan.changes {
                    try requireIdle()
                    guard try Disk.scope(plan.target) == plan.targetScope,
                          try Disk.marker(plan.target.endpoint) == plan.targetMarker else { throw SessionTransferFailure("目标档案已变化，已停止后续写入。") }
                    let file = plan.target.directory.appendingPathComponent(change.name)
                    guard try Disk.optionalData(file) == change.before else { throw SessionTransferFailure("目标索引被外部修改，未覆盖新进展。") }
                    if change.before != nil { attemptedUpdates.insert(change.name) }
                    try io.write(change.after, file, change.before == nil ? .create : .replace)
                    written.insert(change.name)
                    guard try Disk.data(file) == change.after else { throw SessionTransferFailure("会话索引回读不一致。") }
                }
                receipt.state = .completed
                try save(receipt)
                return receipt
            } catch {
                let cause = error.localizedDescription
                let restored = rollback(receipt, space: plan.target, eligibleNames: written.union(attemptedUpdates), requireIdle: requireIdle)
                receipt.state = restored ? .restored : .recoveryRequired
                receipt.message = restored ? "复制失败，已恢复本次变更。" : "复制失败，部分恢复未确认；已保留备份和现场。"
                do { try save(receipt) }
                catch { throw SessionTransferFailure("复制或收据保存未确认，请先查看未完成记录。", receiptID: id) }
                throw SessionTransferFailure("\(receipt.message!) \(cause)", receiptID: id)
            }
        } catch {
            // Before a receipt exists, no target write was attempted. Remove only
            // this operation's staged backup directory; an existing receipt retains its ID.
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("receipt.json").path) {
                try? FileManager.default.removeItem(at: dir)
                throw SessionTransferFailure("备份或准备未完成，目标未修改。\(error.localizedDescription)")
            }
            throw SessionTransferFailure(error.localizedDescription, receiptID: (error as? SessionTransferFailure)?.receiptID ?? id)
        }
    }
    func rollback(_ receipt: SessionTransferReceipt, space: SessionTransferSpace, eligibleNames: Set<String>? = nil, requireIdle: () throws -> Void) -> Bool {
        guard (try? assertTarget(space, for: receipt)) != nil, let files = try? verifyBackup(receipt) else { return false }
        var complete = true
        for (item, before, after) in files.reversed() {
            if let eligibleNames, !eligibleNames.contains(item.name) { continue }
            do {
                try requireIdle(); try assertTarget(space, for: receipt)
                let file = space.directory.appendingPathComponent(item.name)
                let current = try Disk.optionalData(file)
                if current == before { continue }
                guard current == after else { throw SessionTransferFailure("目标已有外部新进展。") }
                if let before { try io.write(before, file, .replace) } else { try io.remove(file) }
                guard try Disk.optionalData(file) == before else { throw SessionTransferFailure("恢复回读失败。") }
            } catch { complete = false }
        }
        return complete
    }
    /// Undo is all-or-nothing at preflight. Interrupted copy recovery also accepts each
    /// recorded before-state because some files may never have been committed.
    public func restore(_ id: String, to space: SessionTransferSpace, undo: Bool,
                        requireIdle: () throws -> Void = {}) throws -> SessionTransferReceipt {
        var receipt = try loadReceipt(id)
        guard undo ? receipt.state == .completed : receipt.state.needsRecovery else { throw SessionTransferFailure("该记录当前不需要恢复。") }
        try requireIdle(); try assertTarget(space, for: receipt)
        let files = try verifyBackup(receipt)
        for (item, before, after) in files {
            let current = try Disk.optionalData(space.directory.appendingPathComponent(item.name))
            guard current == after || (!undo && current == before) else {
                throw SessionTransferFailure("目标已有新进展或外部修改，整批未还原；保留当前数据。", receiptID: id)
            }
        }
        receipt.undoRequested = undo || receipt.undoRequested
        receipt.state = .restoring
        try save(receipt)
        guard rollback(receipt, space: space, requireIdle: requireIdle) else {
            receipt.state = .recoveryRequired; receipt.message = "恢复未能全部确认，已停止并保留现场。"
            try? save(receipt)
            throw SessionTransferFailure(receipt.message!, receiptID: id)
        }
        receipt.state = receipt.undoRequested ? .undone : .restored
        receipt.message = nil
        try save(receipt)
        return receipt
    }
    /// This closes an unresolved record only after explicit user consent. It does not
    /// restore, delete or overwrite any target index, and never claims full recovery.
    public func keepCurrentData(_ id: String, in space: SessionTransferSpace) throws -> SessionTransferReceipt {
        var receipt = try loadReceipt(id)
        guard receipt.state.needsRecovery else { throw SessionTransferFailure("该记录没有待结束的恢复。") }
        try assertTarget(space, for: receipt)
        let backupVerified = (try? verifyBackup(receipt)) != nil
        receipt.state = .preserved
        receipt.message = backupVerified
            ? "已保留当前数据并结束记录，备份已核对；未执行恢复。"
            : "已保留当前数据并结束记录；备份缺失或无法核对，未执行恢复。"
        try save(receipt)
        return receipt
    }

}
