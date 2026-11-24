import Foundation
import Combine
import SwitcherCore

struct CLIConnectionContext: Equatable {
    let profile: String
    let identity: CLIIdentity
}

enum CLITerminalIntent: Equatable { case open, signIn }

@MainActor struct CLIConnectionAccess {
    let status: (CLIBinding) async throws -> CLIBindingStatus
    let launch: (CLIBinding, CLITerminalIntent) async throws -> Void
}

@MainActor struct CLIConnectionOperations {
    let context: () -> CLIConnectionContext?
    let load: (CLIIdentity) throws -> CLIBinding?
    let save: (CLIBinding) throws -> Void
    let make: (CLIBindingChoice, CLIIdentity) throws -> CLIBinding
    let access: () async throws -> CLIConnectionAccess
    var usesDefaultLogin: (CLIIdentity) -> Bool = { _ in false }
    var backupDefaultLogin: (CLIConnectionContext) async throws -> Void = { _ in }
    var focusAuthorizationTerminal: () -> Bool = { false }
    var didVerifyLogin: (CLIConnectionContext, CLIBinding) -> Void = { _, _ in }
    var localRecord: (CLIIdentity, CLIBinding?) -> CLILocalRecord = { _, _ in .unconfirmed }
    var hasRecoverableBackup: (CLIConnectionContext) throws -> Bool = { _ in false }
    var restoreLegacyBackup: (CLIConnectionContext) async throws -> Void = { _ in
        throw SafetyError("旧 CLI 备份无法恢复。")
    }
}

@MainActor final class CLIConnectionController: ObservableObject {
    enum Phase { case unlinked, checking, choosing, opening, waitingForLogin, matched, mismatched, unconfirmed, failed }
    @Published private(set) var phase: Phase = .unlinked
    @Published private(set) var choice: CLIBindingChoice?
    @Published private(set) var detail: String?
    @Published private(set) var routeDecision: SafetyDecision?
    @Published private(set) var failureTitle: String?
    @Published private(set) var defaultMatches = false
    @Published private(set) var defaultLoginAvailable = false
    @Published private(set) var expectedProfile = ""
    @Published private(set) var checkedAt: Date?
    @Published private(set) var localRecord: CLILocalRecord = .unconfirmed
    @Published private(set) var legacyBackupAvailable = false
    /// A restore whose rollback could not be confirmed stays unavailable until a fresh login check.
    private var restoreBlockedFor: Set<String> = []
    var isBusy: Bool { phase == .checking || phase == .opening }
    private let operations: CLIConnectionOperations
    private var binding: CLIBinding?
    var currentBinding: CLIBinding? { binding }
    var preferredChoice: CLIBindingChoice? {
        if let context, operations.usesDefaultLogin(context.identity) { return .defaultLogin }
        if let binding { return binding.choice }
        switch localRecord {
        case .sameAccount(let choice): return choice
        case .differentAccount: return .isolated
        case .notPrepared, .unconfirmed: return nil
        }
    }
    func bindingForCachedUsage() -> CLIBinding? {
        guard let context else { return nil }
        if operations.usesDefaultLogin(context.identity) { return try? operations.make(.defaultLogin, context.identity) }
        if let binding { return binding }
        guard case .sameAccount(let choice) = localRecord else { return nil }
        return try? operations.make(choice, context.identity)
    }
    private var context: CLIConnectionContext?
    private var generation = 0
    private var lastObservedPreferredChoice: CLIBindingChoice?
    init(operations: CLIConnectionOperations) { self.operations = operations }

    func contextDidChange() {
        let observed = operations.context()
        guard observed != context else { return }
        generation += 1; context = observed
        legacyBackupAvailable = false
        expectedProfile = observed?.profile ?? ""; clearFeedback(); defaultMatches = false; defaultLoginAvailable = false
        checkedAt = nil; localRecord = .unconfirmed
        do { binding = try observed.flatMap { try operations.load($0.identity) } }
        catch { binding = nil; choice = nil; phase = .failed; detail = error.localizedDescription; lastObservedPreferredChoice = nil; return }
        choice = binding?.choice
        if let observed { localRecord = operations.localRecord(observed.identity, binding) }
        phase = binding == nil ? .unlinked : .unconfirmed
        lastObservedPreferredChoice = preferredChoice
    }
    func refreshLocalRecord() {
        guard let context else {
            localRecord = .unconfirmed
            lastObservedPreferredChoice = nil
            return
        }
        let observed = operations.localRecord(context.identity, binding)
        if observed != localRecord {
            localRecord = observed
            if phase == .matched {
                generation += 1; phase = .unconfirmed; checkedAt = nil
            }
            lastObservedPreferredChoice = preferredChoice
            return
        }
        let currentChoice = preferredChoice
        if currentChoice != lastObservedPreferredChoice {
            lastObservedPreferredChoice = currentChoice
            objectWillChange.send()
        }
    }
    private func stillCurrent(_ captured: CLIConnectionContext, generation: Int) -> Bool {
        guard generation == self.generation, operations.context() == captured else {
            contextDidChange(); return false
        }
        return true
    }
    private func clearFeedback() {
        detail = nil; routeDecision = nil; failureTitle = nil
    }

