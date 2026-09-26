# DR-011: Shelf表示前にaccessory applicationを明示activateする

日付: 2026-09-25
対象: Scene Shelf / D11 application activation
関連: GitHub Issue #1 Plan revision 1、`DR-010-activating-shelf-panel-scroll-input.md`、`Sources/SceneShelfPresentation/ShelfPanel.swift`

## 目的

status itemから開いたScene Shelfが非activeなまま残り、ボタンやTextFieldは反応するがスクロール入力が届かない実機不具合を解消する。表示時にScene Shelf applicationをactiveにし、その後key panelを前面化する。

## 制約・確認済み事実

- D10で`.nonactivatingPanel`を外しても、ユーザー実機ではShelfViewが全くスクロールしないFAILが報告された。
- ユーザー確認ではボタンとTextField入力は反応しており、透明背景を原因とする変更は行わない。
- Scene Shelfは`NSApplication` accessory policyとstatus itemを維持し、通常window化・複数display・fixture変更は行わない。
- 最低サポートmacOSはPackage.swiftのmacOS 14であり、`NSApp.activate(ignoringOtherApps: true)`はこの境界で利用できる。
- CLT runnerで本物の`NSApp.activate`/`showShelf`とrun loopを起動するとrunner常駐となるため、実runnerはactivation collaboratorとpanelの外部状態を観測し、real GUIを代替しない。

## 決定

1. `SceneShelfPanel`のinitializerに小さな`ApplicationActivator` collaboratorを追加する。
2. productionの既定collaboratorは`NSApp.activate(ignoringOtherApps: true)`とする。
3. `showShelf()`はcollaboratorを呼び出した後、既存の`makeKeyAndOrderFront(nil)`を呼ぶ。
4. runnerはcollaborator呼出し回数が0→1へ変化し、showShelf後にpanelがvisibleになることを検証する。run loopや本物のNSApp activationはrunnerから呼ばない。

## Why

- accessory applicationが非activeなままだと、keyable panelとScrollViewの構造が正しくても実ユーザー入力が届かない可能性がある。表示時にapplication activationを先行させることで、D10の残存仮説に直接対応する。
- `NSApp.activate(ignoringOtherApps: true)`はmacOS 14のAppKit APIで、status item/accessoryを通常windowへ変えずにアプリの入力先を明示できる。
- collaboratorを小さく注入すると、CLT runnerがWindowServer/run loopに依存せず、activation→presentationの呼出し順と表示後のpanel状態を外部観測できる。

## Why not

- 実runnerで`NSApp.activate`と`application.run()`を呼ぶ方式は、CLT/WindowServer環境で接続待ちや常駐となり、決定的な自動検証にならないため採用しない。
- activationをAppDelegate全体やグローバル状態へ広げる方式は、SceneShelfPanelの表示責務を越えてテスト境界を広げるため採用しない。
- 透明背景、通常window化、`hidesOnDeactivate`、event monitorの追加は、ボタン/TextFieldが反応している現時点の事実とD11の仮説を越えるため保留する。
- `NSRunningApplication.current.activate(options:)`へ置き換える方式は、今回の最小変更では`NSApp`のaccessory application契約を直接activateする方が明確なため採用しない。

## 帰結

- `showShelf()`は常にapplication activation要求を先に出してからkey panelを前面化する。
- runnerはPresentationの8件目としてactivation collaborator、panel visibilityを検証し、run-loopなしで終了する。
- 実機でD11後にスクロールが復旧したか、他アプリへのfocus復帰やTextField再編集に副作用がないかは、別途real GUIで再確認する。

## 再検討条件

- D11 buildを再登録しても実機スクロールが失敗する場合、first responder、ScrollViewへのevent routing、`makeKeyAndOrderFront`後のfocus、accessory policyを実機ログで調査する。
- 他アプリを強制的に非activeにする副作用が確認された場合、activation optionsや表示タイミングを再設計する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: activation collaboratorの0→1、showShelf後のpanel visibility、既存panel/scroll契約。
- `docs/phase0/evidence/P0-4-multi-window.md`: D10実機FAIL、D11 Red/Green、real GUI再確認の境界。
