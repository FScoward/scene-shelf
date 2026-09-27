import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// A stable identifier for one managed macOS Space.
///
/// The UUID is the primary identity and the managed-space id is retained as a
/// consistency check. Both values come from the same SkyLight snapshot.
public struct WorkspaceSpaceIdentity: Codable, Equatable, Hashable, Sendable {
    public let uuid: String
    public let id64: UInt64

    public init(uuid: String, id64: UInt64) {
        self.uuid = uuid
        self.id64 = id64
    }

    fileprivate func validate() throws {
        guard !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id64 > 0 else {
            throw WorkspaceContextError.malformedPayload
        }
    }
}

/// The current Space for one display. Display order is canonicalized by
/// `WorkspaceContext`, so equality does not depend on SkyLight dictionary
/// order.
public struct WorkspaceDisplayContext: Codable, Equatable, Hashable, Sendable {
    public let displayIdentifier: String
    public let currentSpace: WorkspaceSpaceIdentity

    public init(
        displayIdentifier: String,
        currentSpace: WorkspaceSpaceIdentity
    ) {
        self.displayIdentifier = displayIdentifier
        self.currentSpace = currentSpace
    }

    fileprivate func validate() throws {
        guard !displayIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceContextError.malformedPayload
        }
        try currentSpace.validate()
    }
}

/// A canonical, Codable value describing the user's current multi-display
/// workspace. This type intentionally contains no AppKit or AX objects.
public struct WorkspaceContext: Codable, Equatable, Hashable, Sendable {
    public let displays: [WorkspaceDisplayContext]

    /// Value construction canonicalizes display ordering. Runtime providers
    /// and decoding use `validated(displays:)` to reject malformed payloads.
    public init(displays: [WorkspaceDisplayContext]) {
        self.displays = displays.sorted {
            if $0.displayIdentifier == $1.displayIdentifier {
                return $0.currentSpace.uuid < $1.currentSpace.uuid
            }
            return $0.displayIdentifier < $1.displayIdentifier
        }
    }

    public static func validated(
        displays: [WorkspaceDisplayContext]
    ) throws -> WorkspaceContext {
        guard !displays.isEmpty else {
            throw WorkspaceContextError.malformedPayload
        }
        try displays.forEach { try $0.validate() }
        let displayIDs = displays.map(\.displayIdentifier)
        guard Set(displayIDs).count == displayIDs.count else {
            throw WorkspaceContextError.malformedPayload
        }
        return WorkspaceContext(displays: displays)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let displays = try container.decode([WorkspaceDisplayContext].self, forKey: .displays)
        self = try Self.validated(displays: displays)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displays, forKey: .displays)
    }

    /// UUID-based key used by UI filtering and diagnostics. The managed id is
    /// intentionally excluded because it can be renumbered at runtime.
    public var scopeKey: String {
        displays.map {
            "\($0.displayIdentifier)=\($0.currentSpace.uuid)"
        }.joined(separator: "|")
    }

    public func sameScope(as other: WorkspaceContext) -> Bool {
        scopeKey == other.scopeKey
    }

    public var currentSpaceIDs: Set<UInt64> {
        Set(displays.map(\.currentSpace.id64))
    }

    private enum CodingKeys: String, CodingKey {
        case displays
    }
}

