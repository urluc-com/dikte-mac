import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "dikte.log")
    private static var fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dikte", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dikte.log")
    }()

    /// Sıradaki satırlar diske yazılana kadar bekler (çıkıştan hemen önce).
    static func flush() {
        queue.sync {}
    }

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
            #if DEBUG
            print(line, terminator: "")
            #endif
        }
    }
}
