# P0-4 multi-window / partial outcome evidence

更新日: 2026-09-25 JST
対象: `SceneShelf` Phase 0 P0-4
正本: GitHub Issue #1 Plan revision 1

## 判定

Coreの複合Matcher、write計画の安全境界、対象別restore outcome、部分成功/全失敗の状態遷移は自動検証 PASS。`SceneShelfP0FourTestRunner` は12/12、`SceneShelfPresentationTestRunner` は最新D11を含め8/8、既存runnerも維持した。

P0-4のreal AX manual/integration（同じtitle/identifierのduplicate表示、PID再利用、実windowの部分成功）と、D11後のTextField再編集・全失敗カード・保存済み一覧スクロールのreal GUI再確認は未実施。D10では保存後ShelfViewのスクロールが全く動かないFAILをユーザー実機で確認した。したがってCP-final manual PASSやIssue #1の全AT PASSは主張しない。

## Red

P0-4契約を実装する前に、未実装の型と公開関数を参照するrunnerを追加し、以下を実行した。

```sh
mkdir -p .build-p0-4-red/module-cache .build-p0-4-red/spm
CLANG_MODULE_CACHE_PATH="$PWD/.build-p0-4-red/module-cache" \
  swift build --disable-sandbox \
  --scratch-path "$PWD/.build-p0-4-red/spm" \
  --product SceneShelfP0FourTestRunner \
  -Xswiftc -strict-concurrency=complete
```

実測Red（exit 1）:

```text
error: cannot find 'SceneMatcher' in scope
error: cannot find 'SceneTargetRestoreOutcome' in scope
error: cannot find 'SceneRestoreReport' in scope
error: cannot infer contextual base in reference to member 'display'
```

これは環境エラーではなく、P0-4で追加するCore契約が未実装であることによるcompile Redである。

## Green

環境:

- macOS Command Line Tools / Swift 6.3.3
- SwiftPM `--disable-sandbox`
- リポジトリ内scratch/module cache
- XCTest/Swift Testingなし、runner実assertion

ビルド:

```sh
mkdir -p .build-scroll-final/module-cache .build-scroll-final/spm
CLANG_MODULE_CACHE_PATH="$PWD/.build-scroll-final/module-cache" \
  swift build --disable-sandbox \
  --scratch-path "$PWD/.build-scroll-final/spm" \
  -Xswiftc -strict-concurrency=complete
```

結果: exit 0 / `SceneShelf`、fixture、5 runnerを含むSwiftPM build PASS。

P0-4 targeted runner:

```sh
.build-scroll-final/spm/arm64-apple-macosx/debug/SceneShelfP0FourTestRunner
```

```text
PASS: unique matcher selects one window from the same bundle
PASS: ambiguous same-title candidates produce zero write instructions
PASS: PID reuse produces zero write instructions
PASS: unique plus missing is aggregated as a partial restore
PASS: all failures produce Failed state and clear currentSceneID
PASS: target-specific failure reason is retained while later targets execute
PASS: successful restore sets currentSceneID
PASS: successful hide clears currentSceneID and stashes the card
PASS: legacy bool executor failure rolls back state currentSceneID and report
PASS: later click is rejected while a target report is busy
PASS: partial card retries display safely and can become displayed
PASS: excluded Secondary is absent from the write plan
SceneShelfP0FourTestRunner: 12 tests passed
```

## レビュー修正のRed/Green

P0-4実装後のレビューで、action別の`currentSceneID`契約とP0-3互換bool executorのロールバックを追加した。修正前に追加2ケースを含むrunnerを実行すると、既存ケースはPASSしたが新規assertion 4件が失敗し、exit 1となった。

```text
SceneShelfP0FourTestRunner: 4 failures
```

修正後は同じrunnerが以下でGreenとなった。

```text
PASS: successful hide clears currentSceneID and stashes the card
PASS: legacy bool executor failure rolls back state currentSceneID and report
SceneShelfP0FourTestRunner: 12 tests passed
```