public enum WorkspaceContextPayloadParser {
    public static func parse(_ payload: [[String: Any]]) throws -> WorkspaceContext {
        let displays = try payload.map { dictionary -> WorkspaceDisplayContext in
            guard let displayIdentifier = stringValue(dictionary["Display Identifier"]),
                      let currentSpace = dictionaryValue(dictionary["Current Space"]),
                      let uuid = stringValue(currentSpace["uuid"] ?? currentSpace["UUID"]),
                  let id64 = try? StrictWorkspaceIntegerParser.parse(
                      currentSpace["ManagedSpaceID"] ?? currentSpace["id64"] ?? currentSpace["id"]
                  ) else {
                throw WorkspaceContextError.malformedPayload
            }
            return WorkspaceDisplayContext(
                displayIdentifier: displayIdentifier,
                currentSpace: WorkspaceSpaceIdentity(uuid: uuid, id64: id64)
            )
        }
        return try WorkspaceContext.validated(displays: displays)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in value {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }
}

public enum WorkspaceSpaceMembershipPayloadParser {
    public static func parse(_ payload: [Any]) throws -> [UInt64] {
        try payload.map { item in
            if let number = item as? NSNumber {
                return try StrictWorkspaceIntegerParser.parse(number)
            }
            guard let dictionary = dictionaryValue(item) else {
                throw WorkspaceContextError.malformedPayload
            }
            guard let value = dictionary["ManagedSpaceID"]
                    ?? dictionary["id64"]
                    ?? dictionary["id"] else {
                throw WorkspaceContextError.malformedPayload
            }
            return try StrictWorkspaceIntegerParser.parse(value)
        }
    }

    private static func dictionaryValue(_ value: Any) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in value {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }
}

fileprivate enum StrictWorkspaceIntegerParser {
    static func parse(_ value: Any?) throws -> UInt64 {
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            switch type {
            case "c", "s", "i", "l", "q":
                let signed = number.int64Value
                guard signed > 0 else { throw WorkspaceContextError.malformedPayload }
                return UInt64(signed)
            case "C", "S", "I", "L", "Q":
                let unsigned = number.uint64Value
                guard unsigned > 0 else { throw WorkspaceContextError.malformedPayload }
                return unsigned
            default:
                throw WorkspaceContextError.malformedPayload
            }
        }
        if let value = value as? String,
           let unsigned = UInt64(value),
           unsigned > 0 {
            return unsigned
        }
        if let value = value as? NSString,
           let unsigned = UInt64(value as String),
           unsigned > 0 {
            return unsigned
        }
        throw WorkspaceContextError.malformedPayload
    }
}

public enum WorkspaceContextError: Error, Equatable, Sendable {
    case privateAPIUnavailable
    case malformedPayload
    case currentContextUnavailable
    case windowNotFound(SceneWindowIdentity)
    case windowAmbiguous(SceneWindowIdentity)
    case windowOutsideCurrentSpace(SceneWindowIdentity)
    case windowInMultipleSpaces(SceneWindowIdentity)
    case contextMismatch

    public var japaneseLabel: String {
        switch self {
        case .privateAPIUnavailable, .malformedPayload, .currentContextUnavailable:
            return "Space情報を取得できないため保存・復元できません"
        case let .windowNotFound(target):
            return "対象ウィンドウのSpace情報を取得できません: \(target.title)"
        case let .windowAmbiguous(target):
            return "対象ウィンドウを一意に特定できないためSpaceを確認できません: \(target.title)"
        case let .windowOutsideCurrentSpace(target):
            return "現在のSpace外のウィンドウは保存・復元しません: \(target.title)"
        case let .windowInMultipleSpaces(target):
            return "複数Spaceに属するウィンドウは保存・復元しません: \(target.title)"
        case .contextMismatch:
            return "保存時と現在のSpaceが異なるため操作しません"
        }
    }
}

/// Provider boundary used by persistence and UI. Keeping this protocol in
/// the core lets tests use deterministic values without loading SkyLight.
public protocol WorkspaceContextProviding: Sendable {
    func currentWorkspaceContext() throws -> WorkspaceContext
}

public struct FixedWorkspaceContextProvider: WorkspaceContextProviding, Sendable {
    public let context: WorkspaceContext?
    public let error: WorkspaceContextError?

    public init(context: WorkspaceContext) {
        self.context = context
        self.error = nil
    }

    public init(error: WorkspaceContextError) {
        self.context = nil
        self.error = error
    }

    public func currentWorkspaceContext() throws -> WorkspaceContext {
        if let error { throw error }
        guard let context else { throw WorkspaceContextError.currentContextUnavailable }
        return context
    }
}

public enum WorkspaceWindowMembership: Equatable, Sendable {
    case current
    case outside
    case multiple
    case missing
}

