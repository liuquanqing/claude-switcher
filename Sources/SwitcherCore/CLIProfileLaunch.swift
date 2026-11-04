import Foundation

/// Select the official CLI's directory for this launch only. The command
/// generator never creates, copies, or reads a login or a session directory.
public enum CLIProfileLaunch {
    public static func command(profile: String, home: URL) throws -> String {
        guard home.isFileURL, ProfileTransaction.validName(profile) else {
            throw SafetyError("CLI 档案路径无法确认，未生成启动命令。")
        }
        let root = home.appendingPathComponent(".claude-switcher-cli", isDirectory: true)
        let directory = root.appendingPathComponent(profile, isDirectory: true)
        for path in [root, directory] {
            do {
                let v = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v.isDirectory == true, v.isSymbolicLink != true else {
                    throw SafetyError("CLI 档案目录不可用或为符号链接，未生成启动命令。")
                }
            } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
                // Claude Code will create the folder when the user first runs it.
            }
        }
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "CLAUDE_CONFIG_DIR=\(quoted) claude"
    }
}