既存runner:

```text
SceneShelfRoundTripTestRunner: 8 tests passed
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 10 tests passed
```

`CLANG_MODULE_CACHE_PATH="$PWD/.build-scroll-final/module-cache" swift test --disable-sandbox --scratch-path .build-scroll-final/spm -Xswiftc -strict-concurrency=complete` もcompile-only test targetとしてPASSした。

Bundle検証も以下の結果だった。

```text
scripts/build-app.sh: PASS
scripts/build-ax-fixture.sh: PASS
codesign --verify --deep --strict .build/SceneShelf.app: PASS
codesign --verify --deep --strict .build/SceneShelfAXFixture.app: PASS
plutil -lint Resources/Info.plist Resources/AXFixture-Info.plist: OK
```

## 実機入力不具合とPresentation修正のRed/Green

ユーザー実機で、メニューバーから開いたScene Shelfの配置名TextFieldをクリックしても編集できない不具合が報告された。原因候補である`NSPanel`のkey受け入れを、専用panel libraryのrunnerで固定した。

修正前は既存の`borderless` + `nonactivatingPanel`を保ったまま`canBecomeKey`が`false`となり、以下のRedを取得した。

```text
PASS: menu bar shelf keeps a borderless panel
PASS: menu bar shelf keeps the nonactivating panel behavior
FAIL: shelf panel must accept key focus for TextField editing
SceneShelfPresentationTestRunner: 1 failures
```

修正後は`canBecomeKey == true`、`canBecomeMain == false`、既存のborderless accessory契約をGreen確認した。後続のD10で、実機スクロール入力を優先して`.nonactivatingPanel`は撤回した。

```text
SceneShelfPresentationTestRunner: 4 tests passed
```

AppDelegateは専用`SceneShelfPanel`を使用し、表示時は`makeKeyAndOrderFront(nil)`へ切り替えた。実機でのTextField再編集と他アプリへのfocus復帰は、この証拠作成時点では未再確認である。

## D2: 全失敗理由のRed/Green

実機で、Mainが`ambiguousMatch`、Secondaryが`windowMissing`となる全失敗時に、保存カード上の理由が省略される不具合が確認された。修正前の公開formatterは旧来の横連結を返したため、対象順の改行全文を期待する実assertionがRedになった。

```text
PASS: menu bar shelf keeps a borderless panel
PASS: menu bar shelf keeps the nonactivating panel behavior
PASS: shelf panel must accept key focus for TextField editing
PASS: shelf panel must remain an accessory panel, not a main window
FAIL: failure reasons keep target order and use one line per target
SceneShelfPresentationTestRunner: 1 failures
```

`SceneFailureMessageFormatter`を改行区切りへ変更し、AppDelegateのprivate重複を削除、保存カードの`.lineLimit(2)`を外して`fixedSize(horizontal: false, vertical: true)`を適用した。修正後は以下がGreenになった。

```text
PASS: failure reasons keep target order and use one line per target
SceneShelfPresentationTestRunner: 5 tests passed
```

tooltipや詳細画面は追加クリックが必要なため採用していない。実機での全失敗カードの折返し・高さは未再確認である。

## D3: 保存済み一覧スクロールのRed/Green

実機で、保存後に保存済み一覧がShelfの上方へ追加されるが、ShelfViewをスクロールできず到達不能になる不具合が確認された。修正前のcontainerはviewport高さを明示せず、NSPanel + NSHostingViewで長いcontentをlayoutしたときdocument heightが0となった。

```text
PASS: scroll viewport stays within the 620 point panel height
FAIL: long shelf content is taller than its scroll viewport
SceneShelfPresentationTestRunner: 1 failures
```

`SceneShelfLayout`の360×620契約と`ShelfScrollContainer`を追加し、ShelfViewとNSPanelで共有した。修正後はNSPanel + NSHostingViewの長いサンプルでviewport 620、document 2236を観測し、以下がGreenになった。