public struct WorkspaceWindowMembershipResult: Equatable, Sendable {
    public let target: SceneWindowIdentity
    public let membership: WorkspaceWindowMembership
    public let spaceIDs: [UInt64]

    public init(
        target: SceneWindowIdentity,
        membership: WorkspaceWindowMembership,
        spaceIDs: [UInt64] = []
    ) {
        self.target = target
        self.membership = membership
        self.spaceIDs = spaceIDs
    }
}

public struct WorkspaceWindowCandidate: Equatable, Sendable {
    public let windowID: UInt32
    public let bundleIdentifier: String
    public let processID: Int32
    public let title: String
    public let identifier: String?
    public let frame: SceneFrame?

    public init(
        windowID: UInt32,
        bundleIdentifier: String,
        processID: Int32,
        title: String,
        identifier: String? = nil,
        frame: SceneFrame? = nil
    ) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.title = title
        self.identifier = identifier
        self.frame = frame
    }
}

public enum WorkspaceWindowResolution: Equatable, Sendable {
    case matched(windowID: UInt32)
    case missing
    case ambiguous
}

public enum WorkspaceWindowResolver {
    public static func resolve(
        target: SceneWindowSnapshot,
        candidates: [WorkspaceWindowCandidate],
        frameTolerance: Double = 4
    ) -> WorkspaceWindowResolution {
        let identityMatches = candidates.filter {
            $0.bundleIdentifier == target.identity.bundleIdentifier
                && $0.processID == target.identity.processID
                && $0.title == target.identity.title
                && $0.identifier == target.identity.identifier
        }
        guard !identityMatches.isEmpty else { return .missing }
        guard identityMatches.count > 1 else {
            return .matched(windowID: identityMatches[0].windowID)
        }

        let frameMatches = identityMatches.filter {
            guard let candidateFrame = $0.frame else { return false }
            return frameApproximatelyEqual(candidateFrame, target.frame, tolerance: frameTolerance)
        }
        guard frameMatches.count == 1 else { return .ambiguous }
        return .matched(windowID: frameMatches[0].windowID)
    }

    private static func frameApproximatelyEqual(
        _ lhs: SceneFrame,
        _ rhs: SceneFrame,
        tolerance: Double
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

/// Pure membership policy. A window is valid for a scoped scene only if
/// SkyLight returns exactly one current-space id. All-Spaces windows therefore
/// fail closed as `.multiple`.
public enum WorkspaceWindowMembershipPolicy {
    public static func evaluate(
        target: SceneWindowIdentity,
        spaceIDs: [UInt64],
        context: WorkspaceContext
    ) -> WorkspaceWindowMembershipResult {
        let uniqueIDs = Array(Set(spaceIDs)).sorted()
        guard !uniqueIDs.isEmpty else {
            return WorkspaceWindowMembershipResult(
                target: target,
                membership: .missing
            )
        }
        guard uniqueIDs.count == 1 else {
            return WorkspaceWindowMembershipResult(
                target: target,
                membership: .multiple,
                spaceIDs: uniqueIDs
            )
        }
        let membership: WorkspaceWindowMembership = context.currentSpaceIDs.contains(uniqueIDs[0])
            ? .current
            : .outside
        return WorkspaceWindowMembershipResult(
            target: target,
            membership: membership,
            spaceIDs: uniqueIDs
        )
    }
}

public protocol WorkspaceWindowMembershipProviding: Sendable {
    func validate(
        windows: [SceneWindowSnapshot],
        in context: WorkspaceContext
    ) throws
}

public struct NoopWorkspaceWindowMembershipProvider: WorkspaceWindowMembershipProviding {
    public init() {}

    public func validate(
        windows: [SceneWindowSnapshot],
        in context: WorkspaceContext
    ) throws {}
}

/// The private API surface is deliberately isolated to these three read-only
/// symbols. No Space creation, deletion, or movement symbol is ever loaded.
fileprivate final class SkyLightReadOnlyBridge: @unchecked Sendable {
    private typealias MainConnectionFunction = @convention(c) () -> UInt32
    private typealias ManagedDisplaysFunction = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindowsFunction = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer
    private let mainConnection: MainConnectionFunction
    private let managedDisplays: ManagedDisplaysFunction
    private let spacesForWindows: SpacesForWindowsFunction

    init() throws {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            throw WorkspaceContextError.privateAPIUnavailable
        }
        self.handle = handle
        guard let mainPointer = dlsym(handle, "SLSMainConnectionID"),
              let displayPointer = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let windowPointer = dlsym(handle, "SLSCopySpacesForWindows") else {
            dlclose(handle)
            throw WorkspaceContextError.privateAPIUnavailable
        }
        mainConnection = unsafeBitCast(mainPointer, to: MainConnectionFunction.self)
        managedDisplays = unsafeBitCast(displayPointer, to: ManagedDisplaysFunction.self)
        spacesForWindows = unsafeBitCast(windowPointer, to: SpacesForWindowsFunction.self)
    }

    deinit {
        dlclose(handle)
    }

    func currentContext() throws -> WorkspaceContext {
        let connection = mainConnection()
        guard let unmanaged = managedDisplays(connection) else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        let array = unmanaged.takeRetainedValue() as NSArray
        guard array.count > 0 else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        let displays = array.compactMap { item -> [String: Any]? in
            if let dictionary = item as? [String: Any] { return dictionary }
            guard let dictionary = item as? NSDictionary else { return nil }
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else { continue }
                result[key] = value
            }
            return result
        }
        guard displays.count == array.count else {
            throw WorkspaceContextError.malformedPayload
        }
        return try WorkspaceContextPayloadParser.parse(displays)
    }

