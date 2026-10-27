import Foundation

public struct ProfileTransaction {
    public let live: URL
    public let parked: URL
    public let marker: URL
    private let move: (URL, URL) throws -> Void
    private let writeMarker: (Data, URL) throws -> Void
    public init(live: URL, parked: URL, marker: URL,
                move: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                writeMarker: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.live = live; self.parked = parked; self.marker = marker
        self.move = move; self.writeMarker = writeMarker
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    public static func currentName(at marker: URL) throws -> String {
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SafetyError("当前档案标记不是普通文件，未修改账号。") }
        let name = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name) else { throw SafetyError("当前档案标记无效，未修改账号。") }
        return name
    }
    /// Undo is used only when the following CLI commit fails. It refuses a changed marker
    /// and retains any data created in a new target instead of deleting that data.
    public func activate(from current: String, to target: String) throws -> (() throws -> Void) {
        let fm = FileManager.default
        let targetWasPresent = fm.fileExists(atPath: parked.appendingPathComponent(target).path)
        let originalMarker = fm.fileExists(atPath: marker.path) ? try Data(contentsOf: marker) : nil
        try switchProfile(from: current, to: target)
        return {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == target else {
                throw SafetyError("桌面档案标记已变化，拒绝覆盖外部切换。")
            }
            try switchProfile(from: target, to: current)
            if !targetWasPresent {
                let created = parked.appendingPathComponent(target)
                if fm.fileExists(atPath: created.path), try fm.contentsOfDirectory(atPath: created.path).isEmpty {
                    try fm.removeItem(at: created)
                }
            }
            if let originalMarker { try originalMarker.write(to: marker, options: .atomic) }
            else if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        }
    }
    public func switchProfile(from current: String, to target: String) throws {
        try validate(from: current, to: target)
        let fm = FileManager.default, source = parked.appendingPathComponent(current), destination = parked.appendingPathComponent(target)
        if fm.fileExists(atPath: source.path) { try fm.removeItem(at: source) }
        let oldMarker = fm.fileExists(atPath: marker.path) ? try Data(contentsOf: marker) : nil
        var sourceMoved = false, targetMoved = false, emptyLiveCreated = false
        do {
            try move(live, source); sourceMoved = true
            if fm.fileExists(atPath: destination.path) {
                try move(destination, live); targetMoved = true
            } else {
                try fm.createDirectory(at: live, withIntermediateDirectories: false); emptyLiveCreated = true
            }
            try writeMarker(Data(target.utf8), marker)
        } catch {
            do {
                if targetMoved { try fm.moveItem(at: live, to: destination) }
                if emptyLiveCreated { try fm.removeItem(at: live) }
                if sourceMoved { try fm.moveItem(at: source, to: live) }
                if let oldMarker { try oldMarker.write(to: marker, options: .atomic) }
                else if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
            } catch {
                throw SafetyError("切换及还原失败；请保留现有 Claude 和 Claude-Profiles 目录，停止操作并检查恢复数据。")
            }
            throw SafetyError("切换失败，已还原原账号：\(error.localizedDescription)")
        }
    }
    /// Read-only validation is also called before any authenticated preparation or quit.
    public func validate(from current: String, to target: String) throws {
        guard Self.validName(current), Self.validName(target), current.caseInsensitiveCompare(target) != .orderedSame else {
            throw SafetyError("账号名称无效或目标与当前账号相同。")
        }
        let fm = FileManager.default, source = parked.appendingPathComponent(current), destination = parked.appendingPathComponent(target)
        for directory in [parked, live, source, destination] {
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                throw SafetyError("账号目录为符号链接，拒绝移动。")
            }
            if fm.fileExists(atPath: directory.path), values?.isDirectory != true {
                throw SafetyError("账号路径不是目录，拒绝移动。")
            }
        }
        guard fm.fileExists(atPath: live.path) else { throw SafetyError("当前 Claude 数据目录缺失，拒绝切换。") }
        if fm.fileExists(atPath: source.path) {
            guard try fm.contentsOfDirectory(atPath: source.path).isEmpty else {
                throw SafetyError("当前账号已有非空存档，拒绝覆盖。")
            }
        }
    }
}
