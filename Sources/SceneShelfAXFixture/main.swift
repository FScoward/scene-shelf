import AppKit

@MainActor
final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var secondaryWindow: NSWindow?
    private var duplicateMainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let main = makeWindow(
            identifier: "main",
            title: "Scene Shelf AX Fixture - Main",
            origin: NSPoint(x: 180, y: 620),
            showsControls: true
        )
        let secondary = makeWindow(
            identifier: "secondary",
            title: "Scene Shelf AX Fixture - Secondary",
            origin: NSPoint(x: 600, y: 620),
            showsControls: false
        )
        secondaryWindow = secondary
        windows = [main, secondary]
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    private func makeWindow(
        identifier: String,
        title: String,
        origin: NSPoint,
        showsControls: Bool
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: 360, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: title)
        label.alignment = .center
        label.font = .systemFont(ofSize: 18, weight: .medium)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(label)

        if showsControls {
            let duplicateButton = NSButton(
                title: "同じMainを複製 / 閉じる",
                target: self,
                action: #selector(toggleDuplicateMain)
            )
            duplicateButton.setAccessibilityLabel("同じtitleとidentifierのMainを複製または閉じる")
            duplicateButton.setAccessibilityIdentifier("fixture-toggle-duplicate-main")
            content.addArrangedSubview(duplicateButton)

            let secondaryButton = NSButton(
                title: "Secondaryを閉じる / 再表示",
                target: self,
                action: #selector(toggleSecondary)
            )
            secondaryButton.setAccessibilityLabel("Secondaryを閉じるまたは再表示")
            secondaryButton.setAccessibilityIdentifier("fixture-toggle-secondary")
            content.addArrangedSubview(secondaryButton)
        }

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])
        window.contentView = container
        return window
    }

    @objc private func toggleDuplicateMain() {
        if let duplicate = duplicateMainWindow {
            duplicate.close()
            windows.removeAll { $0 === duplicate }
            duplicateMainWindow = nil
            return
        }

        let duplicate = makeWindow(
            identifier: "main",
            title: "Scene Shelf AX Fixture - Main",
            origin: NSPoint(x: 980, y: 620),
            showsControls: false
        )
        duplicateMainWindow = duplicate
        windows.append(duplicate)
        duplicate.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleSecondary() {
        guard let secondary = secondaryWindow else { return }
        if secondary.isVisible {
            secondary.close()
        } else {
            secondary.makeKeyAndOrderFront(nil)
        }
    }
}

@main
@MainActor
struct SceneShelfAXFixtureMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
