import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import AppKit
import SceneShelfCore
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// ScreenCaptureKit adapter for saved-scene thumbnails.
///
/// The saved AX identifier has no equivalent on `SCWindow`, so matching is
/// intentionally limited to the owner bundle, process ID, and title. A
/// non-unique result is rejected unless the saved frame identifies exactly
/// one candidate, avoiding an arbitrary capture.
#if canImport(ScreenCaptureKit)
final class ScreenCaptureKitThumbnailCaptureService: SceneThumbnailCapturing, @unchecked Sendable {
    private let maximumSize = SceneThumbnailSize(width: 400, height: 280)

    func capture(scene: SavedScene) async throws -> Data {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess(), CGPreflightScreenCaptureAccess() else {
                throw SceneThumbnailCaptureError.permissionDenied
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw SceneThumbnailCaptureError.captureFailed
        }

        var images: [SceneWindowIdentity: SceneThumbnailImage] = [:]
        for snapshot in scene.windows {
            let matches = content.windows.filter { window in
                guard let application = window.owningApplication else { return false }
                return application.bundleIdentifier == snapshot.identity.bundleIdentifier
                    && Int32(application.processID) == snapshot.identity.processID
                    && window.title == snapshot.identity.title
            }
            let descriptors = matches.map { window in
                SceneThumbnailWindowDescriptor(
                    bundleIdentifier: snapshot.identity.bundleIdentifier,
                    processID: snapshot.identity.processID,
                    title: snapshot.identity.title,
                    frame: SceneFrame(
                        x: window.frame.origin.x,
                        y: window.frame.origin.y,
                        width: window.frame.width,
                        height: window.frame.height
                    )
                )
            }
            guard let matchIndex = SceneThumbnailWindowResolution.uniqueMatchIndex(
                identity: snapshot.identity,
                candidates: descriptors,
                savedFrame: snapshot.frame
            ), matches.indices.contains(matchIndex) else {
                if matches.isEmpty {
                    throw SceneThumbnailCaptureError.windowMissing(snapshot.identity)
                }
                throw SceneThumbnailCaptureError.ambiguousWindow(snapshot.identity)
            }
            let window = matches[matchIndex]

            let configuration = SCStreamConfiguration()
            let captureSize = SceneThumbnailCaptureSizing.outputSize(
                for: SceneFrame(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y,
                    width: window.frame.width,
                    height: window.frame.height
                ),
                maximumSize: maximumSize
            )
            configuration.width = captureSize.width
            configuration.height = captureSize.height
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            do {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                images[snapshot.identity] = try SceneThumbnailImage(cgImage: cgImage)
            } catch let error as SceneThumbnailCaptureError {
                throw error
            } catch {
                throw SceneThumbnailCaptureError.captureFailed
            }
        }

        let composite = try SceneThumbnailComposer.compose(
            scene: scene,
            images: images,
            maximumSize: maximumSize
        )
        return try composite.pngData()
    }
}
#else
/// CoreGraphics fallback for the CLT-only environment. The direct
/// `CGWindowListCreateImage` declaration is unavailable in the current SDK
/// because Apple obsoleted it on macOS 15, while the exported CoreGraphics
/// symbol is still present for the macOS 14 deployment target. Resolve that
/// symbol dynamically so this target remains buildable without Xcode and still
/// captures only the requested window ID.
final class ScreenCaptureKitThumbnailCaptureService: SceneThumbnailCapturing, @unchecked Sendable {
    private let maximumSize = SceneThumbnailSize(width: 400, height: 280)

    func capture(scene: SavedScene) async throws -> Data {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess(), CGPreflightScreenCaptureAccess() else {
                throw SceneThumbnailCaptureError.permissionDenied
            }
        }

        let candidates = try windowCandidates()
        var images: [SceneWindowIdentity: SceneThumbnailImage] = [:]
        for snapshot in scene.windows {
            let matches = candidates.filter {
                $0.descriptor.bundleIdentifier == snapshot.identity.bundleIdentifier
                    && $0.descriptor.processID == snapshot.identity.processID
                    && $0.descriptor.title == snapshot.identity.title
            }
            let descriptors = matches.map(\.descriptor)
            guard let matchIndex = SceneThumbnailWindowResolution.uniqueMatchIndex(
                identity: snapshot.identity,
                candidates: descriptors,
                savedFrame: snapshot.frame
            ), matches.indices.contains(matchIndex) else {
                if matches.isEmpty {
                    throw SceneThumbnailCaptureError.windowMissing(snapshot.identity)
                }
                throw SceneThumbnailCaptureError.ambiguousWindow(snapshot.identity)
            }
            let candidate = matches[matchIndex]
            guard let cgImage = captureWindowImage(windowID: candidate.windowID) else {
                throw SceneThumbnailCaptureError.captureFailed
            }
            let image = try SceneThumbnailImage(cgImage: cgImage)
            let singleWindowScene = SavedScene(
                id: scene.id,
                name: scene.name,
                windows: [snapshot]
            )
            images[snapshot.identity] = try SceneThumbnailComposer.compose(
                scene: singleWindowScene,
                images: [snapshot.identity: image],
                maximumSize: maximumSize
            )
        }

        let composite = try SceneThumbnailComposer.compose(
            scene: scene,
            images: images,
            maximumSize: maximumSize
        )
        return try composite.pngData()
    }

    private struct WindowCandidate {
        let windowID: CGWindowID
        let descriptor: SceneThumbnailWindowDescriptor
    }

    private func windowCandidates() throws -> [WindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionAll,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw SceneThumbnailCaptureError.captureFailed
        }
        return windowInfo.compactMap { info in
            guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bundleIdentifier = NSRunningApplication(
                      processIdentifier: pid_t(ownerPID)
                  )?.bundleIdentifier,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                  let windowLayer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let sharingState = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue else {
                return nil
            }
            let descriptor = SceneThumbnailWindowDescriptor(
                bundleIdentifier: bundleIdentifier,
                processID: ownerPID,
                title: (info[kCGWindowName as String] as? String) ?? "",
                frame: SceneFrame(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                ),
                windowLayer: windowLayer,
                sharingState: sharingState
            )
            // CGWindowList also contains menu-bar, overlay, and other helper
            // surfaces. They may share the saved owner/PID/title, but are not
            // the user window represented by the AX snapshot.
            guard SceneThumbnailWindowResolution.capturableCandidates([descriptor]).count == 1 else {
                return nil
            }
            return WindowCandidate(
                windowID: CGWindowID(windowNumber),
                descriptor: descriptor
            )
        }
    }

    private func captureWindowImage(windowID: CGWindowID) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect,
            UInt32,
            UInt32,
            UInt32
        ) -> Unmanaged<CGImage>?

        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let imageOptions = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        return capture(
            .null,
            UInt32(CGWindowListOption.optionIncludingWindow.rawValue),
            UInt32(windowID),
            UInt32(imageOptions.rawValue)
        )?.takeRetainedValue()
    }
}
#endif
