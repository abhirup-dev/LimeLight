import Foundation

/// Pure command dispatcher. Holds a name-keyed table of synchronous handlers.
/// Long-running commands should not register here; in v0 every command we ship
/// (`status`, `reload`, …) returns from cached state and is fast.
public final class IPCRouter: @unchecked Sendable {
    public typealias Handler = (IPCRequest) -> IPCResponse

    private var handlers: [String: Handler] = [:]
    private let queue = DispatchQueue(label: "dev.focusfx.ipc.router", attributes: .concurrent)

    public init() {}

    public func register(_ command: String, handler: @escaping Handler) {
        queue.async(flags: .barrier) { self.handlers[command] = handler }
    }

    public func dispatch(_ request: IPCRequest) -> IPCResponse {
        let handler = queue.sync { handlers[request.command] }
        guard let handler else {
            return IPCResponse.failure(
                id: request.id,
                code: "unknown_command",
                message: "Unknown command '\(request.command)'"
            )
        }
        return handler(request)
    }
}
