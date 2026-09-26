# DR-017: AX discovery cause and saved-card event boundaries

## Metadata

- Phase: Phase 1 / AT-1, AT-3, AT-6, AT-10 quality follow-up
- Kind: 通常判断（Decision D17）
- Scope: `SceneShelfAccessibility` discovery values, ShelfViewModel UI reason propagation, presentation runner event boundary
- Reversible: code and local evidence only; no Accessibility/TCC, app launch, or remote state change

## Purpose

空のFixture候補だけでは、Accessibility権限拒否・Fixture未起動・同一Bundleの複数processという異なる安全停止理由をUIへ伝えられない。保存・復元時に原因を失わず、ユーザーが次に取るべき判断に対応する日本語理由を表示する。また、保存カードの余白clickが主要actionを一度だけ実行し、管理Menuのeventが主要actionへ伝播しないことを、単なる`hitTest != nil`より強い実行可能テストで固定する。

## Constraints and facts

- `AXUIElement`と`NSRunningApplication`は既存のactor内境界から外へ返さない。
- 既存の`fixtureWindows() -> [AXWindowSnapshot]`とfake adapterを直ちに壊さず、Sendable値型で原因を追加する必要がある。
- `SceneRoundTrip`と`ScenePersistence`はP1-3/P1-2の正本実装であり、この修正では変更しない。
- P0-2 manual evidenceは`AXOperationReport.appliedOperations`を確認済みだが、move/resize後の実AX frame read-backを同一操作で記録していない。
- SwiftPM CLI runnerは実画面のMenu popupを表示するとscreenが無い環境でAppKit例外になるため、Menu hitを記録してpopup表示だけを抑止するテスト用NSWindow境界が必要。

## Decision

1. `AXWindowDiscoveryResult`を公開Sendable値型として追加し、`windows`と`failureReason`を同時に返す。
2. `AXWindowAdapter`へ`fixtureWindowResult()`要求を追加し、既存`fixtureWindows()`だけを持つadapterにはsuccessへ包むdefault implementationを提供する。live `AXSystemAdapter`はpermission denied / application unavailable / ambiguous match / window missingをそれぞれ結果へ保持する。
3. 保存準備はdiscovery failureを`AXSceneCaptureError.discoveryFailed`へ変換し、保存UIは原因の日本語labelを表示する。検出・overwrite・保存済み配置の復元も同じ原因を直接または対象別reportへ変換する。
4. AX fakeは成功したmove/resize/minimizeの状態をsnapshotへ反映し、同じadapterからread-backしたframe/minimized値をassertする。これはreal AXの代替と主張せず、AX operation reportだけでは検証できない副作用契約の自動境界とする。
5. Presentation runnerは実`NSHostingView`を`NSWindow.sendEvent`へ接続し、primary whitespace clickがactionを正確に1回呼ぶこと、Menu hitがMenu viewへ届きprimary action countが増えないことを検証する。Menu popup自体はheadless CLIのscreen依存を避けるためtest windowが抑止する。

## Why

- 原因をwindow配列と同じ値型結果へ持たせると、空配列をmissingと誤表示せず、raw AX参照を増やさずに安全停止理由をUIへ運べる。
- protocolのdefault bridgeにより、既存のfixture fakeとlegacy callerはsnapshot-onlyのまま動き、live adapterだけが実原因を提供できる。
- 保存と復元の両方で同じdiscovery failureを使うと、AT-1の権限案内とAT-6の部分／失敗理由が異なる層で食い違わない。
- fake read-backは、`appliedOperations`という報告だけで「実際にframe/minimized状態が変わった」と推測する穴を、状態fulな観測で埋める。
- `NSHostingView`の実event routingを使うことで、親viewがhitしただけの弱いテストから、action回数とMenu境界を外部観測するテストへ移行できる。

## Why not

- `fixtureWindows()`を直ちに結果型へ置換する案は、既存fakeとP0/P1 runnerの契約を一斉変更し、今回の原因表示修正に不要な移行範囲を増やすため採用しない。
- 空配列をUI側で常に`windowMissing`として扱う案は、permission denied・未起動・ambiguousを誤った復旧案内へ変換するため採用しない。
- raw AX objectをdiscovery resultへ保持する案は、既存のSendable／actor安全境界を破るため採用しない。
- Menuの実popupをCLIで開く案は、screen未接続環境でAppKitの`Nil screen`例外を起こし、action境界の検証より環境依存を増やすため採用しない。
- P0-2 manualの`appliedOperations`だけをread-backとみなす案は、位置・サイズ・最小化状態の観測値がないため採用しない。

## Consequences and risks

- live discovery失敗は日本語理由として表示される。従来のlegacy `fixtureWindows()` callerは空配列を受け取るが、原因を必要とするUIは新しいresult APIを使う。
- stateful fakeはテスト専用であり、real AX/TCCや他アプリの安全性を証明しない。実AX read-backが必要なリリースゲートは別manual/integration evidenceとして残る。
- headless event testはMenu popupの視覚表示・VoiceOver・実機trackを証明しないが、primary actionの重複発火と兄弟Menuへの伝播を自動観測する。

## Reconsideration conditions

- 外部adapterが`fixtureWindows()`の戻り型変更を許容できるAPI移行計画を持つ場合、legacy bridgeを整理してresult-onlyへ移行する。
- TCC付き実機runnerでmove/resize/minimize後のAX frame/minimized read-backが安定して取得できる場合、stateful fakeに加えて実AX evidenceをリリースゲートへ昇格する。
- Menuの実機操作またはVoiceOverでprimaryへ伝播する事実が確認された場合、SwiftUI/AppKit event boundaryを再調査する。

## Related executable tests

- `SceneShelfAXTestRunner`: discovery reason propagation、save preparation error propagation、stateful frame/minimized read-back
- `SceneShelfPresentationTestRunner`: AppKit event primary whitespace exactly-once、Menu hit isolation
