import XCTest
@testable import SwitcherCore

/// Section 5 Replay Cases (R1–R7) and cross-account sync invariants
/// from desktop-session-sync-handoff-20261124.md.
final class SessionSyncReplayTests: FixtureTest {
    typealias Disk = SessionTransferDisk
    var source: SessionTransferSpace!
    var target: SessionTransferSpace!
    var transcripts: URL!
    var backups: URL!
    var service: SessionTransferService { SessionTransferService(transcripts: transcripts, backups: backups) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let srcRoot = try directory("src-c86bbffa")
        let dstRoot = try directory("dst-7dd41b2c")
        _ = try directory("src-c86bbffa/claude-code-sessions/c86bbffa-1111-4111-8111-111111111111/org-src")
        _ = try directory("dst-7dd41b2c/claude-code-sessions/7dd41b2c-2222-4222-8222-222222222222/org-dst")
        source = SessionTransferSpace(
            endpoint: .init(id: "api", name: "API 工作区", root: srcRoot),
            account: "c86bbffa-1111-4111-8111-111111111111",
            organization: "org-src"
        )
        target = SessionTransferSpace(
            endpoint: .init(id: "profile:Personal", name: "Personal", root: dstRoot),
            account: "7dd41b2c-2222-4222-8222-222222222222",
            organization: "org-dst"
        )
        transcripts = try directory("projects")
        _ = try directory("projects/matchat")
        backups = folder.appendingPathComponent("backups")
    }

