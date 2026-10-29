import FlaccyCore
import Foundation
import MidgarCore

/// The live channel of a Flaccy Server (docs/server/PROTOCOL.md section 9): a WebSocket that tells this device the moment
/// something changed in its scope, so a sync runs now instead of at the next five-minute round.
///
/// Only `poke` frames matter; presence and command frames are logged at debug level and dropped. A poke is a hint to pull,
/// never data, and a connection that opens pulls once itself. The channel reconnects with a jittered backoff that grows to a
/// minute, and stops for good when the server refuses the token, since the engine's own polling reports why. While the channel
/// is down the engine keeps polling, so nothing depends on it.
actor FlaccyServerLiveChannel {

    typealias Backoff = @Sendable (_ attempt: Int) -> Double

    static let pingInterval: Duration = .seconds(30)
    static let backoff: Backoff = { attempt in
        min(60, pow(2, Double(attempt))) * Double.random(in: 0.75...1.25)
    }

    private let baseURL: URL
    private let token: @Sendable () -> String?
    private let onPoke: @Sendable () -> Void
    private let backoff: Backoff
    private var runner: Task<Void, Never>?

    init(
        baseURL: URL, token: @escaping @Sendable () -> String?, backoff: @escaping Backoff = FlaccyServerLiveChannel.backoff,
        onPoke: @escaping @Sendable () -> Void
    ) {
        self.baseURL = baseURL
        self.token = token
        self.backoff = backoff
        self.onPoke = onPoke
    }

    var isRunning: Bool { runner != nil }

    func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runner?.cancel()
        runner = nil
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            switch await connectOnce() {
            case .refused:
                MidgarLog.notice("The live channel was refused; relying on polling", category: .sync)
                return
            case .opened:
                failures = 0
            case .failed:
                failures += 1
            }
            let pause = backoff(failures)
            MidgarLog.debug("The live channel is down; trying again in \(Int(pause)) s", category: .sync)
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    private enum Outcome {
        case opened
        case failed
        case refused
    }

    private func connectOnce() async -> Outcome {
        guard let token = token() else { return .refused }
        let client = FlaccyServerClient(baseURL: baseURL, token: token)
        guard let socket = try? await client.liveSocket() else { return .failed }
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        do {
            try await Self.ping(socket)
        } catch {
            return Self.isRefusal(socket) ? .refused : .failed
        }
        MidgarLog.info("The live channel is open", category: .sync)
        onPoke()
        return await listen(socket) ? .opened : .failed
    }

    private func listen(_ socket: URLSessionWebSocketTask) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [onPoke] in
                while !Task.isCancelled {
                    guard let message = try? await socket.receive() else { return }
                    Self.handle(message, onPoke: onPoke)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pingInterval)
                    guard (try? await Self.ping(socket)) != nil else { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
        return !Task.isCancelled
    }

    private static func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func isRefusal(_ socket: URLSessionWebSocketTask) -> Bool {
        guard let status = (socket.response as? HTTPURLResponse)?.statusCode else { return false }
        return status == 401 || status == 403
    }

    private struct Frame: Decodable {
        let t: String
        let head: Int64?
    }

    private static func handle(_ message: URLSessionWebSocketTask.Message, onPoke: @Sendable () -> Void) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        if frame.t == "poke" {
            MidgarLog.info("The live channel poked at change \(frame.head ?? 0)", category: .sync)
            onPoke()
        } else {
            MidgarLog.debug("Ignored a \(frame.t) frame on the live channel", category: .sync)
        }
    }
}
