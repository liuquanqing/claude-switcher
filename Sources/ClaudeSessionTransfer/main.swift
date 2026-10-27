import Foundation
import SwitcherCore

do {
    let result = try SessionTransferCommand.run(Array(CommandLine.arguments.dropFirst()), requireIdle: {
        let result = try LocalCommand.run("/bin/ps", ["-axww", "-o", "comm="])
        guard result.0 == 0 else { throw SessionTransferFailure("无法确认桌面与切换器退出状态，未操作会话。") }
        try SessionTransferCommand.checkWriters(result.1)
    })
    FileHandle.standardOutput.write(result + Data("\n".utf8))
} catch {
    var output = ["error": error.localizedDescription]
    if let id = (error as? SessionTransferFailure)?.receiptID { output["receiptID"] = id }
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) { FileHandle.standardError.write(data + Data("\n".utf8)) }
    exit(1)
}
