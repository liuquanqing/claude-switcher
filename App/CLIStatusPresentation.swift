import Foundation
import SwitcherCore

/// Last completed observation of the default saved login; never a launch or sync authorization.
struct CLIStatusPresentation: Equatable, Sendable {
    var status: CLILoginStatus = .unverified
    var profile: String?
    var email: String?
    var detail: String?
    var standaloneVerified = false
}

/// Only interprets the official CLI's local report. No token, Keychain or network
/// dependency belongs here; this result cannot authorize a linked switch.
extension CLIStatusPresentation {
    static func localReport(_ report: CLIReportedStatus, expectedDirectory: URL,
                            configuration: AuthenticationConfiguration) -> (presentation: Self, defaultSubscription: Bool) {
        var result = Self()
        guard !configuration.malformed else {
            result.detail = "默认 CLI 配置无法读取。"; return (result, false)
        }
        guard report.usesConfigurationDirectory(expectedDirectory), !configuration.customDirectory else {
            result.status = .unsupportedStorage; result.detail = "CLI 使用其他配置目录。"; return (result, false)
        }
        guard report.loggedIn else {
            result.status = .needsLogin; result.detail = "CLI 报告默认配置未登录。"; return (result, false)
        }
        guard report.authMethod == "claude.ai", !configuration.otherAuthentication else {
            result.status = .otherAuthentication; result.detail = "CLI 使用 API 或其他认证来源。"; return (result, false)
        }
        result.status = .reported; result.email = report.identity.email
        result.detail = "官方 CLI 报告已登录；尚未验证在线有效性。"
        return (result, true)
    }
}
