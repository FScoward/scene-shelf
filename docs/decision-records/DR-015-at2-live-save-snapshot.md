# DR-015: AT-2 save-time live snapshot

## Metadata

- Phase: Phase 1 / AT-2 persistence capture correction
- Kind: 通常判断（Decision D15）
- Spec: GitHub Issue #1 AT-2 / `design.md` persistence capture boundary
- Related: `test-matrix.md` AT-2 section、P1-1 evidence、`SceneShelfAccessibility`
- Reversible: code and local evidence only; no external OS or remote state is changed

## Purpose

保存ボタンを押した時点のFixture配置を保存し、検出時に保持していた古いframeを保存しない。検出後にユーザーがwindowを移動・resizeした場合も、保存結果は保存操作時のlive snapshotと一致させる。

## Constraints and facts

- `ShelfViewModel.saveFixtureScene()`は従来、`detectFixture()`が保持した`fixtureWindows`をそのまま`SceneCaptureFlow`へ渡していた。
- `selectedFixtureIDs`は検出時にユーザーが選択したidentity集合であり、保存時に対象を追加・除外してはならない。
- Accessibility adapterはraw AX参照を返さず、`AXWindowSnapshot`のSendable値だけを返す。
- selected identityが保存時live snapshotから欠落、曖昧、またはframe nilの場合は、検出時の古いframeへfallbackせず保存を中止する。

## Decision

`SceneShelfAccessibility`に`AXSceneCapturePreparation`を追加する。`prepare(adapter:selectedIDs:)`は保存ボタン押下後に`adapter.fixtureWindows()`を一度再取得し、selected identityをlive候補へ照合する。各selected identityは一意に存在し、frameがnon-nilであることを検証する。検証成功時は全live候補と検出時に選択されたselected identity集合を返し、ViewModelが既存の`SceneWindowSnapshot`変換と`SceneCaptureFlow`へ渡す。

欠落・曖昧・frame nilは`AXSceneCaptureError`として日本語labelを持つ失敗にする。ViewModelはこのエラーを表示して保存を開始しない。未選択候補は全live候補に残すが、selected identity集合は変更しないため、既存の選択除外契約を維持する。

## Why

- 保存操作の直前にlive値を取得するため、検出時B座標を保存時A座標へ更新できる。
- Accessibility library内のpureな値型境界とadapter overloadを使うため、raw AX参照をUIへ漏らさず、candidate sequence mockで検出→移動→保存を実行可能に検証できる。
- validationを`SceneCaptureFlow`の前段へ置くことで、selected frame nilを`compactMap`で黙って除外せず、保存失敗として明示できる。

## Why not

- ViewModelの`fixtureWindows`を再検出で上書きしてから既存save処理を使う方式は、検出UIのstateと保存transactionの入力を同じmutable配列へ依存させ、選択集合との時系列境界を不明確にするため不採用。
- 検出時snapshotを保存し、後からoverwriteで補正する方式は、AT-2の保存時配置契約を満たさず、誤ったrevisionを一度公開するため不採用。

## Consequences and risks

- 保存操作ごとにAX inspectionが1回増える。これはframeの正確性とstale fallback防止を優先するため受け入れる。
- 保存時に対象が閉じられた場合は保存されず、日本語理由をユーザーへ示す。検出一覧の表示は自動更新せず、次回detectで明示的に更新する。
- 実macOS AX環境での実移動・保存・再起動復元は自動runnerの証明範囲外であり、manual境界に残る。

## Reconsideration conditions

- AX inspection costが計測で問題になった場合、保存操作中のsnapshot cacheとidentity/version契約を別途設計する。
- 任意アプリ対応へ拡張する場合、Fixture固定のidentity validationと対象選択モデルを再評価する。

## Related executable tests

- `SceneShelfAXTestRunner`: 検出B座標→保存時A座標、selected missing、frame nil、selection exclusion
- `SceneShelfRoundTripTestRunner`、`SceneShelfPersistenceTestRunner`: existing capture/persistence contracts
