import Foundation
import Darwin

public final class LocalShell: @unchecked Sendable {
    private var childPID: pid_t = -1
    private var masterFD: Int32 = -1
    private var readTask: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?
    public private(set) var isRunning = false

    public let outputStream: AsyncStream<Data>

    public var currentDirectory: String? {
        guard childPID > 0 else { return nil }
        let viSize = 152
        let pathSize = 1024
        let bufSize = (viSize + pathSize) * 2
        var buffer = [CChar](repeating: 0, count: bufSize)
        let sz = proc_pidinfo(childPID, 9, 0, &buffer, Int32(bufSize))
        guard sz >= bufSize else { return nil }
        let path = buffer[viSize...].withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
        guard !path.isEmpty, path != "/" else { return nil }
        return path
    }

    public init() {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        self.outputStream = stream
        self.continuation = cont
    }

    public func start(shell: String = "/bin/zsh", rows: Int32 = 24, cols: Int32 = 80,
                      cwd: String? = nil, environment: [String: String] = [:]) throws {
        var winSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0

        childPID = forkpty(&master, nil, nil, &winSize)
        guard childPID >= 0 else {
            throw LocalShellError.ptyFailed(String(cString: strerror(errno)))
        }
        masterFD = master

        if childPID == 0 {
            setsid()
            ioctl(STDIN_FILENO, TIOCSCTTY, 0)
            fchmod(STDIN_FILENO, 0620)
            setenv("TERM", "xterm-256color", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)
            setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)

            for (key, value) in environment {
                setenv(key, value, 1)
            }

            if let dir = cwd {
                chdir(dir)
            }

            let argI = strdup("-i")
            let argNoPromptSP = strdup("-o")
            let argNoPromptSPVal = strdup("nopromptsp")
            let shellC = strdup(shell)
            var cargs: [UnsafeMutablePointer<CChar>?] = [shellC, argI, argNoPromptSP, argNoPromptSPVal, nil]
            execv(shell, &cargs)
            _exit(127)
        }

        isRunning = true
        startReading()
    }

    public func write(_ string: String) {
        guard let data = string.data(using: .utf8), masterFD >= 0 else { return }
        data.withUnsafeBytes { _ = Darwin.write(masterFD, $0.baseAddress, data.count) }
    }

    public func resize(rows: Int32, cols: Int32) {
        guard isRunning, masterFD >= 0, rows > 0, cols > 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
    }

    public func terminate() {
        isRunning = false
        readTask?.cancel()
        let pid = childPID; let fd = masterFD; let cont = continuation
        childPID = -1; masterFD = -1; continuation = nil
        DispatchQueue.global().async {
            if pid > 0 { kill(pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0) }
            if fd >= 0 { close(fd) }
            cont?.finish()
        }
    }

    private func startReading() {
        let fd = masterFD
        guard let cont = continuation else { return }
        readTask = Task.detached(priority: .background) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n > 0 { cont.yield(Data(buffer[0..<n])) }
                else if n == 0 { break }
                else if errno == EAGAIN || errno == EINTR { continue }
                else { break }
            }
            cont.finish()
        }
    }
}

public enum LocalShellError: Error, LocalizedError {
    case ptyFailed(String)
    public var errorDescription: String? {
        switch self { case .ptyFailed(let m): return "PTY failed: \(m)" }
    }
}
