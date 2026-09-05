import Foundation

/// Свой файл лога рядом с состоянием приложения. В системном журнале
/// сообщения тонут в шуме, а искать их там при разборе проблемы — мучение.
enum Log {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/whisper-local/dictate.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
