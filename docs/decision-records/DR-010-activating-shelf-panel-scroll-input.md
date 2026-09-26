# DR-010: Scene Shelfはactivatingなkey panelとしてスクロール入力を受ける

日付: 2026-09-25
対象: Scene Shelf / D10 scroll input routing
関連: GitHub Issue #1 Plan revision 1、`DR-007-keyable-shelf-panel.md`、`DR-009-shelf-scroll-viewport.md`、`Sources/SceneShelfPresentation/ShelfPanel.swift`

## 目的

実機で保存済み一覧を含む長いShelfViewを表示したとき、パネルがスクロール入力を受け、固定viewport内で一覧末尾へ到達できるようにする。

## 制約・確認済み事実

- D3で360×620のviewportと縦ScrollViewを導入した後も、ユーザー実機ではShelfViewをスクロールできない不具合が残った。
- `SceneShelfPanel`は`borderless` + `nonactivatingPanel`で、`canBecomeKey`を`true`にしてもnonactivatingの入力経路制約が残っていた。
- メニューバーstatus itemと`NSApplication`のaccessory契約、borderlessの見た目、非main window契約は維持する。
- CLT環境ではXCTest/Swift Testingを使わず、NSPanel + NSHostingViewの実assertion runnerでlayout後の外部状態を観測する。

## 決定

1. `SceneShelfPanel`のstyleMaskから`.nonactivatingPanel`を外し、`.borderless`だけを保持する。
2. `canBecomeKey == true`、`canBecomeMain == false`、`makeKeyAndOrderFront(nil)`は維持し、操作中はkey panelとして入力を受ける。
3. `SceneShelfPresentationTestRunner`で長い`ShelfScrollContainer`を`SceneShelfPanel`へ載せ、scroll operation後に`documentVisibleRect.minY`が変化することを外部観測する。
4. 実機のホイール・トラックパッド入力はrunnerの代替ではないため、real GUI確認は未実施として残す。

## Why

- D3のcontent高さ・viewport高さが正しくても、panelがnonactivatingのままならユーザー入力がScrollViewへ到達しないため、原因候補の制約を最小のstyleMask変更で除去する。
- `documentVisibleRect.minY`の変化をNSPanel + NSHostingViewのlayout後に観測すると、単なるdocument heightの構造検査ではなく、スクロール操作が可視位置へ反映されたことを確認できる。
- keyable・非main・borderlessを型とrunnerで維持することで、TextField編集のD1契約とメニューバーaccessoryの外観を同時に守る。

## Why not

- `.nonactivatingPanel`を残したまま`NSScrollView`やSwiftUI側だけを調整する方式は、D3と同じ入力経路制約を残すため採用しない。
- 通常`NSWindow`化やアプリ全体のactivationは、status item中心のaccessory契約と他アプリへのfocus境界を変更するため採用しない。
- panelの可変高化・別画面化は、保存済み一覧を同一Shelf内でクリック切替する要件とD3の360×620契約を変更するため採用しない。
- runnerで実機のNSEvent/trackpadを完全再現することはできないため、real GUIを自動PASSとは扱わない。

## 帰結

- SceneShelfPanelはkey入力とスクロール操作を受けるactivating borderless accessory panelになる。
- Presentation runnerはD3のviewport/document検査に加えて、scroll operation後の`documentVisibleRect.minY`変化を検証する。
- panelがkeyになるため、他アプリへのfocus復帰、TextField再編集、実機のホイール・トラックパッド到達性はユーザーGUIで再確認する必要がある。

## 再検討条件

- 実機でscroll inputがなお無視される場合、first responder、SwiftUI/NSScrollViewへのevent routing、panel表示時のrun loopを追加調査する。
- accessoryを非活性のまま操作したいという要件が明確になった場合は、status itemからの一時activationや別入力モデルを新しいDRで再設計する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: activating style、keyable・非main、長いcontent、scroll operation後のvisibleRect変化を実assertion。
- `docs/phase0/evidence/P0-4-multi-window.md`: D10 Red/Green、bundle検証、real GUI未実施境界。

## D11による更新（2026-09-25）

D10の`.nonactivatingPanel`除去後もユーザー実機ではスクロールが全く動かないFAILとなった。ボタンとTextFieldは反応しており透明背景は変更せず、残存仮説であるstatus item accessory applicationの非active状態へ`DR-011-activate-accessory-before-show.md`で対応した。productionの`showShelf()`は`NSApp.activate(ignoringOtherApps: true)`を先に実行し、その後`makeKeyAndOrderFront(nil)`を呼ぶ。CLT runnerでは本物のNSApp/run loopを呼ばず、activation collaboratorの呼出しとpanel visibilityを観測する。
