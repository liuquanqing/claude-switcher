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
