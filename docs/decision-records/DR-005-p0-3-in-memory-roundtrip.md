# DR-005: P0-3はin-memory roundtripを先行する

日付: 2026-09-25
対象: Scene Shelf / P0-3
関連: GitHub Issue #1 Plan revision 1, `SceneShelfCore/SceneRoundTrip.swift`

## 目的

ユーザーが現在のFixture配置を確認し、対象を除外して保存し、生成されたカードをクリックして表示・再クリックして退避できる最小往復を、外部ファイルや任意アプリ操作に広げず検証する。

## 制約・確認済み事実

- P0-2のlive AX境界は `SceneShelfAccessibility` のactorに閉じ、対象bundleを専用Fixtureへ限定している。
- Core/runnerはCLT環境で実行する必要があり、XCTest/Swift Testingの実行モジュールは利用できない。
- Issue #1のP0-3対象は1ディスプレイのcapture、対象確認/除外、表示・再クリック退避で、disk persistence・複数display・任意アプリは後続スコープである。
- fixtureのwindow状態はraw AX参照ではなく、Sendableな値として受け渡せる。

## 決定

1. scene保存は `InMemorySceneStore` actorに限定し、candidate snapshotと選択identityから `SavedScene` を作る。
2. Coreは `SceneWindowIdentity`、`SceneFrame`、`SceneWindowSnapshot`、`SceneRestorePlan` だけを扱い、AX型や`AXUIElement`を依存させない。
3. UIはAX snapshotをCore値型へ変換し、カードクリック時にCoreのplanをAX requestへ戻す。AX actorは各operationのwrite直前に対象を再解決する。
4. 除外対象をplanへ入れず、表示/退避のexecutorもplanにあるinstructionだけを実行する。
5. `display`のoperation順は `unminimize → move → resize`、`hide`は `minimize` とする。全操作成功時だけ状態を遷移し、失敗時は元の状態へ戻す。

## Why

- in-memory先行なら、Phase 0で価値の中心である「確認・除外・クリック往復」を、保存schemaや再起動移行の判断から切り離して観測できる。
- Coreを値型境界にすると、実AXの非Sendable参照をUI/Coreへ漏らさず、CLTのrunnerで同じcapture/plan/state契約を検証できる。
- planを登録対象だけから作ることで、除外対象へwriteしない性質を型と自動テストの両方で追跡できる。
- displayで先にunminimizeすることで、minimizedなfixtureへ位置・サイズを適用する不確実性を減らし、ユーザーの表示意図を先に満たす。

## Why not

- disk persistenceは、index/revision/schema・クラッシュ/再起動時復元・移行の判断を同時に導入し、P0-3の往復検証を曖昧にするため採用しない。Phase 1で別途決める。
- 任意アプリの自動対象化は、bundle/window identity・権限・曖昧一致・副作用の設計が未確定で、専用Fixtureの安全境界を壊すため採用しない。
- 複数display対応は、display UUID・Space・座標系・退避先の契約が必要で、1ディスプレイの価値検証に不要なため採用しない。
- CoreからAX actorを直接参照する構造は、raw参照のライフタイム/actor境界を漏らすため採用しない。

## 帰結

- P0-3の自動契約は高速・再現可能に検証できる。
- アプリ終了で保存sceneは失われる。現時点では仕様どおりであり、再起動後復元は未提供。
- real AX手動往復は別途必要で、自動runnerのPASSだけではP0-3の実ユーザー受入れ完了とは判定しない。

## 再検討条件

- 再起動後復元を要求するPlan revisionが承認されたとき、disk schema・atomic write・migrationを設計する。
- 任意アプリや複数displayを対象に含めるPlan revisionが承認されたとき、identity matcher・display mapping・partial failureをP0-4以降で設計する。
- real AX手動往復でadapter/reportの失敗が観測されたとき、P0-4の部分成功/理由表示の境界を更新する。

## 関連テスト

- `Sources/SceneShelfRoundTripTestRunner/main.swift`: capture選択、空選択、display/hide plan、除外対象write 0、状態往復。
- `Sources/SceneShelfAXTestRunner/main.swift`: `unminimize`、権限/対象/再解決の安全境界。