    private func recordFailure(_ error: Error) {
        if let failure = error as? CLITerminalFailure {
            failureTitle = failure.title
            if case .route(let decision) = failure { routeDecision = decision }
        }
        phase = .failed
        detail = error.localizedDescription
    }

    func open(showLoginChoices: Bool = false) async {
        contextDidChange()
        guard !isBusy else { return }
        guard let context, context.identity.isComplete else {
            phase = .unconfirmed; detail = "桌面账号身份尚未确认，暂不能关联 CLI。"; return
        }
        let generation = self.generation
        let needsPicker = showLoginChoices || binding == nil
        phase = .checking; clearFeedback()
        legacyBackupAvailable = false
        defaultLoginAvailable = false
        defaultMatches = false
        do {
            let access = try await operations.access()
            guard stillCurrent(context, generation: generation) else { return }
            if !showLoginChoices, operations.usesDefaultLogin(context.identity) {
                let candidate = try operations.make(.defaultLogin, context.identity)
                let status = try await access.status(candidate)
                guard stillCurrent(context, generation: generation) else { return }
                if status == .matched {
                    try await complete(status, binding: candidate, access: access, context: context, generation: generation)
                } else {
                    phase = status == .different ? .mismatched : .unconfirmed
                }
                return
            }
            if !needsPicker, let binding {
                try await inspectAndOpen(binding, access: access, context: context, generation: generation)
                return
            }

            let defaultBinding = try operations.make(.defaultLogin, context.identity)
            let defaultStatus = try await access.status(defaultBinding)
            guard stillCurrent(context, generation: generation) else { return }
            let defaultRecord = operations.localRecord(context.identity, defaultBinding)
            defaultMatches = defaultStatus == .matched
            if defaultMatches { restoreBlockedFor.remove(context.profile) }
            defaultLoginAvailable = defaultMatches || (defaultStatus == .notLoggedIn && defaultRecord != .differentAccount)
            if showLoginChoices, !defaultMatches, !restoreBlockedFor.contains(context.profile) {
                do { legacyBackupAvailable = try operations.hasRecoverableBackup(context) }
                catch is CLIInteractionRequired { detail = "旧 CLI 备份暂无法检查。" }
                catch { detail = error.localizedDescription }
            }
            phase = .choosing
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            recordFailure(error)
            if needsPicker { phase = .choosing }
        }
    }

    private func inspectAndOpen(_ candidate: CLIBinding, access: CLIConnectionAccess,
                                context: CLIConnectionContext, generation: Int) async throws {
        let status = try await access.status(candidate)
        guard stillCurrent(context, generation: generation) else { return }
        let differs = status == .different || (status == .notLoggedIn
            && operations.localRecord(context.identity, candidate) == .differentAccount)
        if candidate.choice == .defaultLogin {
            defaultMatches = status == .matched
            if defaultMatches { restoreBlockedFor.remove(context.profile) }
            defaultLoginAvailable = !differs && (defaultMatches || status == .notLoggedIn)
        }
        guard !differs, status == .matched || status == .notLoggedIn else {
            checkedAt = Date()
            phase = differs ? .mismatched : .unconfirmed
            if differs { localRecord = .differentAccount }
            return
        }
        try await select(candidate, status: status, access: access, context: context, generation: generation)
    }

    private func select(_ candidate: CLIBinding, status: CLIBindingStatus, access: CLIConnectionAccess,
                        context: CLIConnectionContext, generation: Int) async throws {
        if binding != candidate {
            try operations.save(candidate)
            binding = candidate; choice = candidate.choice
            refreshLocalRecord()
        }
        try await complete(status, binding: candidate, access: access, context: context, generation: generation)
    }

