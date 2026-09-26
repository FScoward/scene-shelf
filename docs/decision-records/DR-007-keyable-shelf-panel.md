# DR-007: Scene Shelfはkeyableなaccessory panelでTextField入力を受ける

日付: 2026-09-25
対象: Scene Shelf / 実機入力不具合修正
関連: GitHub Issue #1 Plan revision 1、`Sources/SceneShelfPresentation/ShelfPanel.swift`

## 目的

メニューバーから表示するScene Shelfの配置名TextFieldをクリック編集できるようにし、既存のaccessoryアプリ・非通常windowの見た目と配置を維持する。

## 制約・確認済み事実

- ユーザー実機で、配置名TextFieldを編集できない不具合が確認された。
- 既存panelは`borderless` + `nonactivatingPanel`で、表示時に`orderFrontRegardless()`を呼んでいた。
- Scene Shelfは`NSApplication.setActivationPolicy(.accessory)`とstatus itemから起動する契約であり、通常window化・固定名化は行わない。
- CLT環境ではXCTest/Swift Testingを使わず、実行可能runnerでpanelの公開契約を検証する。

## 決定

1. `SceneShelfPresentation` libraryに専用`SceneShelfPanel` subclassを置く。
2. `canBecomeKey`を`true`、`canBecomeMain`を`false`として、TextField入力のキー受け入れとaccessory panel境界を型で固定する。
3. `showShelf()`は`makeKeyAndOrderFront(nil)`を使い、AppDelegateは専用panelを生成してこの表示APIを呼ぶ。
4. `borderless`と`nonactivatingPanel`、現在のstatus item/accessory起動、panel幅・配置計算は維持する。

## Why

- TextField編集にはpanelがkey windowになれる必要があり、`canBecomeKey`と`makeKeyAndOrderFront`を同じpresentation境界へ集約すると、表示経路の取りこぼしを防げる。
- `canBecomeMain == false`を明示することで、入力を受けるための最小変更に留め、通常アプリwindowへ変質させない。
- library化するとAppDelegateのAX/scene責務とpanelのAppKit入力責務を分離し、CLT runnerでRed/Greenを再現できる。

## Why not

- `orderFrontRegardless()`を残す方式はkey window化を保証せず、今回の実機不具合を再発させるため採用しない。
- panelから`nonactivatingPanel`を外す方式は、メニューバーaccessoryの既存挙動と見た目を変えるため採用しない。
- 通常`NSWindow`やapplication activationへ切り替える方式は、status item中心の契約とユーザーの表示体験を変更するため採用しない。
- AppDelegate内にoverrideを直接埋め込む方式は、実行可能なpresentation単体検証ができず、責務境界を曖昧にするため採用しない。

## 帰結

- `SceneShelfPresentationTestRunner`で、修正前の`canBecomeKey == false`をRedとして再現し、修正後にkeyable・非main・既存styleをGreen検証できる。
- 実機のTextField再編集は本作業の自動runnerでは代替できないため、GUI再確認を残課題として記録する。
- panel表示はkey化するため、他アプリの入力フォーカスやactivationの挙動は実機で確認する必要がある。

## 再検討条件

- 実機再確認でTextField入力またはaccessory挙動に問題が残る場合、`hidesOnDeactivate`、event monitor、first responderの設定を追加調査する。
- 通常windowとしてのscene管理を要件化する場合は、accessory panel契約とは別のDRで表示モデルを設計する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: D1時点のborderless/nonactivating、keyable、非mainの4件。現在のactivation/scroll契約はD10で更新。
- `docs/phase0/evidence/P0-4-multi-window.md`: 実機報告、Presentation runner Red/Green、real GUI再確認の境界。

## D10による更新（2026-09-25）

実機でShelfViewのスクロール入力が届かない事象が残ったため、D1の`.nonactivatingPanel`維持判断は`DR-010-activating-shelf-panel-scroll-input.md`で撤回した。現在の実装は`.borderless`のみをstyleMaskに指定し、keyable・非main・`makeKeyAndOrderFront(nil)`とaccessory起動契約を維持する。D1のTextField入力境界は継続し、D10ではscroll operation後の`documentVisibleRect.minY`変化を追加検証する。
