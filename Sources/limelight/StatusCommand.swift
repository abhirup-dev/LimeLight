import Foundation
import LimeCore

enum StatusCommand {
    static func run(_ args: [String]) {
        let json = args.contains("--json")
        let resp = CLIClient.requireOK(CLIClient.call("status"))

        guard let result = resp.result else {
            print(json ? "{}" : "(no result)")
            return
        }

        let encoder = IPCCoding.makeEncoder()
        if json {
            encoder.outputFormatting = [.sortedKeys]
        } else {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        do {
            let data = try encoder.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("limelight: failed to render status: \(error)\n".utf8))
            exit(1)
        }
    }
}
