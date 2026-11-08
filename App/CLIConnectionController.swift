import Foundation
import Combine
import SwitcherCore

struct CLIConnectionContext: Equatable {
    let profile: String
    let identity: CLIIdentity
}

@MainActor struct CLIConnectionOperations {
    let context: () -> CLIConnectionContext?
    let load: (CLIIdentity) throws -> CLIBinding?
    let save: (CLIBinding) throws -> Void
    let make: (CLIBindingChoice, CLIIdentity) throws -> CLIBinding
    let status: (CLIBinding) async throws -> CLIBindingStatus
    let launch: (CLIBinding) async throws -> Void
    var existingDirectory: (CLIBinding) -> Bool = { _ in false }
    var localRecord: (CLIIdentity, CLIBinding?) -> CLILocalRecord = { _, _ in .unconfirmed }
    var hasLegacyBackup: (String) throws -> Bool = { _ in false }
    var restoreLegacyBackup: (CLIConnectionContext) async throws -> Void = { _ in
        throw SafetyError("旧 CLI 备份无法恢复。")
    }
}

@MainActor final class CLIConnectionController: ObservableObject {
    enum Phase { case unlinked, checking, choosing, opening, waitingForLogin, matched, mismatched, unconfirmed, failed }
    @Published private(set) var phase: Phase = .unlinked
    @Published private(set) var choice: CLIBindingChoice?
    @Published private(set) var detail: String?
    @Published private(set) var defaultMatches = false
    @Published private(set) var expectedProfile = ""
    @Published private(set) var checkedAt: Date?
    @Published private(set) var localRecord: CLILocalRecord = .unconfirmed
    @Published private(set) var legacyBackupAvailable = false
    var isBusy: Bool { phase == .checking || phase == .opening }
    private let operations: CLIConnectionOperations
    private var binding: CLIBinding?
    var currentBinding: CLIBinding? { binding }
    func bindingForCachedUsage() -> CLIBinding? {
        guard let context else { return nil }
        if let binding { return binding }
        guard case .sameAccount(let choice) = localRecord else { return nil }
        return try? operations.make(choice, context.identity)
    }
    private var context: CLIConnectionContext?
    private var generation = 0
    init(operations: CLIConnectionOperations) { self.operations = operations }

    func contextDidChange() {
        let observed = operations.context()
        guard observed != context else { return }
        generation += 1; context = observed
        legacyBackupAvailable = false
        expectedProfile = observed?.profile ?? ""; detail = nil; defaultMatches = false; checkedAt = nil; localRecord = .unconfirmed
        do { binding = try observed.flatMap { try operations.load($0.identity) } }
        catch { binding = nil; choice = nil; phase = .failed; detail = error.localizedDescription; return }
        choice = binding?.choice
        if let observed { localRecord = operations.localRecord(observed.identity, binding) }
        phase = binding == nil ? .unlinked : .unconfirmed
    }
    func refreshLocalRecord() {
        guard let context else { localRecord = .unconfirmed; return }
        let observed = operations.localRecord(context.identity, binding)
        guard observed != localRecord else { return }
        localRecord = observed
        if phase == .matched {
            generation += 1; phase = .unconfirmed; checkedAt = nil
        }
    }
    private func stillCurrent(_ captured: CLIConnectionContext, generation: Int) -> Bool {
        guard generation == self.generation, operations.context() == captured else {
            contextDidChange(); return false
        }
        return true
    }
    func open() async {
        contextDidChange()
        guard !isBusy else { return }
        guard let context, context.identity.isComplete else {
            phase = .unconfirmed; detail = "桌面账号身份尚未确认，暂不能关联 CLI。"; return
        }
        let generation = self.generation
        phase = .checking; detail = nil
        legacyBackupAvailable = false
        do {
            let remembered = binding
            var loginDirectory: CLIBinding?
            var rememberedMismatch = false

            func inspect(_ candidate: CLIBinding) async throws -> Bool {
                let status = try await operations.status(candidate)
                // Return true when the caller should stop, including an obsolete request.
                guard stillCurrent(context, generation: generation) else { return true }
                if candidate.choice == .defaultLogin { defaultMatches = status == .matched }
                if status == .matched {
                    try await select(candidate, status: status, context: context, generation: generation)
                    return true
                }
                if candidate == remembered, status == .different { rememberedMismatch = true }
                if status == .notLoggedIn, loginDirectory == nil,
                   candidate == remembered || localRecord == .sameAccount(candidate.choice) {
                    loginDirectory = candidate
                }
                return false
            }
            if let remembered, try await inspect(remembered) { return }
            if remembered?.choice != .defaultLogin {
                let defaultBinding = try operations.make(.defaultLogin, context.identity)
                if try await inspect(defaultBinding) { return }
            }
            if remembered?.choice != .isolated {
                let isolated = try operations.make(.isolated, context.identity)
                if operations.existingDirectory(isolated), try await inspect(isolated) { return }
            }
            do { legacyBackupAvailable = try operations.hasLegacyBackup(context.profile) }
            catch {
                // Failure to inspect the item is not evidence of an empty backup.
                phase = .choosing
                detail = "旧 CLI 备份暂无法检查。"
                return
            }
            if legacyBackupAvailable {
                phase = .choosing
            } else if let loginDirectory {
                try await select(loginDirectory, status: .notLoggedIn, context: context, generation: generation)
            } else {
                phase = rememberedMismatch ? .mismatched : .choosing
            }
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            phase = .failed; detail = error.localizedDescription
        }
    }

