# P1-4 AX/UI quality evidence

更新日: 2026-09-26 JST
対象: AT-1 / AT-3 / AT-6 / AT-10の品質フォローアップ
設計判断: [`DR-017`](../../decision-records/DR-017-ax-discovery-and-event-boundaries.md)
Round2判断: [`DR-020`](../../decision-records/DR-020-qg-round2-ax-ui-boundaries.md)

## 判定

AX discovery原因の値型保持、保存準備での原因伝播、move/resize/minimizeのstateful fake read-back、保存カードのAppKit event境界を自動検証した。実AX/TCCの操作後frame read-back、実機Menu popup、VoiceOverはこの証跡ではPASSを主張しない。

## TDD Red

レビュー指摘を再現する契約として、次を先行追加した。

- empty候補だけでなく `permissionDenied` / `applicationUnavailable` / `ambiguousMatch` を公開値型で保持する。
- 保存準備が discovery failure を `windowMissing` へ誤変換せず、原因付きエラーにする。
- AX operation後に frame と `isMinimized` を同じfakeからread-backする。
- `NSHostingView`を`NSWindow.sendEvent`へ接続し、primary whitespace clickが1回、Menu eventがprimaryへ伝播しないことを観測する。

Round2では、nil-frame move/resizeを成功扱いしないケース、cleanup failure後のrefresh方針、検出／保存／上書き／復元のreason boundaryを先に追加し、runtime countと日本語表示契約が実装へ依存せず観測できる形にした。

旧契約では新しいdiscovery/error型とevent assertionを表現できず、production契約追加前のcompile Redになる境界だった。Menu popupをheadless CLIで直接開く試みは`Nil screen`のAppKit例外になったため、test windowでMenu eventのhitを記録しpopup表示だけを抑止する境界へ調整した。

## Green

### AX runner

```text
PASS: discovery preserves permission, unavailable, and ambiguous reasons
PASS: save preparation reports discovery failure instead of missing window
PASS: unique fixture plan applies exact requested operations
PASS: move and resize with unavailable frame perform zero writes
SceneShelfAXTestRunner: 17 tests passed
```

`unique fixture plan applies exact requested operations` は、要求した目標frame `(120,140,800,600)` と `isMinimized=true` を操作後read-backしている。これはstateful fakeの値型検証であり、実AX read-backやTCC許可の証明ではない。

### Presentation runner

```text
PASS: saved scene primary whitespace click invokes its action exactly once
PASS: saved scene management menu receives the menu-area AppKit event
PASS: saved scene management menu click does not invoke the primary action
PASS: cleanup failure keeps the warning that deletion was already applied
PASS: cleanup failure requests a store refresh after the delete
SceneShelfPresentationTestRunner: 11 tests passed
```

`NSHostingView`を実`NSWindow`へ載せ、AppKit mouse down/upを送ってprimary action countを観測した。Menu領域はSwiftUIのMenu viewへhitし、headless screen依存のpopup表示は行っていない。

## UI reason boundary

`ShelfViewModel`は次の経路で原因を表示する。

- Fixture検出: discovery failureの日本語label
- 保存: `保存対象を取得できないため、保存を中止しました: <理由>`
- 現在の配置で上書き: `現在の配置を取得できません: <理由>`
- 保存済み配置の復元: 対象windowごとの`SceneFailureMessageFormatter`へ discovery reasonを保持

`SceneRoundTrip`と`ScenePersistence`は変更していない。

## Mihari Agent Z Round2 Green（2026-09-26 JST）

- `FakeAXAdapter`の`move`/`resize`は現在frameが取得できない場合に`operationFailed`を返し、`appliedOperations`とwrite数を増やさず、snapshotを変更しない。
- `SceneShelfAXTestRunner`のsummaryは`run`呼び出し数を実行時集計するため、テスト追加時に表示値が取り残されない。今回の実行値は17件。
- `SceneShelfManagementPresentation`へcleanup failureの警告とrefresh要否を抽出し、`ShelfViewModel.confirmDelete`は削除失敗後も警告を表示してstoreを再読込する。削除が反映済みのカードを一覧に残さない。
- `SceneShelfAXPresentation`と併せ、検出／保存／上書き／復元の各discovery failure理由を日本語値型境界で実行検証した。Presentation runnerの実行値は11件。

### Round2回帰検証

```text
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 17 tests passed
SceneShelfRoundTripTestRunner: 10 tests passed
SceneShelfP0FourTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 11 tests passed
SceneShelfPersistenceTestRunner: PASS (15 tests)
SceneShelfManagementTestRunner: PASS (14 tests)
SceneShelfSwitchingTestRunner: 13 tests passed
strict swift build: PASS
strict swift test: PASS (compile-only XCTest target in this CLT environment)
scripts/build-app.sh: PASS
scripts/build-ax-fixture.sh: PASS
codesign --verify --deep --strict: PASS (SceneShelf.app / SceneShelfAXFixture.app)
plutil -lint Info.plist: PASS (SceneShelf.app / SceneShelfAXFixture.app)
```

この回帰検証ではアプリ起動、Accessibility設定変更、commit、push、Issue更新は行っていない。

## 未確認の手動境界

- TCC許可済み実AXでのmove/resize後のAX frame read-backとminimized属性read-back
- 実機のMenu popup選択、VoiceOver、トラックパッド操作
- 任意アプリへの操作。既存方針どおりfixture bundle限定
