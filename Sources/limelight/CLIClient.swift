import Foundation
import LimeCore

/// Thin wrapper around `IPCClient` that maps IPC-layer errors to CLI exit codes
/// and prints diagnostics to stderr.
enum CLIClient {
    static func call(
        _ command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval = 1.5
    ) -> IPCResponse {
        let client = IPCClient(socketPath: Lime.resolvedSocketPath, defaultTimeout: timeout)
        do {
            return try client.call(IPCRequest(command: command, args: args), timeout: timeout)
        } catch let err as IPCClient.CallError {
            switch err {
            case .connectFailed:
                FileHandle.standardError.write(Data(
                    "limelight: daemon is not running (no socket at \(Lime.resolvedSocketPath)).\nStart it with: limelight daemon open\n".utf8
                ))
                exit(3)
            case .timeout:
                FileHandle.standardError.write(Data("limelight: daemon timed out (>\(timeout)s)\n".utf8))
                exit(5)
            default:
                FileHandle.standardError.write(Data("limelight: ipc error: \(err)\n".utf8))
                exit(3)
            }
        } catch {
            FileHandle.standardError.write(Data("limelight: \(error)\n".utf8))
            exit(3)
        }
    }

    static func requireOK(_ response: IPCResponse) -> IPCResponse {
        if !response.ok, let e = response.error {
            FileHandle.standardError.write(Data("limelight: \(e.code): \(e.message)\n".utf8))
            exit(4)
        }
        return response
    }
}
