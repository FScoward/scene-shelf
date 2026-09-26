import AppKit

@MainActor
public final class SceneShelfPanel: NSPanel {
    public typealias ApplicationActivator = @MainActor @Sendable () -> Void

    private let activateApplication: ApplicationActivator

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(
        contentRect: NSRect,
        activateApplication: @escaping ApplicationActivator = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    public func showShelf() {
        activateApplication()
        makeKeyAndOrderFront(nil)
    }
}