    @discardableResult
    func writeEntry(
        _ id: String,
        title: String,
        cli: String,
        turns: Int,
        lastActivityAt: Int64,
        lastTurnEdgeAt: Int64? = nil,
        latestUserFrameAt: Int64? = nil,
        priorCliSessionIds: [String]? = nil,
        priorCliSessionLeftAt: [String: Int64]? = nil,
        spawnedFrom: [String: Any]? = nil,
        isArchived: Bool = false,
        space: SessionTransferSpace? = nil,
        transcriptMtimeMs: Int64? = nil
    ) throws -> String {
        let dest = space ?? source!
        let file = "local_\(id).json"
        var obj: [String: Any] = [
            "sessionId": "local_\(id)",
            "cliSessionId": cli,
            "title": title,
            "cwd": "/fake/matchat",
            "completedTurns": turns,
            "lastActivityAt": lastActivityAt,
            "isArchived": isArchived
        ]
        if let lastTurnEdgeAt { obj["lastTurnEdgeAt"] = lastTurnEdgeAt }
        if let latestUserFrameAt { obj["latestUserFrameAt"] = latestUserFrameAt }
        if let priorCliSessionIds { obj["priorCliSessionIds"] = priorCliSessionIds }
        if let priorCliSessionLeftAt { obj["priorCliSessionLeftAt"] = priorCliSessionLeftAt }
        if let spawnedFrom { obj["spawnedFrom"] = spawnedFrom }
        try writeJSON(obj, dest.directory.appendingPathComponent(file))
        let allClis = [cli] + (priorCliSessionIds ?? [])
        for c in allClis {
            let path = transcripts.appendingPathComponent("matchat/\(c).jsonl")
            if !FileManager.default.fileExists(atPath: path.path) {
                try Data("{\"sessionId\":\"\(c)\",\"type\":\"user\"}\n".utf8).write(to: path)
            }
            if c == cli, let mtime = transcriptMtimeMs {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: Double(mtime) / 1000)],
                    ofItemAtPath: path.path
                )
            }
        }
        return file
    }

    func transcriptHashes() throws -> [String: String] {
        let dir = transcripts.appendingPathComponent("matchat")
        var map: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "jsonl" {
            map[url.lastPathComponent] = try Disk.hash(Data(contentsOf: url))
        }
        return map
    }

    // MARK: - R1 (11-08): Target continued on old chain after source left for a new chain (BP, TEST, 思考)
    func testR1_TargetContinuedOldChainAfterSourceMovedIsForkNeverLinearOverwrite() throws {
        let leftAt: Int64 = 1_794_000_000_000
        let bp = try writeEntry(
            "bp-0001", title: "BP", cli: "newchain-bp-1111", turns: 850,
            lastActivityAt: leftAt + 3_600_000, lastTurnEdgeAt: leftAt + 3_500_000,
            priorCliSessionIds: ["oldchain-bp-0000"],
            priorCliSessionLeftAt: ["oldchain-bp-0000": leftAt],
            space: source, transcriptMtimeMs: leftAt + 3_500_000
        )
        // Personal kept chatting on oldchain-bp-0000 hours AFTER leftAt, with fewer turns (250 < 850).
        try writeEntry(
            "bp-0001", title: "BP", cli: "oldchain-bp-0000", turns: 250,
            lastActivityAt: leftAt + 7_200_000, lastTurnEdgeAt: leftAt + 7_100_000,
            space: target, transcriptMtimeMs: leftAt + 7_100_000
        )
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == bp })
        XCTAssertEqual(row.kind, .fork, "R1: Target continued on old chain after leftAt must be FORK, never linear overwrite")
        XCTAssertFalse(row.continuation)
        XCTAssertEqual(row.fork?.defaultResolution, .keepTarget, "Default fork winner picks branch with later effective turn timestamp (target > source)")
        // Without explicit fork resolution, planning must refuse to overwrite.
        XCTAssertThrowsError(try service.plan(source: source, target: target, selected: [bp], updateExisting: true))
    }

    // MARK: - R2 (11-08): Same chain, target active later with fewer turns (对账、模型接入车道)
    func testR2_SameChainTargetActiveLaterWithFewerTurnsIsSkippedNeverOverwritten() throws {
        let base: Int64 = 1_794_100_000_000
        let recon = try writeEntry(
            "recon-0002", title: "对账", cli: "shared-cli-2222", turns: 920,
            lastActivityAt: base, lastTurnEdgeAt: base,
            space: source
        )
        // Target shares the same cliSessionId, ran later (base + 5m), even though target's turn counter is smaller (40 < 920).
        try writeEntry(
            "recon-0002", title: "对账", cli: "shared-cli-2222", turns: 40,
            lastActivityAt: base + 300_000, lastTurnEdgeAt: base + 290_000,
            space: target
        )
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == recon })
        XCTAssertEqual(row.kind, .skip, "R2: Same chain with later target lastActivityAt must skip regardless of lower target completedTurns")
        XCTAssertEqual(row.reason, "目标进度较新，保留目标。")
        XCTAssertThrowsError(try service.plan(source: source, target: target, selected: [recon], updateExisting: true))
    }

    // MARK: - R3 (11-10): Target branched to new chain from source's chain, source kept going on old chain (BP)
    func testR3_SourceContinuedOldChainAfterTargetMovedOnIsForkNotTargetAhead() throws {
        let targetLeftAt: Int64 = 1_794_200_000_000
        // Source stayed on old-bp and kept chatting for 2 days after target left old-bp.
        let bp = try writeEntry(
            "bp-0003", title: "BP", cli: "old-bp-3333", turns: 410,
            lastActivityAt: targetLeftAt + 172_800_000, lastTurnEdgeAt: targetLeftAt + 172_700_000,
            space: source, transcriptMtimeMs: targetLeftAt + 172_700_000
        )
        try writeEntry(
            "bp-0003", title: "BP", cli: "new-bp-4444", turns: 500,
            lastActivityAt: targetLeftAt + 3_600_000, lastTurnEdgeAt: targetLeftAt + 3_500_000,
            priorCliSessionIds: ["old-bp-3333"],
            priorCliSessionLeftAt: ["old-bp-3333": targetLeftAt],
            space: target, transcriptMtimeMs: targetLeftAt + 3_500_000
        )
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == bp })
        XCTAssertEqual(row.kind, .fork, "R3: Source continued on old chain after target left -> FORK, never misclassified as target ahead")
        XCTAssertEqual(row.fork?.defaultResolution, .takeSource, "Source has later effective turn timestamp (2 days later) -> default takeSource")
    }

    // MARK: - R4 (11-10): Fork and skip rows are never silent; every row carries an explicit reason
    func testR4_ForkAndSkipNeverSilentEveryRowHasExplicitReason() throws {
        let t: Int64 = 1_794_300_000_000
        // Unrelated fork
        try writeEntry("fork-a", title: "分叉会话", cli: "cli-src-a", turns: 10, lastActivityAt: t, space: source)
        try writeEntry("fork-a", title: "分叉会话", cli: "cli-dst-a", turns: 12, lastActivityAt: t + 1000, space: target)
        // Archived in target
        try writeEntry("arch-b", title: "目标归档", cli: "cli-arch-b", turns: 5, lastActivityAt: t, space: source)
        try writeEntry("arch-b", title: "目标归档", cli: "cli-arch-b", turns: 5, lastActivityAt: t, isArchived: true, space: target)
        // Same synced
        try writeEntry("sync-c", title: "已同步", cli: "cli-sync-c", turns: 8, lastActivityAt: t, space: source)
        try writeEntry("sync-c", title: "已同步", cli: "cli-sync-c", turns: 8, lastActivityAt: t, space: target)

        let rows = try service.rows(source: source, target: target, updateExisting: true)
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertFalse(row.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "R4: Row \(row.id) must carry explicit reason")
        }
        XCTAssertEqual(rows.first { $0.id == "local_fork-a.json" }?.kind, .fork)
        XCTAssertEqual(rows.first { $0.id == "local_arch-b.json" }?.kind, .skip)
        XCTAssertEqual(rows.first { $0.id == "local_sync-c.json" }?.kind, .skip)
    }

    // MARK: - R5 (11-13): Source has a parked 旧分支 clone whose cliSessionId is already in target -> skip (no duplicate)
    func testR5_ParkedCloneWhoseCliAlreadyExistsInTargetIsSkippedWithoutDuplication() throws {
        let t: Int64 = 1_794_400_000_000
        let clone = try writeEntry(
            "clone-parked-5555",
            title: "BP｜旧分支 shared55（0631）",
            cli: "shared55-cli-uuid",
            turns: 100,
            lastActivityAt: t,
            space: source
        )
        // Target already has a DIFFERENT local_<uuid> pointing to shared55-cli-uuid.
        try writeEntry(
            "orig-bp-5555",
            title: "BP",
            cli: "shared55-cli-uuid",
            turns: 120,
            lastActivityAt: t + 10_000,
            space: target
        )
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == clone })
        XCTAssertEqual(row.kind, .skip, "R5: Parked clone referencing a cliSessionId already in target must be skipped, not added or blocked")
        XCTAssertTrue(row.reason.contains("同一正文链"))
        XCTAssertThrowsError(try service.plan(source: source, target: target, selected: [clone], updateExisting: true))
    }

    // MARK: - R6 (11-18): After switch, target refreshed lastActivityAt and ran real turns on same chain -> skip
    func testR6_PostSwitchTargetNewActivityOnSameChainIsSkipped() throws {
        let t: Int64 = 1_794_500_000_000
        let file = try writeEntry(
            "postswitch-6666", title: "切档后继续聊", cli: "cli-shared-6666",
            turns: 300, lastActivityAt: t, lastTurnEdgeAt: t - 500,
            space: source
        )
        try writeEntry(
            "postswitch-6666", title: "切档后继续聊", cli: "cli-shared-6666",
            turns: 305, lastActivityAt: t + 600_000, lastTurnEdgeAt: t + 599_000,
            space: target
        )
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == file })
        XCTAssertEqual(row.kind, .skip, "R6: Same chain with later target activity skips without losing shared transcript")
        XCTAssertEqual(row.reason, "目标进度较新，保留目标。")
    }

    // MARK: - R7: Normal linear continuation (d.lastActivityAt <= s.leftAt) overwrites EVEN IF target has more turns
    func testR7_NormalLinearContinuationOverwritesRegardlessOfPerIdentityTurnCount() throws {
        let leftAt: Int64 = 1_794_600_000_000
        let file = try writeEntry(
            "linear-7777", title: "线性接续", cli: "cli-new-7777",
            turns: 12, // lower per-identity turn count in source!
            lastActivityAt: leftAt + 120_000, lastTurnEdgeAt: leftAt + 119_000,
            priorCliSessionIds: ["cli-old-7777"],
            priorCliSessionLeftAt: ["cli-old-7777": leftAt],
            space: source, transcriptMtimeMs: leftAt + 119_000
        )
        try writeEntry(
            "linear-7777", title: "线性接续（目标自定义名）", cli: "cli-old-7777",
            turns: 450, // higher per-identity turn count in target!
            lastActivityAt: leftAt - 5_000, lastTurnEdgeAt: leftAt - 6_000,
            space: target, transcriptMtimeMs: leftAt - 5_000
        )
        let beforeTranscripts = try transcriptHashes()
        let rows = try service.rows(source: source, target: target, updateExisting: true)
        let row = try XCTUnwrap(rows.first { $0.id == file })
        XCTAssertEqual(row.kind, .update, "R7: d.lastActivityAt <= s.leftAt must be linear continuation even when target turns > source turns")
        XCTAssertTrue(row.continuation)

        let plan = try service.plan(source: source, target: target, selected: [file], updateExisting: true)
        let receipt = try service.execute(plan)
        XCTAssertEqual(receipt.updatedCount, 1)
        let after = try Disk.json(Data(contentsOf: target.directory.appendingPathComponent(file)))
        XCTAssertEqual(after["cliSessionId"] as? String, "cli-new-7777")
        XCTAssertEqual(after["title"] as? String, "线性接续（目标自定义名）")
        let verification = try service.verifyAfterExecute(receipt, in: target)
        XCTAssertTrue(verification.passed, verification.summary)
        XCTAssertEqual(try transcriptHashes(), beforeTranscripts, "Sync must never touch .jsonl transcripts")
    }

    // MARK: - Fork resolution (takeSource + keepTarget), parked 旧分支 clone, spawnedFrom, verification, and atomic Undo
    func testForkTakeSourceParksTargetBranchVerifiesAndUndoesAtomically() throws {
        let leftAt: Int64 = 1_794_700_000_000
        // Source has later effective turn timestamp (even if target had lastActivityAt refreshed on open!).
        let file = try writeEntry(
            "fork-ts", title: "架构讨论", cli: "aaaa1111-src-cli", turns: 30,
            lastActivityAt: leftAt + 3_000_000, lastTurnEdgeAt: leftAt + 2_900_000,
            priorCliSessionIds: ["bbbb2222-dst-cli"],
            priorCliSessionLeftAt: ["bbbb2222-dst-cli": leftAt],
            spawnedFrom: ["sessionId": "local_parent", "taskId": "task-1", "title": "父会话", "sideSession": true],
            space: source, transcriptMtimeMs: leftAt + 2_900_000
        )
        try writeEntry(
            "fork-ts", title: "架构讨论", cli: "bbbb2222-dst-cli", turns: 50,
            lastActivityAt: leftAt + 9_000_000, // refreshed on open!
            lastTurnEdgeAt: leftAt + 1_000_000, // actual last turn is EARLIER than source!
            space: target, transcriptMtimeMs: leftAt + 1_000_000
        )
        let targetBefore = try Data(contentsOf: target.directory.appendingPathComponent(file))
        let transcriptsBefore = try transcriptHashes()

        let row = try XCTUnwrap(try service.rows(source: source, target: target, updateExisting: true).first)
        XCTAssertEqual(row.kind, .fork)
        XCTAssertEqual(row.fork?.defaultResolution, .takeSource, "Effective turn timestamp (lastTurnEdgeAt) must beat refreshed lastActivityAt")

        let plan = try service.plan(
            source: source, target: target, selected: [file], updateExisting: true,
            forkResolutions: [file: .takeSource]
        )
        XCTAssertEqual(plan.updatedCount, 1)
        XCTAssertEqual(plan.parkedCount, 1)
        XCTAssertEqual(plan.addedCount, 0)

        let receipt = try service.execute(plan)
        XCTAssertEqual(receipt.updatedCount, 1)
        XCTAssertEqual(receipt.parkedCount, 1)
        XCTAssertEqual(receipt.items.count, 2)

        // Primary entry now points to source chain and preserves spawnedFrom WITHOUT adding `name`.
        let primaryAfter = try Disk.json(Data(contentsOf: target.directory.appendingPathComponent(file)))
        XCTAssertEqual(primaryAfter["cliSessionId"] as? String, "aaaa1111-src-cli")
        let spawned = try XCTUnwrap(primaryAfter["spawnedFrom"] as? [String: Any])
        XCTAssertEqual(spawned["sideSession"] as? Bool, true)
        XCTAssertNil(spawned["name"], "Never add spawnedFrom.name")

        // Parked clone exists with exact naming convention and titleSource = "user".
        let parkedItem = try XCTUnwrap(receipt.items.first { $0.parkedFrom == file })
        let parkedAfter = try Disk.json(Data(contentsOf: target.directory.appendingPathComponent(parkedItem.name)))
        XCTAssertEqual(parkedAfter["cliSessionId"] as? String, "bbbb2222-dst-cli")
        XCTAssertEqual(parkedAfter["title"] as? String, "架构讨论｜旧分支 bbbb2222（7dd4）")
        XCTAssertEqual(parkedAfter["titleSource"] as? String, "user")

        // Automatic post-write verification passes (2 items checked, 0 duplicates, 0 dead transcripts).
        let verification = try service.verifyAfterExecute(receipt, in: target)
        XCTAssertTrue(verification.passed, verification.summary)
        XCTAssertEqual(verification.checkedItems, 2)
        XCTAssertTrue(verification.duplicateActiveClis.isEmpty)
        XCTAssertTrue(verification.deadTranscripts.isEmpty)

        // One-click Undo atomically restores primary AND removes the parked clone!
        let undone = try service.restore(receipt.id, to: target, undo: true)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(try Data(contentsOf: target.directory.appendingPathComponent(file)), targetBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(parkedItem.name).path))
        XCTAssertEqual(try transcriptHashes(), transcriptsBefore)
    }

    func testForkKeepTargetParksSourceBranchAndUndoesAtomically() throws {
        let t: Int64 = 1_794_800_000_000
        let file = try writeEntry(
            "fork-kt", title: "需求评审", cli: "cccc3333-src-cli", turns: 20,
            lastActivityAt: t, lastTurnEdgeAt: t, space: source
        )
        try writeEntry(
            "fork-kt", title: "需求评审", cli: "dddd4444-dst-cli", turns: 25,
            lastActivityAt: t + 500_000, lastTurnEdgeAt: t + 500_000, space: target
        )
        let targetBefore = try Data(contentsOf: target.directory.appendingPathComponent(file))

        let plan = try service.plan(
            source: source, target: target, selected: [file], updateExisting: true,
            forkResolutions: [file: .keepTarget]
        )
        XCTAssertEqual(plan.updatedCount, 0)
        XCTAssertEqual(plan.parkedCount, 1)

        let receipt = try service.execute(plan)
        // Primary stays byte-identical!
        XCTAssertEqual(try Data(contentsOf: target.directory.appendingPathComponent(file)), targetBefore)
        // Parked source clone created with source account prefix (c86b).
        let parkedItem = try XCTUnwrap(receipt.items.first { $0.parkedFrom == file })
        let parkedAfter = try Disk.json(Data(contentsOf: target.directory.appendingPathComponent(parkedItem.name)))
        XCTAssertEqual(parkedAfter["cliSessionId"] as? String, "cccc3333-src-cli")
        XCTAssertEqual(parkedAfter["title"] as? String, "需求评审｜旧分支 cccc3333（c86b）")
        XCTAssertEqual(parkedAfter["titleSource"] as? String, "user")

        XCTAssertTrue(try service.verifyAfterExecute(receipt, in: target).passed)
        XCTAssertEqual(try service.restore(receipt.id, to: target, undo: true).state, .undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(parkedItem.name).path))
        XCTAssertEqual(try Data(contentsOf: target.directory.appendingPathComponent(file)), targetBefore)
    }

    func testForkDoesNotCreateDuplicateParkedCloneWhenBranchAlreadyReachable() throws {
        let t: Int64 = 1_794_850_000_000
        let file = try writeEntry("fork-dup", title: "重复分支", cli: "src-dup-cli", turns: 15, lastActivityAt: t + 10_000, space: source)
        try writeEntry("fork-dup", title: "重复分支", cli: "dst-dup-cli", turns: 10, lastActivityAt: t, space: target)
        // Target ALREADY has another entry referencing dst-dup-cli.
        try writeEntry("existing-clone", title: "重复分支｜旧分支 dst-dup-（7dd4）", cli: "dst-dup-cli", turns: 10, lastActivityAt: t, space: target)

        let plan = try service.plan(
            source: source, target: target, selected: [file], updateExisting: true,
            forkResolutions: [file: .takeSource]
        )
        XCTAssertEqual(plan.updatedCount, 1)
        XCTAssertEqual(plan.parkedCount, 0, "Reachable branch must not be cloned twice")
        let receipt = try service.execute(plan)
        XCTAssertTrue(try service.verifyAfterExecute(receipt, in: target).passed)
    }

    // MARK: - Auto-inferred --new-since cutoff (Section 9 #1)
    func testInferredNewSinceUsesEarliestActiveTargetSessionAndFiltersOnlyAdditions() throws {
        let cal = Calendar.current
        let nov10 = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15, minute: 30))!
        let nov01 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12, minute: 0))!
        let nov12 = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 0))!
        let oct20 = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8, minute: 0))!

        // Empty target -> inferredNewSince is nil
        XCTAssertNil(try service.inferredNewSince(for: target))

        // Target has an archived Oct 20 session (must be ignored!) and active Nov 10 + Nov 12 sessions.
        try writeEntry("arch-old", title: "归档老会话", cli: "cli-arch-old", turns: 3, lastActivityAt: Int64(oct20.timeIntervalSince1970 * 1000), isArchived: true, space: target)
        try writeEntry("dst-earliest", title: "目标最早活跃", cli: "cli-dst-earliest", turns: 5, lastActivityAt: Int64(nov10.timeIntervalSince1970 * 1000), space: target)
        try writeEntry("dst-newer", title: "目标较新", cli: "cli-dst-newer", turns: 10, lastActivityAt: Int64(nov12.timeIntervalSince1970 * 1000), space: target)

        let inferred = try XCTUnwrap(try service.inferredNewSince(for: target))
        XCTAssertEqual(inferred, cal.startOfDay(for: nov10), "Auto cutoff must be local start-of-day of earliest active target session")

        // Source has: old addition (Nov 01 < Nov 10), recent addition (Nov 12 >= Nov 10), and update to existing Nov 10 session.
        let oldAdd = try writeEntry("src-old", title: "老新增", cli: "cli-src-old", turns: 4, lastActivityAt: Int64(nov01.timeIntervalSince1970 * 1000), space: source)
        let newAdd = try writeEntry("src-new", title: "新会话", cli: "cli-src-new", turns: 6, lastActivityAt: Int64(nov12.timeIntervalSince1970 * 1000), space: source)
        let existingUpdate = try writeEntry("dst-earliest", title: "目标最早活跃", cli: "cli-dst-earliest", turns: 12, lastActivityAt: Int64(nov10.timeIntervalSince1970 * 1000) + 1000, space: source)

        let rows = try service.rows(source: source, target: target, updateExisting: true, newSince: inferred)
        let oldRow = try XCTUnwrap(rows.first { $0.id == oldAdd })
        XCTAssertEqual(oldRow.kind, .skip)
        XCTAssertTrue(oldRow.skippedByCutoff)
        XCTAssertTrue(oldRow.reason.contains("2026-11-10"))
        XCTAssertEqual(rows.first { $0.id == newAdd }?.kind, .add)
        XCTAssertEqual(rows.first { $0.id == existingUpdate }?.kind, .update)

        // Clearing cutoff (newSince: nil) makes oldAdd selectable again.
        let allRows = try service.rows(source: source, target: target, updateExisting: true, newSince: nil)
        XCTAssertEqual(allRows.first { $0.id == oldAdd }?.kind, .add)
    }

    // MARK: - Post-write verification catches anomalies
    func testVerifyAfterExecuteDetectsDuplicateCliMissingItemAndDeadTranscript() throws {
        let t: Int64 = 1_794_900_000_000
        let a = try writeEntry("v1", title: "验证项1", cli: "cli-v1", turns: 5, lastActivityAt: t, space: source)
        let plan = try service.plan(source: source, target: target, selected: [a], updateExisting: true)
        let receipt = try service.execute(plan)
        XCTAssertTrue(try service.verifyAfterExecute(receipt, in: target).passed)

        // Inject duplicate active cli in target -> verification must fail!
        try writeEntry("v1-dup", title: "重复项", cli: "cli-v1", turns: 5, lastActivityAt: t, space: target)
        let dupCheck = try service.verifyAfterExecute(receipt, in: target)
        XCTAssertFalse(dupCheck.passed)
        XCTAssertEqual(dupCheck.duplicateActiveClis, ["cli-v1"])
        try FileManager.default.removeItem(at: target.directory.appendingPathComponent("local_v1-dup.json"))

        // Remove transcript -> verification must detect dead transcript!
        let raw = transcripts.appendingPathComponent("matchat/cli-v1.jsonl")
        try FileManager.default.removeItem(at: raw)
        let deadCheck = try service.verifyAfterExecute(receipt, in: target)
        XCTAssertFalse(deadCheck.passed)
        XCTAssertEqual(deadCheck.deadTranscripts, [a])
    }
}
