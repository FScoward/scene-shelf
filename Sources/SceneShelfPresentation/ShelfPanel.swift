import AppKit

public enum SceneShelfPanelPresentation {
    public static func appearanceName(increaseContrast: Bool) -> NSAppearance.Name {
        increaseContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
    }
}

@MainActor
public final class SceneShelfPanel: NSPanel {
    public typealias ApplicationActivator = @MainActor @Sendable () -> Void

    private let activateApplication: ApplicationActivator
    public private(set) var configuredAppearanceName: NSAppearance.Name

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(
        contentRect: NSRect,
        increaseContrast: Bool? = nil,
        activateApplication: @escaping ApplicationActivator = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
        self.configuredAppearanceName = SceneShelfPanelPresentation.appearanceName(
            increaseContrast: increaseContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        applyAppearance(
            increaseContrast: increaseContrast
                ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    public func showShelf() {
        applyAppearance(
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        activateApplication()
        makeKeyAndOrderFront(nil)
    }

    private func applyAppearance(increaseContrast: Bool) {
        configuredAppearanceName = SceneShelfPanelPresentation.appearanceName(
            increaseContrast: increaseContrast
        )
        appearance = NSAppearance(named: .darkAqua)
    }
}