```text
PASS: scroll viewport stays within the 620 point panel height
PASS: long shelf content is taller than its scroll viewport
SceneShelfPresentationTestRunner: 6 tests passed
```

別画面化は採用していない。実機で保存後にホイール・トラックパッド等で一覧末尾へ到達するGUI確認は未実施である。

## D10: activating panelによるスクロール入力のRed/Green

D3で360×620のviewportと長いdocumentを作っても、ユーザー実機ではShelfViewをスクロールできない事象が残った。D1の`borderless` + `nonactivatingPanel`を原因候補として、まずPresentation runnerへactivation契約と操作後の外部観測を追加した。

修正前は`SceneShelfPanel`が`.nonactivatingPanel`を保持していた。長い`ShelfScrollContainer`をNSPanel + NSHostingViewへ載せ、scroll operation後の`documentVisibleRect.minY`を観測したところ、位置変化の検証自体は通ったが、activation契約2件がRedになった。

```text
PASS: menu bar shelf keeps a borderless panel
FAIL: menu bar shelf uses an activating panel for direct interaction
PASS: shelf panel must accept key focus for TextField editing
PASS: shelf panel must remain an accessory panel, not a main window
PASS: failure reasons keep target order and use one line per target
PASS: scroll viewport stays within the 620 point panel height
PASS: long shelf content is taller than its scroll viewport
FAIL: shelf panel must be activating so scroll input reaches its content
PASS: scroll operation changes the visible scroll position
SceneShelfPresentationTestRunner: 2 failures
```

`SceneShelfPanel`のstyleMaskから`.nonactivatingPanel`だけを外し、`.borderless`、`canBecomeKey == true`、`canBecomeMain == false`、`makeKeyAndOrderFront(nil)`、status item/accessory起動を維持した。修正後は以下がGreenになった。

```text
PASS: menu bar shelf keeps a borderless panel
PASS: menu bar shelf uses an activating panel for direct interaction
PASS: shelf panel must accept key focus for TextField editing
PASS: shelf panel must remain an accessory panel, not a main window
PASS: failure reasons keep target order and use one line per target
PASS: scroll viewport stays within the 620 point panel height
PASS: long shelf content is taller than its scroll viewport
PASS: shelf panel must be activating so scroll input reaches its content
PASS: scroll operation changes the visible scroll position
SceneShelfPresentationTestRunner: 7 tests passed
```

このrunnerは実機のNSEvent/ホイール・トラックパッドそのものを代替しない。D10の自動検証はPASSしたが、ユーザー実機では保存後ShelfViewのスクロールが全く動かないFAILだった。D11でapplication activationを追加し、real GUI再確認を残す。

D11コードの最終自動検証は、リポジトリ内scratch/module cacheとSwift 6 strict concurrencyで行った。

```text
swift build --disable-sandbox --scratch-path .build-d11-verify/spm -Xswiftc -strict-concurrency=complete: PASS
swift test --disable-sandbox --scratch-path .build-d11-verify/spm -Xswiftc -strict-concurrency=complete: PASS
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 10 tests passed
SceneShelfRoundTripTestRunner: 8 tests passed
SceneShelfP0FourTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 8 tests passed
```

## D11: accessory application activationのRed/Green

D10で`.nonactivatingPanel`を外した最新buildをユーザー実機で再確認したが、ShelfViewは全くスクロールしなかった。一方、ボタンと配置名TextFieldは反応していたため透明背景は変更せず、status item accessory application自体が非activeなままという残存仮説を採用した。

まず本物の`NSApp.activate`と`showShelf()`をrunnerから呼び、`NSApp.isActive`/`panel.isKeyWindow`を観測するRedを取得した。

```text
FAIL: showShelf activates the accessory application
FAIL: showShelf makes the shelf panel key
SceneShelfPresentationTestRunner: 2 failures
```