    /// Invoked only by the explicit, account-scoped confirmation in the picker.
    func restoreLegacyBackup(for expected: CLIConnectionContext) async {
        contextDidChange()
        guard phase == .choosing, legacyBackupAvailable, context == expected else { return }
        let generation = self.generation
        phase = .checking; clearFeedback()
        do {
            try await operations.restoreLegacyBackup(expected)
            guard stillCurrent(expected, generation: generation) else { return }
            legacyBackupAvailable = false
            phase = .unconfirmed; checkedAt = nil
            refreshLocalRecord()
        } catch {
            guard stillCurrent(expected, generation: generation) else { return }
            detail = error.localizedDescription
            let message = error.localizedDescription
            if message.contains("还原未确认") || message.contains("回滚未确认") || message.contains("停止切换") {
                legacyBackupAvailable = false
                restoreBlockedFor.insert(expected.profile)
                phase = .unconfirmed
            } else { phase = .choosing }
        }
    }
    func choose(_ selected: CLIBindingChoice) async {
        contextDidChange()
        guard !isBusy else { return }
        guard let context, context.identity.isComplete else {
            phase = .unconfirmed; detail = "桌面账号身份尚未确认，暂不能关联 CLI。"; return
        }
        let generation = self.generation
        guard selected != .isolated || !operations.usesDefaultLogin(context.identity) else {
            detail = "当前账号已使用默认终端。"
            return
        }
        phase = .checking; clearFeedback()
        legacyBackupAvailable = false
        do {
            let chosen = try binding.flatMap { $0.choice == selected ? $0 : nil }
                ?? operations.make(selected, context.identity)
            let access = try await operations.access()
            guard stillCurrent(context, generation: generation) else { return }
            try await inspectAndOpen(chosen, access: access, context: context, generation: generation)
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            recordFailure(error)
        }
    }
    private func complete(_ status: CLIBindingStatus, binding: CLIBinding, access: CLIConnectionAccess,
                          context: CLIConnectionContext, generation: Int) async throws {
        if status == .matched, binding.choice == .defaultLogin {
            restoreBlockedFor.remove(context.profile)
            await backupDefaultLogin(context, generation: generation)
            guard stillCurrent(context, generation: generation) else { return }
        }
        phase = .opening
        try await access.launch(binding, status == .matched ? .open : .signIn)
        guard stillCurrent(context, generation: generation) else { return }
        checkedAt = Date()
        phase = status == .matched ? .matched : .waitingForLogin
        if status == .matched {
            localRecord = .sameAccount(binding.choice)
            operations.didVerifyLogin(context, binding)
        }
    }
    private func backupDefaultLogin(_ context: CLIConnectionContext, generation: Int) async {
        do { try await operations.backupDefaultLogin(context) }
        catch {
            guard stillCurrent(context, generation: generation) else { return }
            detail = "已登录，但备份尚未更新。"
        }
    }
    func confirmLogin() async {
        contextDidChange()
        guard !isBusy, let context, let binding else { return }
        let generation = self.generation; phase = .checking; clearFeedback()
        do {
            let access = try await operations.access()
            guard stillCurrent(context, generation: generation) else { return }
            let status = try await access.status(binding)
            guard stillCurrent(context, generation: generation) else { return }
            checkedAt = Date()
            switch status {
            case .matched:
                if binding.choice == .defaultLogin { restoreBlockedFor.remove(context.profile) }
                if binding.choice == .defaultLogin {
                    await backupDefaultLogin(context, generation: generation)
                    guard stillCurrent(context, generation: generation) else { return }
                }
                phase = .matched; localRecord = .sameAccount(binding.choice)
                operations.didVerifyLogin(context, binding)
            case .notLoggedIn:
                phase = .waitingForLogin
                detail = "Claude Code 尚未确认登录完成。请在浏览器和终端完成授权后再核对。"
            case .different: phase = .mismatched; localRecord = .differentAccount
            case .unconfirmed: phase = .unconfirmed
            }
        } catch {
            guard stillCurrent(context, generation: generation) else { return }
            recordFailure(error)
        }
    }
    func returnToAuthorizationTerminal() {
        contextDidChange()
        guard phase == .waitingForLogin, binding != nil else { return }
        if !operations.focusAuthorizationTerminal() {
            detail = "未能切回授权终端。如果已关闭，请从终端选项重新开始。"
        }
    }

    func resetChoice() {
        guard !isBusy else { return }
        generation += 1; phase = .choosing; clearFeedback()
    }
    func defaultLoginDidChange() {
        refreshLocalRecord()
        defaultLoginAvailable = false
        guard choice == .defaultLogin else { return }
        if phase == .waitingForLogin { checkedAt = nil; return }
        generation += 1; phase = .unconfirmed; checkedAt = nil; clearFeedback()
    }
}
