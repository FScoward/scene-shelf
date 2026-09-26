# DR-016: saved scene primary card hit area

## Metadata

- Phase: Phase 1 / saved scene card UX correction
- Kind: 通常判断（Decision D16）
- Spec: saved scene card click-area manual finding / AT-3 card interaction
- Related: `SceneShelfPresentation`、P1-3 evidence、test-matrix UX section
- Reversible: code and local evidence only; no external OS or remote state is changed

## Purpose

保存済み配置カードの視覚領域全体をクリック可能にし、ユーザーがカードの余白をクリックしても表示／退避を実行できるようにする。管理用「…」Menuの操作領域は独立して維持する。

## Constraints and facts

- 現状のsaved scene cardはButton labelにpadding/frameを持つが、透明な余白のhit shapeが明示されていない。
- 「…」Menuはrename/overwrite/duplicate/reorder/deleteの独立入口であり、カード本体のgestureで操作を奪ってはならない。
- macOSの操作高さは最低44pt相当を維持する。
- 実UIのNSHostingView/hitTest境界をCLIで検証し、real GUI操作はmanual境界として分ける。

## Decision

`SceneShelfPresentation`にsaved scene primary label用の小さなView componentを追加し、Button labelへ適用する。componentは視覚的paddingを含む`frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)`の後に`contentShape(Rectangle())`を適用する。AppDelegateの外側HStackには`onTapGesture`を追加せず、Menuは兄弟viewとして残す。

## Why

- Button自身のlabel hit shapeを拡張するため、カード主要部のクリック責務をButton内に保てる。
- component境界をPresentation targetへ置くことで、AppDelegateのデータ／操作ロジックと分離し、NSHostingViewのhitTestと最低高さを実行可能テストにできる。
- Menuを兄弟viewに残すため、管理操作のクリック経路とカード表示／退避経路が衝突しない。

## Why not

- 外側HStackへ`onTapGesture`を付ける方式は、Menuのイベント伝播を親gestureが奪うリスクがあり、Buttonのアクセシビリティ意味も二重化するため不採用。
- 透明な背景色だけに依存する方式はhit shapeを保証せず、今回の実機報告を再発させるため不採用。

## Consequences and risks

- 保存カード主要部の操作領域が広がり、余白クリックが表示／退避として解釈される。
- Menu領域はカード主要部と別Buttonのままなので、Menu項目の操作契約を維持する。
- NSHostingViewのCLI hitTestは実AppKit event routing全体を証明しないため、実機クリックはmanual境界に残る。

## Reconsideration conditions

- Menuの実機操作が主要部Buttonへ誤伝播する場合、AppKit event traceを取得してlabel/frame境界を再評価する。
- 44ptを超えるOSアクセシビリティ推奨値が新たに適用される場合、componentのminimum heightを再検討する。

## Related executable tests

- `SceneShelfPresentationTestRunner`: primary card hitTest、44pt minimum height、Menu兄弟領域

## Manual acceptance update（2026-09-26 JST）

修正版relaunch後、ユーザーが保存カード「検証A」の文字ではなく管理用「…」の手前の右側空白をclickし、表示／退避が反応することを確認した。「いい感じ」との確認を得たため、カード主要部全面hit areaをmanual PASSとした。Menu項目操作とVoiceOverは未確認である。