    func spaces(for windowID: CGWindowID) throws -> [UInt64] {
        let connection = mainConnection()
        let windowIDs = [NSNumber(value: UInt32(windowID))] as NSArray
        // The second argument is the tested mask (7 = all managed-space
        // membership flags), not an array count.
        guard let unmanaged = spacesForWindows(connection, 7, windowIDs as CFArray) else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        let value = unmanaged.takeRetainedValue() as NSArray
        return try WorkspaceSpaceMembershipPayloadParser.parse(value.map { $0 })
    }
}

/// Read-only bridge from an Accessibility element to its Core Graphics
/// window number. The public AX API deliberately does not expose this number,
/// so this private symbol is isolated here and is never used for mutation.
fileprivate final class AXWindowIDReadOnlyBridge: @unchecked Sendable {
    private typealias GetWindowFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let handle: UnsafeMutableRawPointer
    private let getWindow: GetWindowFunction

    init() throws {
        // Swift's Darwin overlay does not expose the RTLD_DEFAULT macro on
        // this CLT SDK. A handle for the current process has the same lookup
        // scope and keeps the symbol resolution local and read-only.
        guard let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else {
            throw WorkspaceContextError.privateAPIUnavailable
        }
        self.handle = handle
        guard let pointer = dlsym(handle, "_AXUIElementGetWindow") else {
            dlclose(handle)
            throw WorkspaceContextError.privateAPIUnavailable
        }
        getWindow = unsafeBitCast(pointer, to: GetWindowFunction.self)
    }

    deinit {
        dlclose(handle)
    }

    func windowID(for element: AXUIElement) throws -> CGWindowID {
        var windowID: CGWindowID = 0
        guard getWindow(element, &windowID) == .success, windowID != 0 else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        return windowID
    }
}

/// Production provider. It lazily loads SkyLight so tests and unsupported
/// environments fail only when a Space-scoped operation is requested.
public struct SkyLightWorkspaceContextProvider: WorkspaceContextProviding, Sendable {
    private static let bridge: Result<SkyLightReadOnlyBridge, WorkspaceContextError> = {
        do {
            return .success(try SkyLightReadOnlyBridge())
        } catch let error as WorkspaceContextError {
            return .failure(error)
        } catch {
            return .failure(.privateAPIUnavailable)
        }
    }()

    public init() {}

