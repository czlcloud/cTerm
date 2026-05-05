import Foundation

/// Simple file-backed logger for SFTP operations.
/// Writes to /tmp/terminalapp-sftp.log so we can tail it.
enum SFTPLogger {
    private static let logPath = "/tmp/terminalapp-sftp.log"
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ tag: String, _ msg: String) {
        let line = "[\(tag)] \(df.string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        }
    }
}
