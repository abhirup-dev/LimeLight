import Foundation

/// Tracks windows, Spaces, focus, movement, resize, creation, and destruction.
/// Runs on `window-event-queue`; coalesces bursts before redraw scheduling.
public final class WindowTracker {
    public init() {}
    // Implementation lands in focusfx-10.
}