    public func currentWorkspaceContext() throws -> WorkspaceContext {
        switch Self.bridge {
        case let .success(bridge):
            return try bridge.currentContext()
        case let .failure(error):
            throw error
        }
    }
}

/// Runtime window-to-Space validation. It resolves the target through the
/// Accessibility window list (title + identifier), obtains the exact
/// CoreGraphics window number from that raw AX element, then asks SkyLight
/// only for that resolved window ID. It deliberately does not use
/// CGWindowList: its titles and frames can be redacted by Screen Recording
/// privacy even when Accessibility can identify the target.
public struct SkyLightWorkspaceWindowMembershipProvider: WorkspaceWindowMembershipProviding, Sendable {
    public init() {
    }

    public func validate(
        windows: [SceneWindowSnapshot],
        in context: WorkspaceContext
    ) throws {
        let skyLight = try SkyLightWorkspaceContextProvider.bridgeValue()
        guard AXIsProcessTrusted() else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        let windowIDBridge = try AXWindowIDReadOnlyBridge()
        for window in windows {
            let candidates = try windowCandidates(
                for: window.identity,
                windowIDBridge: windowIDBridge
            )
            let windowID: CGWindowID
            switch WorkspaceWindowResolver.resolve(target: window, candidates: candidates) {
            case let .matched(resolvedID):
                windowID = CGWindowID(resolvedID)
            case .missing:
                throw WorkspaceContextError.windowNotFound(window.identity)
            case .ambiguous:
                throw WorkspaceContextError.windowAmbiguous(window.identity)
            }
            let spaceIDs = try skyLight.spaces(for: windowID)
            let result = WorkspaceWindowMembershipPolicy.evaluate(
                target: window.identity,
                spaceIDs: spaceIDs,
                context: context
            )
            switch result.membership {
            case .current:
                continue
            case .outside:
                throw WorkspaceContextError.windowOutsideCurrentSpace(window.identity)
            case .multiple:
                throw WorkspaceContextError.windowInMultipleSpaces(window.identity)
            case .missing:
                throw WorkspaceContextError.windowNotFound(window.identity)
            }
        }
    }

    private func windowCandidates(
        for target: SceneWindowIdentity,
        windowIDBridge: AXWindowIDReadOnlyBridge
    ) throws -> [WorkspaceWindowCandidate] {
        guard let application = NSRunningApplication(
            processIdentifier: pid_t(target.processID)
        ), application.bundleIdentifier == target.bundleIdentifier,
        application.activationPolicy != .prohibited else {
            return []
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success else {
            throw WorkspaceContextError.currentContextUnavailable
        }
        guard let elements = rawValue as? [AXUIElement] else {
            throw WorkspaceContextError.malformedPayload
        }

        return try elements.compactMap { element in
            guard let title = copyAttribute(element, kAXTitleAttribute) as? String else {
                return nil
            }
            let identifier = copyAttribute(element, kAXIdentifierAttribute) as? String
            // Do not ask the private bridge for unrelated helper windows. A
            // failure to expose one of those elements must not make an
            // otherwise uniquely identifiable target fail closed.
            guard title == target.title,
                  identifier == target.identifier else {
                return nil
            }
            let windowID = try windowIDBridge.windowID(for: element)
            return WorkspaceWindowCandidate(
                windowID: UInt32(windowID),
                bundleIdentifier: target.bundleIdentifier,
                processID: target.processID,
                title: title,
                identifier: identifier,
                frame: readFrame(from: element)
            )
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func readFrame(from element: AXUIElement) -> SceneFrame? {
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
              AXValueGetValue(size, .cgSize, &cgSize),
              point.x.isFinite,
              point.y.isFinite,
              cgSize.width.isFinite,
              cgSize.height.isFinite,
              cgSize.width > 0,
              cgSize.height > 0 else {
            return nil
        }
        return SceneFrame(
            x: point.x,
            y: point.y,
            width: cgSize.width,
            height: cgSize.height
        )
    }

}

fileprivate extension SkyLightWorkspaceContextProvider {
    static func bridgeValue() throws -> SkyLightReadOnlyBridge {
        switch bridge {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }
}
