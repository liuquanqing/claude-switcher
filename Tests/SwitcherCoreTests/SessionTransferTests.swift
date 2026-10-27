import XCTest
@testable import SwitcherCore

final class SessionTransferTests: FixtureTest {
    typealias Disk = SessionTransferDisk
    var source: SessionTransferSpace!
    var target: SessionTransferSpace!
    var transcripts: URL!
    var backups: URL!
    var service: SessionTransferService { SessionTransferService(transcripts: transcripts, backups: backups) }
    override func setUpWithError() throws {
        try super.setUpWithError()
        let a = try directory("source"), b = try directory("target")
        _ = try directory("source/claude-code-sessions/account-a/org-a")
        _ = try directory("target/claude-code-sessions/account-b/org-b")
        source = SessionTransferSpace(endpoint: .init(id: "a", name: "来源", root: a), account: "account-a", organization: "org-a")
        target = SessionTransferSpace(endpoint: .init(id: "b", name: "目标", root: b), account: "account-b", organization: "org-b")
        transcripts = try directory("projects"); _ = try directory("projects/project")
        backups = folder.appendingPathComponent("backups")
    }
    @discardableResult func index(_ name: String = "one", cli: String? = nil, logical: String? = nil, turns: Int = 20, time: Int = 2000,
                                 space: SessionTransferSpace? = nil, extras: [String: Any] = [:], transcript: Bool = true) throws -> String {
        let dest = space ?? source!, id = cli ?? "cli-" + name, file = "local_" + name + ".json"
        var value: [String: Any] = ["sessionId": logical ?? "logical-" + name, "cliSessionId": id, "title": "具体会话：" + name,
            "cwd": "/fake/project", "completedTurns": turns, "lastActivityAt": time]
        extras.forEach { value[$0] = $1 }
        try writeJSON(value, dest.directory.appendingPathComponent(file))
        if transcript {
            let path = transcripts.appendingPathComponent("project/" + id + ".jsonl")
            if !FileManager.default.fileExists(atPath: path.path) { try Data("FICTIONAL TRANSCRIPT \(id)\n".utf8).write(to: path) }
        }
        return file
    }
    func plan(_ names: Set<String> = ["local_one.json"], updates: Bool = false, engine: SessionTransferService? = nil) throws -> SessionTransferPlan {
        try (engine ?? service).plan(source: source, target: target, selected: names, updateExisting: updates)
    }
    func bytes(_ name: String, in space: SessionTransferSpace) throws -> Data { try Data(contentsOf: space.directory.appendingPathComponent(name)) }
    func mutateReceipt(_ receipt: SessionTransferReceipt, state: SessionTransferReceiptState) throws {
        var value = receipt; value.state = state
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: backups.appendingPathComponent(receipt.id + "/receipt.json"), options: .atomic)
    }
    func testSpacesAreExplicitAcrossAccountsAndAPIOrganizations() throws {
        _ = try directory("source/claude-code-sessions/account-a/org-two")
        _ = try directory("source/claude-code-sessions/local-api/space")
        let result = try service.spaces(in: source.endpoint)
        XCTAssertEqual(result.count, 3); XCTAssertEqual(Set(result.map(\.id)).count, 3)
    }
    func testAddBacksUpBeforeWritingAndNeverChangesSourceOrTranscript() throws {
        let file = try index(extras: ["futureField": ["keep": true], "remoteMcpServersConfig": ["private"], "armedWorkAtQuit": true])
        let original = try bytes(file, in: source), rawPath = transcripts.appendingPathComponent("project/cli-one.jsonl"), raw = try Data(contentsOf: rawPath)
        let result = try service.execute(plan())
        XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.addedCount, 1)
        let dest = try Disk.json(bytes(file, in: target)); XCTAssertNil(dest["remoteMcpServersConfig"]); XCTAssertNil(dest["armedWorkAtQuit"]); XCTAssertNotNil(dest["futureField"])
        XCTAssertEqual(try bytes(file, in: source), original); XCTAssertEqual(try Data(contentsOf: rawPath), raw)
        XCTAssertEqual(try service.loadReceipt(result.id).items[0].beforeHash, nil)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups.appendingPathComponent(result.id).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups.appendingPathComponent(result.id + "/after-0.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testDefaultExistingRecordIsNotUpdated() throws {
        try index(); let file = try index(turns: 10, time: 1000, space: target); let before = try bytes(file, in: target)
        XCTAssertEqual(try service.rows(source: source, target: target, updateExisting: false)[0].kind, .skip)
        XCTAssertThrowsError(try plan()); XCTAssertEqual(try bytes(file, in: target), before)
    }
    func testUpdatePreservesTargetTitleUnknownFieldsAndConnections() throws {
        try index(); let file = try index(turns: 10, time: 1000, space: target, extras: ["title": "目标自己改的标题", "newUnknown": 42, "remoteMcpServersConfig": ["target-only"]])
        let before = try bytes(file, in: target), receipt = try service.execute(plan(updates: true))
        XCTAssertEqual(receipt.updatedCount, 1)
        let after = try Disk.json(bytes(file, in: target))
        XCTAssertEqual(after["title"] as? String, "目标自己改的标题"); XCTAssertEqual(after["newUnknown"] as? Int, 42)
        XCTAssertNotNil(after["remoteMcpServersConfig"]); XCTAssertEqual(after["completedTurns"] as? Int, 20)
        XCTAssertEqual(try Data(contentsOf: backups.appendingPathComponent(receipt.id + "/before-0.json")), before)
    }
    func testTargetAheadAndIncomparableProgressAreNotOverwritten() throws {
        try index(); try index(turns: 30, time: 3000, space: target)
        XCTAssertEqual(try service.rows(source: source, target: target, updateExisting: true)[0].kind, .skip)
        try index(turns: 1, time: 3000, space: target)
        XCTAssertThrowsError(try plan(updates: true))
    }
    func testContinuationListAndInventedProofNeverAuthorizeOverwrite() throws {
        try index(cli: "new-cli", turns: 2, extras: ["priorCliSessionIds": ["old-cli"], "fixtureProof": ["targetHasNoProgressAfterJoin": true]])
        try index(cli: "old-cli", turns: 120, space: target)
        XCTAssertEqual(try service.rows(source: source, target: target, updateExisting: true)[0].kind, .blocked)
        XCTAssertThrowsError(try plan(updates: true))
    }
    func testLogicalDuplicateUnderDifferentFilenameIsSkipped() throws {
        try index(); try index("renamed", cli: "cli-one", logical: "logical-one", space: target)
        XCTAssertEqual(try service.rows(source: source, target: target, updateExisting: true)[0].kind, .skip)
        XCTAssertThrowsError(try plan(updates: true))
    }
    func testSameFilenameUnrelatedSessionCannotBeReplaced() throws {
        try index(); try index(cli: "other-cli", logical: "other-logical", space: target)
        XCTAssertThrowsError(try plan(updates: true))
    }
    func testUnreadableTargetIsNotMissing() throws {
        try index(); let file = target.directory.appendingPathComponent("local_one.json"); try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try plan()); XCTAssertEqual(try String(contentsOf: file), "broken")
    }
    func testUnsupportedSourceStillShowsConcreteTitleAndProject() throws {
        try writeJSON(["title": "还能识别的会话", "cwd": "/fake/visible-project"], source.directory.appendingPathComponent("local_old.json"))
        let row = try XCTUnwrap(service.rows(source: source, target: target, updateExisting: false).first)
        XCTAssertEqual(row.title, "还能识别的会话"); XCTAssertEqual(row.project, "visible-project"); XCTAssertFalse(row.selectable)
    }
    func testArchivedAndDeletedEntriesNeverResurrect() throws {
        try index(extras: ["isArchived": true]); XCTAssertThrowsError(try plan())
        try index(extras: ["isArchived": false]); try Data().write(to: target.directory.appendingPathComponent("deleted_cli-one")); XCTAssertThrowsError(try plan())
    }
    func testMalformedArchiveListStopsInsteadOfAssumingEmpty() throws {
        try index(); try Data("broken".utf8).write(to: target.directory.appendingPathComponent("archived-sessions.idx"))
        XCTAssertThrowsError(try plan())
    }
    func testMissingAndDuplicateTranscriptsCannotCreateEmptyIndexes() throws {
        try index(transcript: false); XCTAssertThrowsError(try plan())
        try index(); let duplicate = try directory("projects/other"); try Data("second".utf8).write(to: duplicate.appendingPathComponent("cli-one.jsonl")); XCTAssertThrowsError(try plan())
    }
    func testSymlinkTranscriptAndNamespaceAreRejected() throws {
        try index(transcript: false); let outside = folder.appendingPathComponent("outside"); try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: transcripts.appendingPathComponent("project/cli-one.jsonl"), withDestinationURL: outside)
        XCTAssertThrowsError(try plan()); XCTAssertEqual(try String(contentsOf: outside), "outside")
        let linked = SessionTransferSpace(endpoint: target.endpoint, account: "account-b", organization: "linked")
        try FileManager.default.createSymbolicLink(at: linked.directory, withDestinationURL: source.directory)
        XCTAssertThrowsError(try service.rows(source: source, target: linked, updateExisting: false))
    }
    func testChangedSourceAndTargetInvalidateBeforeBackup() throws {
        try index(); let p = try plan(); try index(turns: 21)
        XCTAssertThrowsError(try service.execute(p)); XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        let p2 = try plan(); try index(space: target)
        XCTAssertThrowsError(try service.execute(p2)); XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testMarkerChangeAndDirectoryRotationInvalidatePlan() throws {
        try index(); let marker = folder.appendingPathComponent("current"); try Data("A".utf8).write(to: marker)
        let endpoint = SessionTransferEndpoint(id: "a", name: "来源", root: source.endpoint.root, marker: marker, expectedMarker: "A")
        source = .init(endpoint: endpoint, account: "account-a", organization: "org-a")
        let p = try plan(); try Data("B".utf8).write(to: marker); XCTAssertThrowsError(try service.execute(p))
        try Data("A".utf8).write(to: marker); let p2 = try plan()
        try FileManager.default.moveItem(at: target.endpoint.root, to: folder.appendingPathComponent("parked-old"))
        _ = try directory("target/claude-code-sessions/account-b/org-b")
        XCTAssertThrowsError(try service.execute(p2))
    }
    func testUnrelatedTargetAdditionAndTranscriptAppendDoNotInvalidate() throws {
        try index(); let p = try plan(); try index("unrelated", space: target)
        let raw = transcripts.appendingPathComponent("project/cli-one.jsonl"); try Data("APPENDED BY A FAKE CLI\n".utf8).write(to: raw)
        XCTAssertEqual(try service.execute(p).state, .completed)
        XCTAssertEqual(try String(contentsOf: raw), "APPENDED BY A FAKE CLI\n")
    }
    func testBackupWriteFailureChangesNoTarget() throws {
        try index(); let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { _, _, _ in throw SafetyError("fixture backup denied") }))
        XCTAssertThrowsError(try engine.execute(plan()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }
    func testBackupReadbackFailureChangesNoTarget() throws {
        try index(); let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            try SessionTransferDisk.write(url.lastPathComponent.hasPrefix("after-") ? Data("bad backup".utf8) : data, url, mode)
        }))
        XCTAssertThrowsError(try engine.execute(plan()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }
    func testSecondTargetWriteFailureRestoresWholeBatch() throws {
        let one = try index("one"), two = try index("two"); try index("two", turns: 1, time: 1000, space: target)
        let targetBefore = try bytes(two, in: target), sourceBefore = try bytes(one, in: source)
        var targetWrites = 0
        let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url.deletingLastPathComponent() == self.target.directory { targetWrites += 1; if targetWrites == 2 { throw SafetyError("fixture disk full") } }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try engine.execute(plan([one, two], updates: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(one).path))
        XCTAssertEqual(try bytes(two, in: target), targetBefore); XCTAssertEqual(try bytes(one, in: source), sourceBefore)
        XCTAssertEqual(try service.receipts().first?.state, .restored)
    }
    func testForeignTargetDuringFailedCreateIsPreservedWithoutBlockingRecovery() throws {
        let file = try index(); let foreign = Data("FOREIGN NEW PROGRESS".utf8)
        let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url == self.target.directory.appendingPathComponent(file) { try foreign.write(to: url) }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try engine.execute(plan()))
        XCTAssertEqual(try bytes(file, in: target), foreign); XCTAssertEqual(try service.receipts().first?.state, .restored)
    }
    func testUndoRestoresOldBytesAndOnlyRemovesOwnNewItems() throws {
        let a = try index("one"), b = try index("two"); try index("two", turns: 1, time: 1000, space: target)
        let old = try bytes(b, in: target); let receipt = try service.execute(plan([a, b], updates: true))
        try index("unrelated", space: target)
        XCTAssertEqual(try service.restore(receipt.id, to: target, undo: true).state, .undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(a).path)); XCTAssertEqual(try bytes(b, in: target), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent("local_unrelated.json").path))
    }
    func testUndoConflictHasZeroWritesToOtherItems() throws {
        let a = try index("one"), b = try index("two"); let receipt = try service.execute(plan([a,b])); let untouched = try bytes(b, in: target)
        try index("one", turns: 99, time: 9999, space: target); let progress = try bytes(a, in: target)
        XCTAssertThrowsError(try service.restore(receipt.id, to: target, undo: true))
        XCTAssertEqual(try bytes(a, in: target), progress); XCTAssertEqual(try bytes(b, in: target), untouched)
        XCTAssertEqual(try service.loadReceipt(receipt.id).state, .completed)
    }
    func testInterruptedPartialCopyCanRecoverUsingJournalHashes() throws {
        let a = try index("one"), b = try index("two"); let receipt = try service.execute(plan([a,b]))
        try FileManager.default.removeItem(at: target.directory.appendingPathComponent(b))
        try mutateReceipt(receipt, state: .copying)
        XCTAssertTrue(try service.loadReceipt(receipt.id).state.needsRecovery)
        XCTAssertEqual(try service.restore(receipt.id, to: target, undo: false).state, .restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(a).path))
    }
    func testReceiptAndBackupsExistBeforeFirstTargetWrite() throws {
        try index(); var observed = false
        let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url.deletingLastPathComponent() == self.target.directory {
                let r = try XCTUnwrap(self.service.receipts().first); XCTAssertEqual(r.state, .copying)
                XCTAssertTrue(FileManager.default.fileExists(atPath: self.backups.appendingPathComponent(r.id + "/after-0.json").path)); observed = true
            }
            try SessionTransferDisk.write(data, url, mode)
        }))
        _ = try engine.execute(plan()); XCTAssertTrue(observed)
    }
    func testCorruptBackupCannotBeRestored() throws {
        let file = try index(); let receipt = try service.execute(plan()); let now = try bytes(file, in: target)
        try Data("corrupt".utf8).write(to: backups.appendingPathComponent(receipt.id + "/after-0.json"))
        XCTAssertThrowsError(try service.restore(receipt.id, to: target, undo: true)); XCTAssertEqual(try bytes(file, in: target), now)
    }
    func testWrongSpaceAndTamperedBackupPathAreRejected() throws {
        try index(); let receipt = try service.execute(plan())
        XCTAssertThrowsError(try service.restore(receipt.id, to: source, undo: true))
        let path = backups.appendingPathComponent(receipt.id + "/receipt.json"); var object = try Disk.json(Data(contentsOf: path))
        var items = object["items"] as! [[String: Any]]; items[0]["afterFile"] = "../../outside"; object["items"] = items
        try writeJSON(object, path); XCTAssertThrowsError(try service.loadReceipt(receipt.id))
    }
    func testRestoreResolvesOriginalDirectoryAfterProfileMove() throws {
        try index(); let receipt = try service.execute(plan())
        let relocated = folder.appendingPathComponent("parked-target"); try FileManager.default.moveItem(at: target.endpoint.root, to: relocated)
        let resolved = SessionTransferSpace(endpoint: .init(id: target.endpoint.id, name: "目标", root: relocated), account: target.account, organization: target.organization)
        XCTAssertEqual(try service.restore(receipt.id, to: resolved, undo: true).state, .undone)
    }
    func testIdleGateNeverInvokesTargetWrite() throws {
        try index(); XCTAssertThrowsError(try service.execute(plan(), requireIdle: { throw SafetyError("fake desktop still running") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }
    func testIncompleteOperationBlocksSameTargetNotOtherSpace() throws {
        try index(); let receipt = try service.execute(plan()); try mutateReceipt(receipt, state: .copying)
        try index("two")
        XCTAssertThrowsError(try service.execute(plan(["local_two.json"])))
        let api = try directory("api"); _ = try directory("api/claude-code-sessions/local-api/org")
        let other = SessionTransferSpace(endpoint: .init(id: "api", name: "API工作区", root: api), account: "local-api", organization: "org")
        let p = try service.plan(source: source, target: other, selected: ["local_two.json"], updateExisting: false)
        XCTAssertEqual(try service.execute(p).state, .completed)
    }
    func testDuplicateSourceIdentityAndBooleanProgressAreRejected() throws {
        let a = try index("one"), b = try index("alias", cli: "cli-one", logical: "logical-one")
        XCTAssertThrowsError(try plan([a,b]))
        try index("one", space: target, extras: ["completedTurns": true])
        XCTAssertThrowsError(try plan([a], updates: true))
    }
    func testCompletedReceiptSaveFailureRollsBackTargets() throws {
        let file = try index(); var saves = 0
        let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url.lastPathComponent == "receipt.json" { saves += 1; if saves == 2 { throw SafetyError("fixture receipt denied") } }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try engine.execute(plan()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(file).path)); XCTAssertEqual(try service.receipts().first?.state, .restored)
    }
    func testMissingHistoricalTranscriptBlocksNewIndex() throws {
        try index(extras: ["priorCliSessionIds": ["missing-history"]])
        XCTAssertThrowsError(try plan())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }
    func testSilentTargetWriteIsDetectedAndRestored() throws {
        let file = try index(); try index(turns: 1, time: 1000, space: target)
        let before = try bytes(file, in: target)
        let engine = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url.deletingLastPathComponent() == self.target.directory { return }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try engine.execute(plan(updates: true)))
        XCTAssertEqual(try bytes(file, in: target), before); XCTAssertEqual(try service.receipts().first?.state, .restored)
    }
    func testRecoveryFailureIsRecordedAndCanBeRetriedWithoutOverwriting() throws {
        let a = try index("one"), b = try index("two"), receipt = try service.execute(plan([a,b]))
        var removes = 0
        let failed = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(remove: { url in
            removes += 1; if removes == 2 { throw SafetyError("fixture remove denied") }
            try FileManager.default.removeItem(at: url)
        }))
        XCTAssertThrowsError(try failed.restore(receipt.id, to: target, undo: true))
        XCTAssertEqual(try service.loadReceipt(receipt.id).state, .recoveryRequired)
        XCTAssertEqual(try service.restore(receipt.id, to: target, undo: false).state, .undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(a).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(b).path))
    }
    func testBackupSymlinkDoesNotWriteOutsideDeclaredDirectory() throws {
        try index(); let outside = try directory("outside-backup")
        try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
        XCTAssertThrowsError(try service.execute(plan()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testAliasedEndpointsCannotCopyToSamePhysicalNamespace() throws {
        try index()
        let alias = SessionTransferSpace(endpoint: .init(id: "alias", name: "别名", root: source.endpoint.root), account: source.account, organization: source.organization)
        XCTAssertThrowsError(try service.plan(source: source, target: alias, selected: ["local_one.json"], updateExisting: false))
    }

    func testOutOfRangeTimestampCannotCrashNativeTimeLabels() throws {
        try index(extras: ["lastActivityAt": 1e300])
        let row = try XCTUnwrap(service.rows(source: source, target: target, updateExisting: false).first)
        XCTAssertFalse(row.selectable); XCTAssertEqual(row.title, "具体会话：one")
    }

    func testExplicitKeepCurrentClosesUnresolvedRecordWithoutTouchingAnyTarget() throws {
        let file = try index(); let originalSource = try bytes(file, in: source)
        var foreign: [String: Any] = ["sessionId": "foreign-logical", "cliSessionId": "foreign-cli", "cwd": "/fake/other", "title": "外部新进展"]
        foreign["completedTurns"] = 8; foreign["lastActivityAt"] = 3000
        let foreignBytes = try Disk.encode(foreign)
        let second = try index("two")
        let failed = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url == self.target.directory.appendingPathComponent(second) {
                try foreignBytes.write(to: self.target.directory.appendingPathComponent(file))
                throw SafetyError("fixture second write failed after external progress")
            }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try failed.execute(plan([file, second])))
        let receipt = try XCTUnwrap(service.receipts().first)
        XCTAssertEqual(receipt.state, .recoveryRequired)
        XCTAssertThrowsError(try service.restore(receipt.id, to: target, undo: false))
        let closed = try service.keepCurrentData(receipt.id, in: target)
        XCTAssertEqual(closed.state, .preserved); XCTAssertFalse(closed.state.needsRecovery)
        XCTAssertEqual(try bytes(file, in: target), foreignBytes); XCTAssertEqual(try bytes(file, in: source), originalSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appendingPathComponent(receipt.id + "/after-0.json").path))
        let another = try index("three")
        XCTAssertEqual(try service.execute(plan([another])).state, .completed)
        XCTAssertThrowsError(try plan([file]))
    }
    func testKeepCurrentCannotCloseAnotherSpaceOrCompletedOperation() throws {
        try index(); let receipt = try service.execute(plan())
        XCTAssertThrowsError(try service.keepCurrentData(receipt.id, in: target))
        try mutateReceipt(receipt, state: .copying)
        XCTAssertThrowsError(try service.keepCurrentData(receipt.id, in: source))
        XCTAssertEqual(try service.loadReceipt(receipt.id).state, .copying)
    }
    func testKeepCurrentReportsUnverifiedBackupWithoutChangingTarget() throws {
        let file = try index(), receipt = try service.execute(plan())
        let targetBytes = try bytes(file, in: target)
        try mutateReceipt(receipt, state: .copying)
        let backup = backups.appendingPathComponent(receipt.id + "/after-0.json")
        try Data("damaged fixture backup".utf8).write(to: backup)
        let closed = try service.keepCurrentData(receipt.id, in: target)
        XCTAssertEqual(closed.state, .preserved)
        XCTAssertTrue(closed.message?.contains("备份缺失或无法核对") == true)
        XCTAssertFalse(closed.message?.contains("备份已核对") == true)
        XCTAssertEqual(try bytes(file, in: target), targetBytes)
        XCTAssertEqual(try Data(contentsOf: backup), Data("damaged fixture backup".utf8))
    }

    func testExclusiveCreateFailureNeverDeletesAnIdenticalForeignIndex() throws {
        let file = try index(); let planned = try plan(); let identical = planned.changes[0].after
        let raced = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { data, url, mode in
            if url == self.target.directory.appendingPathComponent(file) { try identical.write(to: url) }
            try SessionTransferDisk.write(data, url, mode)
        }))
        XCTAssertThrowsError(try raced.execute(planned))
        XCTAssertEqual(try bytes(file, in: target), identical)
        XCTAssertEqual(try service.receipts().first?.state, .restored)
    }

    func testNewCopyRejectsUnadaptedIdentityOrCredentialBindings() throws {
        for field in ["accountUuid", "organizationUuid", "accessToken", "apiKey", "providerConfig"] {
            try index(extras: [field: "FICTIONAL BINDING"])
            let row = try XCTUnwrap(service.rows(source: source, target: target, updateExisting: false).first)
            XCTAssertEqual(row.title, "具体会话：one"); XCTAssertFalse(row.selectable)
            XCTAssertThrowsError(try plan())
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }

    func testDisplayedSourceIdentityCannotSilentlyBecomeAnotherSession() throws {
        let name = try index()
        let displayed = try XCTUnwrap(service.rows(source: source, target: target, updateExisting: false).first)
        try index(cli: "other-cli", logical: "other-logical", extras: ["title": "另一条具体会话"])
        XCTAssertThrowsError(try service.plan(source: source, target: target, selected: [name], updateExisting: false, expectedSourceIdentities: [name: displayed.identity]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testSameSourceSessionProgressCanAdvanceBeforePlanWithoutLosingIdentity() throws {
        let name = try index(), displayed = try XCTUnwrap(service.rows(source: source, target: target, updateExisting: false).first)
        try index(turns: 21, time: 3000)
        let p = try service.plan(source: source, target: target, selected: [name], updateExisting: false, expectedSourceIdentities: [name: displayed.identity])
        XCTAssertEqual(try service.execute(p).state, .completed)
        XCTAssertEqual(try Disk.json(bytes(name, in: target))["completedTurns"] as? Int, 21)
    }

    func exportedRequest() throws -> (SessionTransferRequest, URL) {
        let request = try SessionTransferRequest(plan: plan(), transcripts: transcripts, backups: backups)
        let url = folder.appendingPathComponent("requests/a request's name.json")
        try request.save(to: url)
        return (request, url)
    }
    func command(_ verb: String, request: URL, extra: [String] = [], idle: () throws -> Void = {}) throws -> [String: Any] {
        try Disk.json(SessionTransferCommand.run([verb, "--request", request.path] + extra, requireIdle: idle))
    }
    func testCommandPlanExportsNoContentAndDoesNotWriteTarget() throws {
        let file = try index(); let original = try bytes(file, in: source)
        let (request, url) = try exportedRequest(), result = try command("plan", request: url)
        XCTAssertEqual(result["status"] as? String, "ready")
        XCTAssertEqual(result["fingerprint"] as? String, request.expectedFingerprint)
        XCTAssertEqual((result["sessions"] as? [[String: String]])?.first?["title"], "具体会话：one")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path)); XCTAssertEqual(try bytes(file, in: source), original)
        let encoded = try String(contentsOf: url)
        XCTAssertFalse(encoded.contains("completedTurns")); XCTAssertFalse(encoded.contains("FICTIONAL TEST ONLY"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCommandApplyRequiresExpectedFingerprintAndExplicitIdle() throws {
        try index(); let (request, url) = try exportedRequest()
        XCTAssertThrowsError(try command("apply", request: url))
        XCTAssertThrowsError(try command("apply", request: url, extra: ["--expect", "wrong"]))
        XCTAssertThrowsError(try command("apply", request: url, extra: ["--expect", request.expectedFingerprint], idle: { throw SafetyError("fixture desktop running") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).isEmpty)
    }
    func testCommandApplyUndoAndDuplicateExecutionUseSameEngine() throws {
        let file = try index(), (request, url) = try exportedRequest()
        let result = try command("apply", request: url, extra: ["--expect", request.expectedFingerprint])
        let id = try XCTUnwrap(result["receiptID"] as? String)
        XCTAssertEqual(result["state"] as? String, "completed")
        XCTAssertEqual(try service.loadReceipt(id).items.first?.cwd, "/fake/project")
        XCTAssertThrowsError(try command("apply", request: url, extra: ["--expect", request.expectedFingerprint]))
        XCTAssertEqual(try command("undo", request: url, extra: ["--receipt", id.lowercased()])["state"] as? String, "undone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.directory.appendingPathComponent(file).path))
    }
    func testCommandChangedSourceOrTargetCannotRefreshItsOwnApproval() throws {
        let file = try index(), (request, url) = try exportedRequest()
        try index(turns: 77, time: 4000)
        XCTAssertThrowsError(try command("plan", request: url))
        XCTAssertThrowsError(try command("apply", request: url, extra: ["--expect", request.expectedFingerprint]))
        try index(); try index("one", logical: "foreign", space: target)
        let foreign = try bytes(file, in: target)
        XCTAssertThrowsError(try command("apply", request: url, extra: ["--expect", request.expectedFingerprint]))
        XCTAssertEqual(try bytes(file, in: target), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testCommandRecoveryAndConflictDoNotOverwriteExternalProgress() throws {
        let file = try index(), (request, url) = try exportedRequest()
        let result = try command("apply", request: url, extra: ["--expect", request.expectedFingerprint])
        let id = result["receiptID"] as! String, receipt = try service.loadReceipt(id)
        try mutateReceipt(receipt, state: .recoveryRequired)
        try index("one", turns: 999, time: 9999, space: target)
        let external = try bytes(file, in: target)
        XCTAssertThrowsError(try command("recover", request: url, extra: ["--receipt", id]))
        XCTAssertEqual(try bytes(file, in: target), external)
        try receipt.items.first.map { item in try Data(contentsOf: backups.appendingPathComponent(id + "/" + item.afterFile)).write(to: target.directory.appendingPathComponent(file)) }
        XCTAssertEqual(try command("recover", request: url, extra: ["--receipt", id])["state"] as? String, "restored")
    }
    func testCommandRejectsMalformedArgumentsAndRequestSymlinks() throws {
        try index(); let (_, url) = try exportedRequest()
        for extra in [["--request", url.path], ["--unexpected", "x"], ["--expect"], ["--receipt", "bad"]] {
            XCTAssertThrowsError(try command("plan", request: url, extra: extra))
        }
        let link = folder.appendingPathComponent("linked-request.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try command("plan", request: link))
    }
    func testHandoffQuotesShellPathsAndDoesNotContainActualSessionBody() throws {
        try index(); let (request, url) = try exportedRequest()
        let command = URL(fileURLWithPath: "/fake dir/it's $(touch should-not-run)/tool")
        let text = request.instructions(command: command, request: url)
        XCTAssertTrue(text.contains(SessionTransferRequest.shellQuote(command.path)))
        XCTAssertTrue(text.contains("'\"'\"'")); XCTAssertTrue(text.contains("plan --request")); XCTAssertTrue(text.contains("undo --request"))
        XCTAssertFalse(text.contains("FICTIONAL TEST ONLY")); XCTAssertFalse(text.contains("--force"))
    }
    func testReceiptWithoutNewOptionalPathRemainsReadable() throws {
        try index(); let receipt = try service.execute(plan())
        let path = backups.appendingPathComponent(receipt.id + "/receipt.json")
        var object = try Disk.json(Data(contentsOf: path)), items = object["items"] as! [[String: Any]]
        for i in items.indices { items[i].removeValue(forKey: "cwd") }; object["items"] = items
        try Disk.encode(object).write(to: path)
        XCTAssertNil(try service.loadReceipt(receipt.id).items.first?.cwd)
        XCTAssertEqual(try service.restore(receipt.id, to: target, undo: true).state, .undone)
    }
    func testFirstReceiptSaveFailureRetainsItsRecoveryIDBeforeTargetWrite() throws {
        let file = try index()
        let failed = SessionTransferService(transcripts: transcripts, backups: backups, io: .init(write: { bytes, url, mode in
            try SessionTransferDisk.write(bytes, url, mode)
            if url.lastPathComponent == "receipt.json" { throw SafetyError("fixture save acknowledgement failed") }
        }))
        var failedID: String?
        XCTAssertThrowsError(try failed.execute(plan())) { failedID = ($0 as? SessionTransferFailure)?.receiptID }
        let id = try XCTUnwrap(failedID)
        XCTAssertEqual(try service.loadReceipt(id).state, .copying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent(file).path))
        XCTAssertEqual(try service.restore(id, to: target, undo: false).state, .restored)
    }
    func testFallbackWriterRequiresDesktopAndSwitcherExitWithoutBindingTerminalCLI() throws {
        let helper = "/fake/App.app/Contents/Helpers/ClaudeSessionTransfer"
        XCTAssertNoThrow(try SessionTransferCommand.checkWriters("/usr/local/bin/claude\n/fake/ClaudeGuard\n" + helper))
        for writer in ["/Applications/Claude.app/Contents/MacOS/Claude", "/fake/Preview.app/Contents/MacOS/ClaudeSwitcher", helper] {
            XCTAssertThrowsError(try SessionTransferCommand.checkWriters(helper + "\n" + writer))
        }
    }

}