本物のNSApp/run loopをrunner内で起動する案は、CLT/WindowServer環境でrunnerが常駐して短時間に終了しないため採用しなかった。代わりに`SceneShelfPanel`へ小さな`ApplicationActivator` collaboratorを注入し、production既定値を`NSApp.activate(ignoringOtherApps: true)`とした。`showShelf()`はactivation collaborator→`makeKeyAndOrderFront(nil)`の順に実行する。runnerは本物のNSAppを呼ばず、collaboratorの呼出し回数0→1とshowShelf後の`panel.isVisible`を外部観測する。

```text
PASS: activation collaborator starts untouched
PASS: showShelf activates the accessory application before presentation
PASS: showShelf presents the keyable shelf panel
SceneShelfPresentationTestRunner: 8 tests passed
```

D11 runnerはrun-loopなしで短時間終了する。`NSApp.isActive`、実機のkey window状態、ホイール/トラックパッド入力の復旧はreal GUIで再確認していない。

## 安全境界と観測結果

| 観点 | 自動検証結果 |
|---|---|
| 同一bundleの一意一致 | Main/Secondaryから保存対象Mainだけを`matched`としてwrite planへ渡した |
| same title/identifier duplicate | `ambiguousMatch`、write instruction 0 |
| PID reuse | `pidReused`、write instruction 0 |
| missing + success | missingをpreflight failureへ保持し、success対象の3操作を継続、`一部復元` |
| 全失敗 | `失敗`、`currentSceneID=nil`、write 0 |
| 表示→全退避成功 | `表示中`から`しまい済み`へ遷移し、`currentSceneID=nil` |
| 互換bool executorの失敗 | state、`currentSceneID`、対象reportを失敗前へ復元 |
| 全失敗理由の表示 | Main ambiguous + Secondary missingを対象順の2行で全文表示 |
| 保存済み一覧の到達性 | 360×620 viewport内でdocument heightがviewportを超え、縦スクロール範囲を持つ。activating panelでscroll operation後の`documentVisibleRect.minY`変化を確認 |
| panel入力経路 | `.nonactivatingPanel`を外したactivating key panelで、scroll operation後の`documentVisibleRect.minY`変化を観測 |
| application activation | production既定collaboratorが`NSApp.activate(ignoringOtherApps: true)`を呼び、runnerでactivation→panel visibleを観測 |
| 対象別失敗 | 後続対象を評価し、titleと日本語理由を保持 |
| retry | `partiallyRestored`/`failed`の次クリックはdisplay planを再試行 |
| Secondary除外 | scene/write planにSecondaryを含めず、write count 0（Secondary分） |

UIは保存済みカードへ「一部復元」「失敗」と対象title＋日本語failure labelを改行で全件表示し、raw enum名は表示しない。ShelfViewはPresentation層の360×620 `ShelfScrollContainer`を利用する。P0-4用Fixtureには、same title/identifierのMain duplicateを表示/閉じるボタンと、Secondaryを閉じる/再表示するボタンを追加した。Scene Shelf本体は`.nonactivatingPanel`を持たない専用keyable borderless accessory panelで、表示前にaccessory applicationをactivateする。これはmanual確認用の可逆操作であり、強制終了は実装していない。

## 未実施・残課題

- Scene Shelf UIからP0-4 fixture操作を実行するreal AX manual/integration。
- duplicate Mainの実AX曖昧停止、PID再利用の実プロセス入替え、部分成功の実window観測。
- P0-4の実操作に伴うAccessibility再許可/TCC状態の確認。
- 実機で配置名TextFieldを再編集し、表示後のfocus復帰を確認するGUI受入れ。
- 実機で保存後のShelfViewを末尾まで縦スクロールし、保存済み一覧・失敗理由へ到達するGUI受入れ。
- D11 build再登録後にapplication active/key panel化が実機で成立し、D10のスクロールFAILが解消することの再確認。
- disk persistence、任意アプリ、複数display、強制終了、完成形scene CRUD。