    private func select(_ candidate: CLIBinding, status: CLIBindingStatus,
                        context: CLIConnectionContext, generation: Int) async throws {
        if binding != candidate {
            try operations.save(candidate)
            binding = candidate; choice = candidate.choice
            refreshLocalRecord()
        }
        try await complete(status, binding: candidate, context: context, generation: generation)
    }

    /// Invoked only by the explicit, account-scoped confirmation in the picker.
    func restoreLegacyBackup(for expected: CLIConnectionContext) async {
        contextDidChange()
        guard phase == .choosing, legacyBackupAvailable, context == expected else { return }
        let generation = self.generation
        phase = .checking; detail = nil
        do {
            try await operations.restoreLegacyBackup(expected)
            guard stillCurrent(expected, generation: generation) else { return }
            legacyBackupAvailable = false
            phase = .unconfirmed; checkedAt = nil
            refreshLocalRecord()
        } catch {
            guard stillCurrent(expected, generation: generation) else { return }
            phase = .failed; detail = error.localizedDescription
        }
    }
    func choose(_ selected: CLIBindingChoice) async {
        contextDidChange()
        guard !isBusy else { return }
        guard let context, context.identity.isComplete else {
            phase = .unconfirmed; detail = "桌面账号身份尚未确认，暂不能关联 CLI。"; return
        }
        let generation = self.generation
        phase = .checking; detail = nil
        legacyBackupAvailable = false
        do {
            let chosen = try operations.make(selected, context.identity)
            let status = try await operations.status(chosen)
            guard stillCurrent(context, generation: generation) else { return }
            // An explicitly different default must never be turned into a login
            // prompt for this profile. Existing default history stays in place.
            guard status == .matched || status == .notLoggedIn else {
                phase = status == .different ? .mismatched : .unconfirmed; return
            }
            try operations.save(chosen); binding = chosen; choice = chosen.choice; refreshLocalRecord()
            try await complete(status, binding: chosen, context: context, generation: generation)
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            phase = .failed; detail = error.localizedDescription
        }
    }
    private func complete(_ status: CLIBindingStatus, binding: CLIBinding,
                          context: CLIConnectionContext, generation: Int) async throws {
        checkedAt = Date()
        switch status {
        case .matched, .notLoggedIn:
            phase = .opening
            try await operations.launch(binding)
            guard stillCurrent(context, generation: generation) else { return }
            phase = status == .matched ? .matched : .waitingForLogin
            if status == .matched { localRecord = .sameAccount(binding.choice) }
        case .different: phase = .mismatched; localRecord = .differentAccount
        case .unconfirmed: phase = .unconfirmed
        }
    }
    func confirmLogin() async {
        contextDidChange()
        guard !isBusy, let context, let binding else { return }
        let generation = self.generation; phase = .checking; detail = nil
        do {
            let status = try await operations.status(binding)
            guard stillCurrent(context, generation: generation) else { return }
            checkedAt = Date()
            switch status {
            case .matched: phase = .matched; localRecord = .sameAccount(binding.choice)
            case .notLoggedIn: phase = .waitingForLogin
            case .different: phase = .mismatched; localRecord = .differentAccount
            case .unconfirmed: phase = .unconfirmed
            }
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            phase = .failed; detail = error.localizedDescription
        }
    }
    func resetChoice() {
        guard !isBusy else { return }
        generation += 1; phase = .choosing; detail = nil
    }
    func defaultLoginDidChange() {
        refreshLocalRecord()
        guard choice == .defaultLogin else { return }
        if phase == .waitingForLogin { checkedAt = nil; return }
        generation += 1; phase = .unconfirmed; checkedAt = nil; detail = nil
    }
}
