import Foundation
import CLibssh2
import Darwin

// MARK: - SFTPEntry
public struct SFTPEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let permissions: UInt
    public let modifiedAt: Date?

    public init(name: String, path: String, isDirectory: Bool, size: Int64,
                permissions: UInt, modifiedAt: Date? = nil) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.size = size; self.permissions = permissions; self.modifiedAt = modifiedAt
    }
}

// MARK: - SFTPClient
public final class SFTPClient: @unchecked Sendable {

    private let connection: SSHConnection
    private var sftpSession: OpaquePointer?

    public init(connection: SSHConnection) { self.connection = connection }

    deinit { disconnect() }

    // MARK: - Blocking socket helper

    // MARK: - Session management

    /// If `blocking` is true, switches the socket to blocking mode for the init.
    /// Use `true` for dedicated SFTP connections (Quick Connect), `false` when
    /// sharing the session with an active terminal (Session dropdown).
    public func connect(blocking: Bool = false) throws {
        guard let session = connection.session else { throw SSHError.notConnected }

        if blocking {
            connection.setSocketBlocking(true)
            libssh2_session_set_blocking(session, 1)
            libssh2_session_set_timeout(session, 30_000)
            defer {
                libssh2_session_set_timeout(session, 0)
                libssh2_session_set_blocking(session, 0)
                connection.setSocketBlocking(false)
            }
        }

        // EAGAIN retry loop (works for both blocking and non-blocking)
        let eagain = Int32(LIBSSH2_ERROR_EAGAIN_VALUE)
        var attempts = 0
        var s: OpaquePointer?
        while attempts < (blocking ? 30 : 60) {
            s = libssh2_sftp_init(session)
            if s != nil { break }
            let lastErr = libssh2_session_last_errno(session)
            if lastErr == eagain { attempts += 1; usleep(100_000); continue }
            var errPtr: UnsafeMutablePointer<CChar>?
            libssh2_session_last_error(session, &errPtr, nil, 0)
            let detail = errPtr.map { String(cString: $0) } ?? "unknown"
            throw SSHError.sftpError("SFTP init failed (err=\(lastErr): \(detail))")
        }

        guard let s = s else {
            throw SSHError.sftpError("SFTP init timed out after \(attempts) retries")
        }
        sftpSession = s
    }

    public func disconnect() {
        guard let s = sftpSession else { return }
        libssh2_sftp_shutdown(s)
        sftpSession = nil
    }

    // MARK: - Directory listing

