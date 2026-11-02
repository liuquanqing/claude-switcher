import Foundation

/// A parent process's silent Keychain query does not constrain a child CLI's
/// authorization UI. Background execution therefore requires an explicit
/// noninteractive capability, not merely a prior "always allow" observation.
public enum CLIRenewalInteractionPolicy {
    public static func mayStartNative(userInitiated: Bool, backgroundEnabled: Bool,
                                      guaranteesNoSystemPrompt: Bool) -> Bool {
        userInitiated || backgroundEnabled && guaranteesNoSystemPrompt
    }
}
