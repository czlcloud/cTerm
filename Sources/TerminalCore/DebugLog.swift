import Foundation

public func dlog(_ tag: String, _ msg: String) {
    let df = DateFormatter(); df.dateFormat = "mm:ss.SSS"
    let line = "[\(df.string(from: Date())) \(tag)] \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/termdbg.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        try? "".data(using: .utf8)?.write(to: url)
    }
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        try? fh.write(line.data(using: .utf8)!)
        try? fh.close()
    }
}
