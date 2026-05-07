import Foundation

public enum Lime {
    public static let version = "0.0.1"
    /// Runtime UNIX socket. Stays under Application Support (sandboxed, not user-edited).
    public static let socketRelativePath = "Library/Application Support/LimeLight/limelight.sock"
    /// User config. Lives under `~/.config/limelight/` (XDG-style) so it sits
    /// next to other dev-tool configs and is easy to edit, version, and dotfile.
    public static let configRelativePath = ".config/limelight/config.jsonc"
    public static let schemaRelativePath = ".config/limelight/config.schema.json"
}
