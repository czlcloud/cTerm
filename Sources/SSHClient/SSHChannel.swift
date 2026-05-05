import Foundation
import CLibssh2

// MARK: - SSHChannel
/// Wraps a libssh2 `LIBSSH2_CHANNEL` and provides an `AsyncStream<Data>`
/// for reading output.  Intended use:
///
/// ```swift
/// let channel = try SSHChannel(connection: conn)
/// try channel.openShell(rows: 24, cols: 80)
/// for await data in channel.outputStream {
///     // process incoming data
/// }
/// ```
///
/// - Note: This class is **not** `Sendable` because it holds a raw channel
///   pointer.  Access it from a single actor / task in practice.
public final class SSHChannel: @unchecked Sendable {

    // MARK: - Public properties

    /// Async stream of data received from the remote side.
    public let outputStream: AsyncStream<Data>

    /// The exit status of the remote command, or `nil` if the channel is still open.
    public private(set) var exitStatus: Int?

    // MARK: - Private state

    private let connection: SSHConnection
    private let channelPtr: OpaquePointer
    private let continuation: AsyncStream<Data>.Continuation
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    // MARK: - Init

    /// Open a fresh session channel on the given connection.  The caller must
    /// still call `openShell(rows:cols:)` or `exec(_:)` before the channel
    /// is usable.
    public init(connection: SSHConnection) throws {
        self.connection = connection
        self.channelPtr = try connection.openChannel()

        let (stream, cont) = AsyncStream<Data>.makeStream()
        self.outputStream = stream
        self.continuation = cont
    }

    deinit {
        closeInternal()
    }

    // MARK: - Shell / Exec

    /// Request a PTY and start an interactive shell.
    public func openShell(rows: Int32, cols: Int32) throws {
        try connection.requestPTY(channel: channelPtr, rows: rows, cols: cols)
        try connection.startShell(channel: channelPtr)
        startReadLoop()
    }

    /// Execute a single command (no PTY allocated).
    public func exec(_ command: String) throws {
        try connection.exec(channel: channelPtr, command: command)
        startReadLoop()
    }

    // MARK: - Write

    /// Write raw `Data` to the channel.  Handles partial writes and EAGAIN
    /// by looping until all bytes have been sent.
    public func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let segment: Data
            if offset == 0 {
                segment = data
            } else {
                segment = data.subdata(in: offset..<data.count)
            }
            let written = try connection.write(channel: channelPtr, data: segment)
            if written == 0 {
                // EAGAIN; block briefly before retrying.
                usleep(10_000) // 10 ms
            } else {
                offset += written
            }
        }
    }

    /// Convenience: encode a `String` as UTF-8 and write it.
    public func write(_ string: String) throws {
        guard let data = string.data(using: .utf8) else {
            return // silently skip invalid UTF-8
        }
        try write(data)
    }

    // MARK: - Resize

    /// Inform the remote side that the local terminal dimensions changed.
    public func resize(rows: Int32, cols: Int32) {
        connection.resizePTY(channel: channelPtr, rows: rows, cols: cols)
    }

    // MARK: - Close

    /// Close the channel and finish the async stream.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        readTask = nil
        // Capture exit status before freeing the channel pointer.
        if exitStatus == nil {
            exitStatus = connection.getExitStatus(channel: channelPtr)
        }
        connection.closeChannel(channelPtr)
        continuation.finish()
    }

    // MARK: - Read loop (private)

    /// Spawn a `Task` that continuously reads from the channel and feeds
    /// the `AsyncStream`.
    private func startReadLoop() {
        guard readTask == nil else { return }

        readTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.continuation.finish()
            }

            while !Task.isCancelled && !self.isClosed {
                do {
                    if let data = try self.connection.read(channel: self.channelPtr) {
                        if data.isEmpty {
                            // EAGAIN – no data available yet; sleep before retry.
                            try await Task.sleep(nanoseconds: 10_000_000)
                        } else {
                            self.continuation.yield(data)
                        }
                    } else {
                        // nil means EOF (channel closed by remote).
                        // Capture exit status before the channel is freed.
                        self.exitStatus = self.connection.getExitStatus(channel: self.channelPtr)
                        break
                    }
                } catch {
                    // If the task was cancelled mid-sleep, just exit.
                    if Task.isCancelled { break }
                    // Treat any read error as terminal for this channel.
                    break
                }
            }
        }
    }

    /// Internal teardown used by `deinit` — guards against double-close
    /// and avoids touching the session if the connection is already gone.
    private func closeInternal() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        readTask = nil
        // Only free the channel if the connection might still be alive.
        // If the connection is gone the session pointer is already invalid.
        if connection.status != .disconnected, !connection.isFailed {
            if exitStatus == nil {
                exitStatus = connection.getExitStatus(channel: channelPtr)
            }
            connection.closeChannel(channelPtr)
        }
        continuation.finish()
    }
}
