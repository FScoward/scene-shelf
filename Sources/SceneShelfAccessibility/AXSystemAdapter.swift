import AppKit
import ApplicationServices
import Foundation

/// The only live AX boundary in Scene Shelf P0-2.
///
/// `AXUIElement` and `NSRunningApplication` values are created, used, and
/// discarded inside one actor call. No raw reference is stored or returned.
public actor AXSystemAdapter: AXWindowAdapter {
    private enum FixtureApplicationResolution {
        case unique(NSRunningApplication)
        case unavailable
        case ambiguous
    }

    private struct ResolvedRawWindow {
        let element: AXUIElement
        let snapshot: AXWindowSnapshot
    }

    public init() {}

    public func permissionStatus() -> PermissionStatus {
        if AXIsProcessTrusted() {
            return PermissionStatus(
                state: .granted,
                reason: "アクセシビリティ権限が許可されています",
                allowsAXInspection: true
            )
        }
        return PermissionStatus(
            state: .denied,
            reason: "アクセシビリティ権限が必要です。設定を開いてScene Shelfを許可してください",
            allowsAXInspection: false
        )
    }

    public func fixtureWindows() -> [AXWindowSnapshot] {
        fixtureWindowResult().windows
    }

    public func fixtureWindowResult() -> AXWindowDiscoveryResult {
        guard AXIsProcessTrusted() else {
            return .failure(.permissionDenied)
        }

        let application: NSRunningApplication
        switch resolveFixtureApplication() {
        case .unavailable:
            return .failure(.applicationUnavailable)
        case .ambiguous:
            return .failure(.ambiguousMatch)
        case let .unique(value):
            application = value
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let values = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return .failure(.applicationUnavailable)
        }

        let windows = values.compactMap {
            snapshot(of: $0, processID: application.processIdentifier)
        }
        return windows.isEmpty ? .failure(.windowMissing) : .success(windows)
    }

    public func windowResult(for target: AXWindowIdentity) -> AXWindowDiscoveryResult {
        if target.bundleIdentifier == SceneShelfAXContract.fixtureBundleIdentifier {
            return fixtureWindowResult()
        }
        guard AXIsProcessTrusted() else {
            return .failure(.permissionDenied)
        }
        guard !target.bundleIdentifier.isEmpty,
              target.bundleIdentifier != SceneShelfAXContract.sceneShelfBundleIdentifier else {
            return .failure(.bundleNotAllowed)
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: target.bundleIdentifier
        )
        guard !applications.isEmpty else {
            return .failure(.applicationUnavailable)
        }
        guard let application = applications.first(where: {
            $0.processIdentifier == target.processID
        }) else {
            return .failure(.pidReused)
        }
        guard application.activationPolicy != .prohibited else {
            return .failure(.bundleNotAllowed)
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let values = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return .failure(.applicationUnavailable)
        }
        let windows = values.compactMap {
            snapshot(
                of: $0,
                processID: application.processIdentifier,
                bundleIdentifier: target.bundleIdentifier
            )
        }
        return windows.isEmpty ? .failure(.windowMissing) : .success(windows)
    }

    /// Enumerates running applications and their accessible windows without
    /// issuing any AX write. The normalizer removes Scene Shelf itself,
    /// background-only apps, and observations without a usable bundle ID.
    public func applicationCatalog() -> AXApplicationCatalogResult {
        guard AXIsProcessTrusted() else {
            return .failure(.permissionDenied)
        }

        let processes: [AXApplicationProcessSnapshot] = NSWorkspace.shared.runningApplications.compactMap {
            application in
            // Reject observations that can never become a user-visible catalog
            // candidate before creating an AX application element. This keeps
            // the live read boundary small while the pure normalizer remains
            // the source of truth for fixture and value-level filtering.
            guard let bundleIdentifier = application.bundleIdentifier,
                  !bundleIdentifier.isEmpty,
                  bundleIdentifier != SceneShelfAXContract.sceneShelfBundleIdentifier,
                  application.activationPolicy != .prohibited else {
                return nil
            }

            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let rawWindows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let windows: [AXWindowSnapshot] = rawWindows.compactMap { element in
                snapshot(
                    of: element,
                    processID: application.processIdentifier,
                    bundleIdentifier: bundleIdentifier
                )
            }
            return AXApplicationProcessSnapshot(
                appName: application.localizedName ?? application.bundleIdentifier ?? "名称不明",
                bundleIdentifier: bundleIdentifier,
                processID: application.processIdentifier,
                windows: windows,
                hasUserInterface: true,
                isBackgroundOnly: false
            )
        }
        return .success(AXApplicationCatalogNormalizer.normalize(processes))
    }

    public func perform(_ request: AXOperationRequest) -> AXOperationReport {
        guard AXIsProcessTrusted() else {
            return AXOperationReport(
                target: request.target,
                requestedOperations: request.operations,
                failureReason: .permissionDenied
            )
        }

        if let scope = request.authorizationScope {
            let authorization = AXAuthorizationPolicy.authorize(
                target: request.target,
                scope: scope
            )
            guard authorization == .authorized else {
                return AXOperationReport(
                    target: request.target,
                    requestedOperations: request.operations,
                    failureReason: authorization.failureReason
                )
            }
            if request.target.bundleIdentifier != SceneShelfAXContract.fixtureBundleIdentifier {
                return performGeneric(request)
            }
        }
        return performFixture(request)
    }

    private func performFixture(_ request: AXOperationRequest) -> AXOperationReport {
        let requested = request.operations
        func report(
            applied: [AXOperation] = [],
            writes: Int = 0,
            failure: FailureReason? = nil
        ) -> AXOperationReport {
            AXOperationReport(
                target: request.target,
                requestedOperations: requested,
                appliedOperations: applied,
                writesPerformed: writes,
                failureReason: failure
            )
        }

        guard request.target.bundleIdentifier == SceneShelfAXContract.fixtureBundleIdentifier else {
            return report(failure: .bundleNotAllowed)
        }
        guard !requested.isEmpty else {
            return report()
        }
        switch resolveFixtureApplication() {
        case .unavailable:
            return report(failure: .applicationUnavailable)
        case .ambiguous:
            return report(failure: .ambiguousMatch)
        case .unique:
            break
        }

        var applied: [AXOperation] = []
        var writes = 0
        for operation in requested {
            guard let resolved = resolveRawWindow(target: request.target) else {
                return report(applied: applied, writes: writes, failure: .applicationUnavailable)
            }

            switch resolved {
            case let .failure(reason):
                return report(applied: applied, writes: writes, failure: reason)
            case let .success(rawWindow):
                guard apply(operation, to: rawWindow.element, frame: request.frame) else {
                    return report(applied: applied, writes: writes, failure: .operationFailed)
                }
                writes += 1
                applied.append(operation)
            }
        }
        return report(applied: applied, writes: writes)
    }

    private func performGeneric(_ request: AXOperationRequest) -> AXOperationReport {
        let requested = request.operations
        func report(
            applied: [AXOperation] = [],
            writes: Int = 0,
            failure: FailureReason? = nil
        ) -> AXOperationReport {
            AXOperationReport(
                target: request.target,
                requestedOperations: requested,
                appliedOperations: applied,
                writesPerformed: writes,
                failureReason: failure
            )
        }

        guard !requested.isEmpty else {
            return report()
        }

        var applied: [AXOperation] = []
        var writes = 0
        for operation in requested {
            switch resolveGenericRawWindow(target: request.target) {
            case let .failure(reason):
                return report(applied: applied, writes: writes, failure: reason)
            case let .success(rawWindow):
                guard apply(operation, to: rawWindow.element, frame: request.frame) else {
                    return report(
                        applied: applied,
                        writes: writes,
                        failure: .operationFailed
                    )
                }
                writes += 1
                applied.append(operation)
            }
        }
        return report(applied: applied, writes: writes)
    }

    private func resolveFixtureApplication() -> FixtureApplicationResolution {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: SceneShelfAXContract.fixtureBundleIdentifier
        )
        switch applications.count {
        case 0:
            return .unavailable
        case 1:
            return .unique(applications[0])
        default:
            // Never choose `.first`: two same-bundle processes make the PID
            // identity ambiguous and all inspection/write operations stop.
            return .ambiguous
        }
    }

    private func resolveRawWindow(
        target: AXWindowIdentity
    ) -> Result<ResolvedRawWindow, FailureReason>? {
        let application: NSRunningApplication
        switch resolveFixtureApplication() {
        case .unavailable:
            return nil
        case .ambiguous:
            return .failure(.ambiguousMatch)
        case let .unique(value):
            application = value
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let values = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return .failure(.windowMissing)
        }

        let rawWindows = values.compactMap { element -> ResolvedRawWindow? in
            guard let snapshot = snapshot(of: element, processID: application.processIdentifier) else {
                return nil
            }
            return ResolvedRawWindow(element: element, snapshot: snapshot)
        }
        let resolution = AXSafetyPolicy.resolve(
            target: target,
            candidates: rawWindows.map { $0.snapshot }
        )
        switch resolution {
        case let .unique(snapshot):
            guard let match = rawWindows.first(where: { $0.snapshot == snapshot }) else {
                return .failure(.windowMissing)
            }
            return .success(match)
        case .missing:
            return .failure(.windowMissing)
        case .ambiguous:
            return .failure(.ambiguousMatch)
        case .windowChanged:
            return .failure(.windowChanged)
        case .pidReused:
            return .failure(.pidReused)
        case .bundleNotAllowed:
            return .failure(.bundleNotAllowed)
        }
    }

    private func resolveGenericRawWindow(
        target: AXWindowIdentity
    ) -> Result<ResolvedRawWindow, FailureReason> {
        guard !target.bundleIdentifier.isEmpty,
              target.bundleIdentifier != SceneShelfAXContract.sceneShelfBundleIdentifier else {
            return .failure(.bundleNotAllowed)
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: target.bundleIdentifier
        )
        guard !applications.isEmpty else {
            return .failure(.applicationUnavailable)
        }
        guard let application = applications.first(where: {
            $0.processIdentifier == target.processID
        }) else {
            return .failure(.pidReused)
        }
        guard application.activationPolicy != .prohibited else {
            return .failure(.bundleNotAllowed)
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let values = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return .failure(.applicationUnavailable)
        }
        let rawWindows = values.compactMap { element -> ResolvedRawWindow? in
            guard let snapshot = snapshot(
                of: element,
                processID: application.processIdentifier,
                bundleIdentifier: target.bundleIdentifier
            ) else {
                return nil
            }
            return ResolvedRawWindow(element: element, snapshot: snapshot)
        }
        let resolution = AXApplicationSafetyPolicy.resolve(
            target: target,
            candidates: rawWindows.map(\.snapshot)
        )
        switch resolution {
        case let .unique(snapshot):
            guard let match = rawWindows.first(where: { $0.snapshot == snapshot }) else {
                return .failure(.windowMissing)
            }
            return .success(match)
        case .missing:
            return .failure(.windowMissing)
        case .ambiguous:
            return .failure(.ambiguousMatch)
        case .windowChanged:
            return .failure(.windowChanged)
        case .pidReused:
            return .failure(.pidReused)
        case .bundleNotAllowed:
            return .failure(.bundleNotAllowed)
        }
    }

    private func snapshot(
        of element: AXUIElement,
        processID: pid_t,
        bundleIdentifier: String = SceneShelfAXContract.fixtureBundleIdentifier
    ) -> AXWindowSnapshot? {
        guard let title = copyAttribute(element, kAXTitleAttribute) as? String else {
            return nil
        }
        let identifier = copyAttribute(element, kAXIdentifierAttribute) as? String
        let frame = readFrame(from: element)
        let minimized = (copyAttribute(element, kAXMinimizedAttribute) as? Bool) ?? false
        let identity = AXWindowIdentity(
            bundleIdentifier: bundleIdentifier,
            processID: processID,
            title: title,
            identifier: identifier
        )
        return AXWindowSnapshot(identity: identity, frame: frame, isMinimized: minimized)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func readFrame(from element: AXUIElement) -> AXFrame? {
        guard let positionReference = copyAttribute(element, kAXPositionAttribute),
              let sizeReference = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionReference) == AXValueGetTypeID(),
              CFGetTypeID(sizeReference) == AXValueGetTypeID() else {
            return nil
        }
        let position = positionReference as! AXValue
        let size = sizeReference as! AXValue
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &cgSize) else {
            return nil
        }
        return AXFrame(
            x: point.x,
            y: point.y,
            width: cgSize.width,
            height: cgSize.height
        )
    }

    private func apply(
        _ operation: AXOperation,
        to element: AXUIElement,
        frame: AXFrame?
    ) -> Bool {
        switch operation {
        case .unminimize:
            return AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            ) == .success
        case .move:
            guard let frame else { return false }
            var point = CGPoint(x: frame.x, y: frame.y)
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
        case .resize:
            guard let frame else { return false }
            var size = CGSize(width: frame.width, height: frame.height)
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
        case .minimize:
            return AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            ) == .success
        }
    }
}
