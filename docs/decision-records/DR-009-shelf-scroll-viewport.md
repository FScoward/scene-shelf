# DR-009: ShelfはPresentation契約のviewportで縦スクロールする

日付: 2026-09-25
対象: Scene Shelf / P0-4 scroll reachability
関連: GitHub Issue #1 Plan revision 1、`Sources/SceneShelfPresentation/ShelfScrollContainer.swift`

## 目的

保存後に増える保存済み一覧や失敗理由まで、固定サイズのScene Shelfパネル内からユーザーが縦スクロールで到達できるようにする。

## 制約・確認済み事実

- 実機で保存後の保存済み一覧がShelfの上方へ追加される一方、ShelfViewをスクロールできず到達不能になる不具合が確認された。
- Scene Shelfはメニューバーaccessory panelで、表示領域は幅360、高さ620を維持する。
- 別画面化はクリック導線とaccessory panelの契約を変えるため採用しない。
- CLT環境ではXCTest/Swift Testingを使わず、NSPanel + NSHostingViewの実assertion runnerを使う。

## 決定

1. `SceneShelfPresentation`に`SceneShelfLayout`（360×620）と`ShelfScrollContainer`を置く。
2. container外側を幅360・高さ620へ固定し、長いcontentを同じviewport内のvertical ScrollViewへ配置する。
3. `ShelfView`はcontainerを利用し、NSPanelのcontentRectも同じlayout契約から生成する。
4. 長いサンプル内容をNSHostingView + NSPanelへlayoutし、viewport高が620以内かつdocument高がviewportを超えることをrunnerで検証する。

## Why

- viewportとpanel寸法をPresentation層で共有すると、SwiftUIのScrollViewがcontentのintrinsic heightへ引き伸ばされる経路を抑え、表示範囲とスクロール範囲を分離できる。
- 実際のNSPanelへNSHostingViewを載せるテストなら、単なる定数検査ではなくAppKit layout後のdocument heightを観測できる。
- 既存のクリック中心導線と同一panelを維持するため、保存後の一覧にも追加操作を要求しない。

## Why not

- 別画面・シート化は一覧到達性を得る代わりに、メニューバーからの既存導線とpanel契約を変更するため採用しない。
- panelをcontentに合わせて可変高にする方式は、表示位置と画面占有を不安定にし、固定viewportの目的を失うため採用しない。
- AppDelegateだけで高さを個別指定する方式は、SwiftUI側のScrollViewと寸法がずれるため採用しない。

## 帰結

- 長い一覧は360×620のviewport内で縦スクロールでき、保存済みカード・失敗理由へ到達できる。
- contentが長いほどdocument heightが増え、ScrollViewの内部スクロール範囲に依存する。
- 実機でのホイール・トラックパッド・VoiceOverスクロールはrunnerでは代替できず、GUI再確認を残す。

## 再検討条件

- 実機でスクロール入力が無視される場合、first responderやevent routingを追加調査する。
- 保存対象数が増えて360×620で視認性が不足する場合、別画面化を新しい要件・DRとして再検討する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: NSPanel + NSHostingViewの長いcontentでviewport/document高を検証。
- `docs/phase0/evidence/P0-4-multi-window.md`: D3 Red/Greenとreal GUI再確認の境界。
