# DR-008: 対象別失敗理由は順序付き改行で全件表示する

日付: 2026-09-25
対象: Scene Shelf / P0-4 failure message format
関連: GitHub Issue #1 Plan revision 1、`Sources/SceneShelfPresentation/SceneFailureMessageFormatter.swift`

## 目的

全失敗・部分失敗時に、ユーザーが次に確認・再試行すべき対象と理由を判断できるよう、登録対象ごとの失敗理由を省略せず保存カードへ表示する。

## 制約・確認済み事実

- 実機で全失敗時の理由が、保存カード上で省略される不具合が確認された。
- 既存formatterは対象を`" / "`で連結し、UI側に`.lineLimit(2)`があった。
- D2では対象順を保持した改行区切りを採用し、tooltipや詳細画面はクリック追加となるため今回のスコープ外とする。
- CLT環境ではXCTest/Swift Testingを使わず、Presentation runnerの実assertionを使う。

## 決定

1. `SceneShelfPresentation`に`SceneFailureMessageFormatter`を置き、`SceneRestoreReport.failedOutcomes`を対象順のまま`title: 日本語理由`へ変換する。
2. 区切りは改行（`\n`）とし、UIの保存カードから`.lineLimit(2)`を外して`fixedSize(horizontal: false, vertical: true)`で全件を縦表示する。
3. AppDelegateのprivate formatterは削除し、公開formatterを保存カードとaccessibility messageで共用する。

## Why

- 対象順を保持した改行なら、MainとSecondaryのどちらを先に確認するかをユーザーが読み取れる。
- line limitを撤去して縦方向へ伸ばすことで、失敗対象の情報を省略せず同じカード内で確認できる。
- Presentation libraryに置くことで、SwiftUIの表示制約とCoreのreport形式をAppDelegateから分離し、実行可能runnerで全文formatを検証できる。

## Why not

- `" / "`連結は横幅と行数に依存して対象理由を隠すため採用しない。
- `.lineLimit(2)`維持は3件以上や長い理由を省略するため採用しない。
- tooltipや詳細画面は追加クリックを要求し、今回の「次アクションをカード上で判断する」目的を満たさないため採用しない。
- formatterをAppDelegate privateに残す方式は、UI以外の検証境界を持てず、重複実装を温存するため採用しない。

## 帰結

- Main ambiguous + Secondary missingは、対象順の2行全文として表示される。
- 対象数に比例してカードの高さが伸びるため、ScrollViewの既存境界に依存する。
- 実機の文字折返し・カード高さはGUI再確認が必要であり、runner PASSだけでreal AX/GUI受入れPASSとはしない。

## 再検討条件

- 多数対象でカード高さや視認性に問題が出た場合、tooltipではなく同一カード内の折りたたみ表示を別判断する。
- ユーザーが対象別再試行を要件化した場合、詳細画面や対象単位操作を別DRで設計する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: Main ambiguous + Secondary missingの順序付き改行全文format。
- `docs/phase0/evidence/P0-4-multi-window.md`: D2 Red/Greenと実機GUI再確認の境界。
