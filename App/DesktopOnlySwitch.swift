import Foundation
import SwitcherCore

struct DesktopOnlySwitchOffer: Equatable {
    let source: String
    let target: String
    let reason: String
}

@MainActor extension Store {
    /// An explicit exception, never an automatic fallback from a linked switch.
    /// This path does not construct a CLI storage adapter or mutate CLI login/backups.
    func confirmDesktopOnlySwitch() async {
        guard busy == nil, !refreshing, let offer = desktopOnlyOffer else { return }
        desktopOnlyOffer = nil
        banner = nil; busy = "检查网络与桌面档案…"
        defer { busy = nil }
        if isDemo {
            let gate = await protection.preflight()
            guard gate.allowed else { banner = gate.message; return }
            guard current == offer.source else { banner = "当前档案已变化，请重新选择。"; return }
            current = offer.target
            cliStatus = .unverified
            banner = "仅切换了桌面；CLI 登录保持原样，可核验后同步到当前账号。"
            return
        }
        do {
            let targetConfig = parkDir.appendingPathComponent(offer.target).appendingPathComponent("claude_desktop_config.json")
            try await DesktopOnlyFlow.run(transaction: ProfileTransaction(live: liveDir, parked: parkDir, marker: currentFile),
                from: offer.source, to: offer.target, current: confirmedCurrentProfile, subscriptionMode: {
                    let documents: [Data]
                    do { documents = [try Data(contentsOf: targetConfig)] }
                    catch let e as CocoaError where e.code == .fileReadNoSuchFile { documents = [] }
                    return DesktopModeInspector.read(support: support) == .subscription && DesktopModeInspector.classify(documents) == .subscription
                }, quit: { await quitClaude() }, check: { await self.protection.preflight() }, launch: {
                try await launchProtectedDesktop(files: self.protection.files)
                self.protection.refreshStatus()
            })
            reloadList(); await refreshCLI(verify: false)
            banner = "桌面已切换；CLI 登录保持原样。请核验后同步，或在 CLI 完成登录。"
        } catch {
            reloadList(); await refreshCLI(verify: false)
            let outcome = (error as? DesktopOnlyFailure)?.directoryChanged
            let phase: String
            switch outcome {
            case true?: phase = "桌面目录已切换，打开或保护未全部完成，请核对 Claude 状态。"
            case false?: phase = "桌面目录未移动。"
            case nil: phase = "桌面移动未完成，请核对还原结果。"
            }
            banner = "\(phase) \(error.localizedDescription) CLI 登录保持原样。"
        }
    }
}
