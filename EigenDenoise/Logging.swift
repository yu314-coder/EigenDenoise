//
//  Logging.swift
//  Tiny console logger — tagged, timestamped, single switch to disable.
//  Output goes to stderr so it shows up in Xcode's console pane.
//

import Foundation

public enum EDLog {

    /// Master switch. Set to `false` to silence (without recompiling all sites).
    public nonisolated(unsafe) static var enabled: Bool = true

    /// The categories we care about. Edit `silenced` to mute one.
    public enum Cat: String, Sendable {
        case app, ui, model, folder, denoise, bridge, py
        case math, svd, eigh, gram, metrics, sim, rmt
    }

    /// Categories temporarily silenced (none by default).
    public nonisolated(unsafe) static var silenced: Set<Cat> = []

    @inlinable
    public nonisolated static func log(_ cat: Cat,
                            _ msg: @autoclosure () -> String,
                            file: StaticString = #file,
                            line: UInt = #line,
                            function: StaticString = #function) {
        guard enabled, !silenced.contains(cat) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        let f = ("\(file)" as NSString).lastPathComponent
        let text = msg()
        FileHandle.standardError.write(Data(
            "[\(stamp)] [ED:\(cat.rawValue)] \(f):\(line) \(function) — \(text)\n".utf8))
    }

    @inlinable
    public nonisolated static func warn(_ cat: Cat, _ msg: @autoclosure () -> String,
                             file: StaticString = #file, line: UInt = #line,
                             function: StaticString = #function) {
        log(cat, "⚠️ \(msg())", file: file, line: line, function: function)
    }

    @inlinable
    public nonisolated static func error(_ cat: Cat, _ msg: @autoclosure () -> String,
                              file: StaticString = #file, line: UInt = #line,
                              function: StaticString = #function) {
        log(cat, "❌ \(msg())", file: file, line: line, function: function)
    }
}
