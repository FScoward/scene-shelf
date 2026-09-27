import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfCoreTestRunner {
    private static var failures = 0

    static func main() async {
        await run("fake scenes keep the approved display order") {
            let coordinator = SceneCoordinator(scenes: FakeSceneFactory.defaultScenes)
            let snapshot = await coordinator.snapshot()
            expect(snapshot.cards.map(\.name) == ["開発", "会議"])
        }

        await run("stashed card click completes as displayed") {
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")]
            )
            let outcome = await coordinator.click(sceneID: "development")
            let snapshot = await coordinator.snapshot()
            expect(outcome == .completed(sceneID: "development", state: .displayed))
            expect(snapshot.cards.first?.state == .displayed)
        }

        await run("displayed card click completes as stashed") {
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")],
                initialState: .displayed
            )
            let outcome = await coordinator.click(sceneID: "development")
            let snapshot = await coordinator.snapshot()
            expect(outcome == .completed(sceneID: "development", state: .stashed))
            expect(snapshot.cards.first?.state == .stashed)
        }

        await run("busy same card is rejected without a second operation") {
            let gate = OperationGate()
            let coordinator = SceneCoordinator(
                scenes: [SceneDefinition(id: "development", name: "開発")],
                operation: { _, _ in await gate.blockUntilReleased() }
            )
            let firstClick = Task { await coordinator.click(sceneID: "development") }
            await gate.waitForStart()
            let secondOutcome = await coordinator.click(sceneID: "development")
            let preparingSnapshot = await coordinator.snapshot()
            expect(secondOutcome == .busyRejected(sceneID: "development"))
            expect(preparingSnapshot.cards.first?.state == .preparing)
            await gate.release()
            let firstOutcome = await firstClick.value
            let startedCount = await gate.startedCount
            expect(firstOutcome == .completed(sceneID: "development", state: .displayed))
            expect(startedCount == 1)
        }

        await run("busy different card is rejected and not queued") {
            let gate = OperationGate()
            let coordinator = SceneCoordinator(
                scenes: FakeSceneFactory.defaultScenes,
                operation: { _, _ in await gate.blockUntilReleased() }
            )
            let firstClick = Task { await coordinator.click(sceneID: "development") }
            await gate.waitForStart()
            let rejectedOutcome = await coordinator.click(sceneID: "meeting")
            let preparingSnapshot = await coordinator.snapshot()
            expect(rejectedOutcome == .busyRejected(sceneID: "meeting"))
            expect(preparingSnapshot.cards.map(\.state) == [.preparing, .stashed])
            await gate.release()
            let firstOutcome = await firstClick.value
            expect(firstOutcome == .completed(sceneID: "development", state: .displayed))
            let completedSnapshot = await coordinator.snapshot()
            expect(completedSnapshot.cards.map(\.state) == [.displayed, .stashed])
            let startedCount = await gate.startedCount
            expect(startedCount == 1)
        }

        await run("empty scenes return a safe empty shelf result") {
            let coordinator = SceneCoordinator(scenes: [])
            let snapshot = await coordinator.snapshot()
            let outcome = await coordinator.click(sceneID: "missing")
            expect(snapshot.cards.isEmpty)
            expect(outcome == .emptyShelf)
        }

        await run("workspace context canonicalizes displays and scopes by UUID") {
            let first = WorkspaceDisplayContext(
                displayIdentifier: "display-b",
                currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-b", id64: 22)
            )
            let second = WorkspaceDisplayContext(
                displayIdentifier: "display-a",
                currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-a", id64: 11)
            )
            let reordered = WorkspaceContext(displays: [first, second])
            let renumbered = WorkspaceContext(displays: [
                WorkspaceDisplayContext(
                    displayIdentifier: "display-a",
                    currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-a", id64: 101)
                ),
                WorkspaceDisplayContext(
                    displayIdentifier: "display-b",
                    currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-b", id64: 202)
                )
            ])
            expect(reordered.displays.map(\.displayIdentifier) == ["display-a", "display-b"])
            expect(reordered.sameScope(as: renumbered))
            expect(reordered.scopeKey == "display-a=uuid-a|display-b=uuid-b")
        }

        await run("workspace context Codable rejects malformed payload") {
            let valid = WorkspaceContext(displays: [
                WorkspaceDisplayContext(
                    displayIdentifier: "display-a",
                    currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-a", id64: 1)
                )
            ])
            let data = try? JSONEncoder().encode(valid)
            let decoded = data.flatMap { try? JSONDecoder().decode(WorkspaceContext.self, from: $0) }
            expect(decoded == valid)
            let malformed = try? JSONDecoder().decode(
                WorkspaceContext.self,
                from: Data(#"{"displays":[]}"#.utf8)
            )
            expect(malformed == nil)
        }

        await run("workspace membership policy fails closed for outside, multiple, and missing") {
            let context = WorkspaceContext(displays: [
                WorkspaceDisplayContext(
                    displayIdentifier: "display-a",
                    currentSpace: WorkspaceSpaceIdentity(uuid: "uuid-a", id64: 1)
                )
            ])
            let target = SceneWindowIdentity(
                bundleIdentifier: "com.example.app",
                processID: 10,
                title: "Main"
            )
            expect(WorkspaceWindowMembershipPolicy.evaluate(target: target, spaceIDs: [1], context: context).membership == .current)
            expect(WorkspaceWindowMembershipPolicy.evaluate(target: target, spaceIDs: [2], context: context).membership == .outside)
            expect(WorkspaceWindowMembershipPolicy.evaluate(target: target, spaceIDs: [1, 2], context: context).membership == .multiple)
            expect(WorkspaceWindowMembershipPolicy.evaluate(target: target, spaceIDs: [], context: context).membership == .missing)
        }

        await run("workspace window resolver accepts a unique window after frame change") {
            let target = SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main"
                ),
                frame: SceneFrame(x: 10, y: 10, width: 400, height: 300),
                isMinimized: false
            )
            let candidates = [
                WorkspaceWindowCandidate(
                    windowID: 21,
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main",
                    frame: SceneFrame(x: 500, y: 200, width: 800, height: 600)
                )
            ]
            expect(
                WorkspaceWindowResolver.resolve(target: target, candidates: candidates)
                    == .matched(windowID: 21)
            )
        }

        await run("workspace window resolver uses frame to disambiguate duplicate identities") {
            let target = SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main"
                ),
                frame: SceneFrame(x: 10, y: 10, width: 400, height: 300),
                isMinimized: false
            )
            let candidates = [
                WorkspaceWindowCandidate(
                    windowID: 21,
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main",
                    frame: target.frame
                ),
                WorkspaceWindowCandidate(
                    windowID: 22,
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main",
                    frame: SceneFrame(x: 800, y: 400, width: 500, height: 400)
                )
            ]
            expect(
                WorkspaceWindowResolver.resolve(target: target, candidates: candidates)
                    == .matched(windowID: 21)
            )
        }

        await run("workspace window resolver fails when duplicate identities stay ambiguous") {
            let target = SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main"
                ),
                frame: SceneFrame(x: 10, y: 10, width: 400, height: 300),
                isMinimized: false
            )
            let candidates = [
                WorkspaceWindowCandidate(
                    windowID: 21,
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main",
                    frame: SceneFrame(x: 10, y: 10, width: 400, height: 300)
                ),
                WorkspaceWindowCandidate(
                    windowID: 22,
                    bundleIdentifier: "com.example.app",
                    processID: 10,
                    title: "Main",
                    frame: SceneFrame(x: 12, y: 12, width: 402, height: 302)
                )
            ]
            expect(
                WorkspaceWindowResolver.resolve(target: target, candidates: candidates)
                    == .ambiguous
            )
        }

        await run("SkyLight payload parser accepts multiple displays and rejects malformed payload") {
            let payload: [[String: Any]] = [
                [
                    "Display Identifier": "display-b",
                    "Current Space": ["uuid": "uuid-b", "ManagedSpaceID": NSNumber(value: 22)]
                ],
                [
                    "Display Identifier": "display-a",
                    "Current Space": ["uuid": "uuid-a", "ManagedSpaceID": NSNumber(value: 11)]
                ]
            ]
            let context = try? WorkspaceContextPayloadParser.parse(payload)
            expect(context?.displays.map(\.displayIdentifier) == ["display-a", "display-b"])
            let malformed = try? WorkspaceContextPayloadParser.parse([
                ["Display Identifier": "display-a"]
            ])
            expect(malformed == nil)
        }

        await run("workspace membership payload parser rejects invalid numeric values") {
            let valid = try? WorkspaceSpaceMembershipPayloadParser.parse([
                NSNumber(value: 7),
                ["ManagedSpaceID": NSNumber(value: 8)] as [String: Any]
            ])
            expect(valid == [7, 8])

            let negative = try? WorkspaceSpaceMembershipPayloadParser.parse([
                NSNumber(value: -1)
            ])
            let fraction = try? WorkspaceSpaceMembershipPayloadParser.parse([
                NSNumber(value: 1.5)
            ])
            let mixed = try? WorkspaceSpaceMembershipPayloadParser.parse([
                NSNumber(value: 7),
                ["unexpected": NSNumber(value: 9)] as [String: Any]
            ])
            expect(negative == nil)
            expect(fraction == nil)
            expect(mixed == nil)
        }

        if failures == 0 {
            print("SceneShelfCoreTestRunner: tests passed")
        } else {
            print("SceneShelfCoreTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
    }

    private static func run(_ name: String, _ body: () async -> Void) async {
        let before = failures
        await body()
        if failures == before {
            print("PASS: \(name)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool) {
        if !condition() {
            failures += 1
            print("FAIL")
        }
    }
}

private actor OperationGate {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0

    func waitForStart() async {
        if startedCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockUntilReleased() async {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
