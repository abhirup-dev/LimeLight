import Foundation

public struct ConfigDiagnostic: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable {
        case warning
        case error
    }

    public let severity: Severity
    public let path: String        // e.g. "rules[3].match.windowTitleRegex"
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(severity: Severity, path: String, line: Int? = nil, column: Int? = nil, message: String) {
        self.severity = severity
        self.path = path
        self.line = line
        self.column = column
        self.message = message
    }
}
