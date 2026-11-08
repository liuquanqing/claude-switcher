import Foundation
import SwitcherCore

struct CredentialReadSummary:Encodable {
    let category:String
    var reads=0
    var interactiveRequestsAllowed=0
    var interactionRequired=0
    var failures=0
    var missing=0
}
@MainActor final class CredentialReadAudit {
    private var values:[String:CredentialReadSummary]=[:]
    func record(service:String,interactive:Bool,result:Result<Data?,Error>) {
        let category=service==cliService ? "nativeCLI" : service==switcherService ? "ownedBackup" : "other"
        var entry=values[category] ?? CredentialReadSummary(category:category)
        entry.reads += 1
        if interactive {entry.interactiveRequestsAllowed += 1}
        if case .success(nil)=result {entry.missing += 1}
        if case .failure(let error)=result {
            if error is CLIInteractionRequired {entry.interactionRequired += 1} else {entry.failures += 1}
        }
        values[category]=entry
    }
    var summary:[CredentialReadSummary] {values.keys.sorted().compactMap {values[$0]}}
}
struct UsageQueryDiagnostic: Encodable {
    let profileIndex: Int
    let stages: [String]
}
struct RefreshDiagnostics:Encodable {
    var usageQueries: [UsageQueryDiagnostic] = []
    var desktopUsageStages: [String] = []
    var startedAt=Date()
    var completedAt:Date?
    var outcome="pending"
    var recoveryOutcome:String?
    var nativeHelperRuns=0
    var freshQuotaRequests=0
    var quotaCacheAdopted=false
    var credentialReads:[CredentialReadSummary]=[]
    // Permission to ask is not proof that SecurityAgent actually displayed UI.
    let actualSystemDialogsObserved=false
    let scope="manual footer refresh only; no tokens, identities, raw output, or system-dialog count"
    func save() {
        let directory=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("dev.claudeswitcher.candidate/Diagnostics")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            let file=directory.appendingPathComponent("last-refresh-summary.json")
            try encoder.encode(self).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        } catch { /* A diagnostic failure must not alter login or quota state. */ }
    }
}