    public func listDirectory(_ path: String) throws -> [SFTPEntry] {
        guard let sftp = sftpSession else { throw SSHError.notConnected }
        guard let session = connection.session else { throw SSHError.notConnected }

        let pathLen = UInt32(path.lengthOfBytes(using: .utf8))
        let eagainValue = Int32(LIBSSH2_ERROR_EAGAIN_VALUE)

        // opendir with EAGAIN retry
        var dirHandle: OpaquePointer?
        var openAttempts = 0
        while openAttempts < 60 {
            dirHandle = libssh2_sftp_opendir(sftp, path, pathLen)
            if dirHandle != nil { break }
            if libssh2_session_last_errno(session) == eagainValue {
                openAttempts += 1; usleep(100_000); continue
            }
            try throwLastSFTPError(sftp)
            throw SSHError.sftpError("Failed to open remote directory: \(path)")
        }
        guard let dirHandle = dirHandle else {
            throw SSHError.sftpError("SFTP opendir timed out: \(path)")
        }
        defer { libssh2_sftp_closedir(dirHandle) }

        var entries: [SFTPEntry] = []
        let nameBufferSize = 512
        var buffer = [CChar](repeating: 0, count: nameBufferSize)
        var attrs = LIBSSH2_SFTP_ATTRIBUTES(
            flags: 0, filesize: 0, uid: 0, gid: 0, permissions: 0, atime: 0, mtime: 0
        )

        loop: while true {
            buffer.withUnsafeMutableBytes { raw in memset(raw.baseAddress, 0, raw.count) }
            attrs.flags = 0

            let result = buffer.withUnsafeMutableBufferPointer { buf in
                libssh2_sftp_readdir(dirHandle, buf.baseAddress, nameBufferSize, &attrs)
            }

            switch result {
            case eagainValue: usleep(10_000); continue
            case ..<0:        break loop
            default:          guard result > 0 else { break loop }
            }

            let name = String(cString: buffer)
            guard name != "." && name != ".." else { continue }

            let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"

            let isDir: Bool = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)) != 0
                ? (attrs.permissions & UInt(S_IFMT)) == UInt(S_IFDIR) : false
            let size: Int64 = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE)) != 0
                ? Int64(attrs.filesize) : 0
            let modifiedAt: Date? = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)) != 0
                ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime)) : nil

            entries.append(SFTPEntry(name: name, path: fullPath, isDirectory: isDir,
                                     size: size, permissions: attrs.permissions, modifiedAt: modifiedAt))
        }
        return entries
    }

    // MARK: - File transfers

    public func download(_ remotePath: String, to localURL: URL) throws {
        guard let sftp = sftpSession else { throw SSHError.notConnected }

        let handle = try sftpOpen(sftp, path: remotePath, flags: UInt(LIBSSH2_FXF_READ), mode: 0)
        defer { libssh2_sftp_close(handle) }

        let eagainValue = LIBSSH2_ERROR_EAGAIN_VALUE
        let chunkSize = 32768
        var fileData = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        loop: while true {
            let bytesRead = buffer.withUnsafeMutableBytes { raw in
                libssh2_sftp_read(handle, raw.baseAddress!.assumingMemoryBound(to: Int8.self), chunkSize)
            }
            switch bytesRead {
            case eagainValue: usleep(10_000); continue
            case ..<0: throw SSHError.sftpError("Download read error at offset \(fileData.count)")
            case 0:   break loop
            default:  fileData.append(contentsOf: buffer[0..<Int(bytesRead)])
            }
        }
        try fileData.write(to: localURL, options: .atomic)
    }

    public func upload(localURL: URL, to remotePath: String) throws {
        guard let sftp = sftpSession else { throw SSHError.notConnected }

        let fileData = try Data(contentsOf: localURL)
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let handle = try sftpOpen(sftp, path: remotePath, flags: flags, mode: 0o644)
        defer { libssh2_sftp_close(handle) }

        let eagainValue = LIBSSH2_ERROR_EAGAIN_VALUE
        let chunkSize = 32768
        var offset = 0

        while offset < fileData.count {
            let remaining = fileData.count - offset
            let thisChunk = min(remaining, chunkSize)
            let slice = fileData[offset..<offset + thisChunk]

            let bytesWritten = slice.withUnsafeBytes { raw in
                libssh2_sftp_write(handle, raw.baseAddress!.assumingMemoryBound(to: Int8.self), thisChunk)
            }
            if bytesWritten == eagainValue { usleep(10_000); continue }
            guard bytesWritten > 0 else {
                throw SSHError.sftpError("Upload write returned zero at offset \(offset)")
            }
            offset += Int(bytesWritten)
        }
    }

    // MARK: - File system operations

    public func remove(_ path: String) throws {
        guard let sftp = sftpSession else { throw SSHError.notConnected }
        let pathLen = UInt32(path.lengthOfBytes(using: .utf8))
        let result = libssh2_sftp_unlink(sftp, path, pathLen)
        guard result == 0 else {
            try throwLastSFTPError(sftp)
            throw SSHError.sftpError("Failed to remove: \(path) (err=\(result))")
        }
    }

    public func mkdir(_ path: String) throws {
        guard let sftp = sftpSession else { throw SSHError.notConnected }
        let pathLen = UInt32(path.lengthOfBytes(using: .utf8))
        let result = libssh2_sftp_mkdir(sftp, path, pathLen, 0o755)
        guard result == 0 else {
            try throwLastSFTPError(sftp)
            throw SSHError.sftpError("Failed to create directory: \(path) (err=\(result))")
        }
    }

    // MARK: - Private helpers

    private func sftpOpen(_ sftp: OpaquePointer, path: String, flags: UInt, mode: Int) throws -> OpaquePointer {
        guard let session = connection.session else { throw SSHError.notConnected }

        // Blocking mode for file open — faster than EAGAIN retry
        connection.setSocketBlocking(true)
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 30_000)
        defer {
            libssh2_session_set_timeout(session, 0)
            libssh2_session_set_blocking(session, 0)
            connection.setSocketBlocking(false)
        }

        let pathLen = UInt32(path.lengthOfBytes(using: .utf8))
        guard let h = libssh2_sftp_open(sftp, path, pathLen, flags, mode) else {
            try throwLastSFTPError(sftp)
            throw SSHError.sftpError("Failed to open: \(path)")
        }
        return h
    }

    private func throwLastSFTPError(_ sftp: OpaquePointer) throws {
        guard let session = connection.session else { return }
        var errPtr: UnsafeMutablePointer<CChar>?
        let errno = libssh2_session_last_error(session, &errPtr, nil, 0)
        if let errPtr = errPtr {
            let msg = String(cString: errPtr)
            throw SSHError.sftpError("SFTP error \(errno): \(msg)")
        }
    }
}
