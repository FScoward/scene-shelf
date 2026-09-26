import SceneShelfCore

// Command Line Tools ships SwiftPM without XCTest/Swift Testing modules. This
// target remains a compile-time package-test target; the executable contract
// runner executes the same assertions in the CLT-only environment.
enum CompileOnlyContract {
    static let expectedSceneNames = FakeSceneFactory.defaultScenes.map(\.name)
}
