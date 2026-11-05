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
        do {
            if let binding {
                let status = try await operations.status(binding)
                guard stillCurrent(context, generation: generation) else { return }
                try await complete(status, binding: binding, context: context, generation: generation)
            } else {
                let existing = try operations.make(.defaultLogin, context.identity)
                let status = try await operations.status(existing)
                guard stillCurrent(context, generation: generation) else { return }
                defaultMatches = status == .matched
                if status == .matched {
                    try operations.save(existing); binding = existing; choice = existing.choice; refreshLocalRecord()
                    try await complete(status, binding: existing, context: context, generation: generation)
                } else {
                    let isolated = try operations.make(.isolated, context.identity)
                    if operations.existingDirectory(isolated) {
                        let isolatedStatus = try await operations.status(isolated)
                        guard stillCurrent(context, generation: generation) else { return }
                        if isolatedStatus == .matched {
                            try operations.save(isolated); binding = isolated; choice = isolated.choice; refreshLocalRecord()
                            try await complete(isolatedStatus, binding: isolated, context: context, generation: generation)
                            return
                        }
                    }
                    // The existing default belongs to another account or has no
                    // reusable sign-in. Offer a single isolated-login setup.
                    phase = .choosing
                }
            }
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
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
