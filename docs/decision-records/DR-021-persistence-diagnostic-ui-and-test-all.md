# DR-021: persistence diagnostics in UI and aggregated runner gate

## Metadata

- Phase: Phase 1 / persistence observability and quality gate
- Kind: 通常判断（Decision D21）
- Scope: per-scene persistence diagnostics, reload guidance, independent runner aggregation
- Related: `SceneShelfPersistence`, `ShelfViewModel`, `SceneShelfPresentation`, `scripts/test-all.sh`
- Reversible: local code/tests/docs only; no app launch or external state change

## Purpose

永続化の一部revisionが欠落・破損してカードから消えた場合でも、ユーザーが対象scene IDと日本語の理由を確認し、安全に再読込できるようにする。また、独立runnerの実行漏れをCI相当の一括検証で検出する。

## Constraints and facts

- `SceneShelfPersistence.load()`はindex entryごとに `ScenePersistenceDiagnostic` を返し、問題のあるsceneだけを `scenes` から除外する。
- 一覧全体のcorrupt/unsupported/invalid indexはscene単位の診断を生成できないため、対象を「一覧全体」として説明する必要がある。
- 保存診断は破損ファイルを自動削除・採用してはならず、再読込は読み込みを再試行するだけに限定する。
- 既存の独立runnerはSwiftPM productとして実行可能で、CLT環境では専用scratch/module-cacheと `--disable-sandbox` が必要である。

## Decision

1. `SceneShelfPresentation`に `SceneShelfPersistenceDiagnosticRow` と診断一覧Viewを追加し、各行へ対象scene ID・日本語理由・pathを投影する。
2. `ShelfViewModel`はload結果のdiagnosticsを保持し、正常カードとは独立した診断一覧へ渡す。読み込み失敗時はカードを消さず、一覧全体対象の安全な説明を表示する。
3. 診断一覧には「保存済み配置を再読込」ボタンを置く。再読込中のbusy拒否は既存診断を上書きせず、通常のactor busy契約を維持する。
4. `scripts/test-all.sh`は全独立runnerを専用cache/scratchでbuild後に順次実行し、全runnerを最後まで実行して失敗名を集約し、1件でも失敗すればexit 1とする。

## Why

- 診断をstatusの一行だけに集約すると、どのカードが消えたか分からず、破損が複数ある場合に原因を失う。カード一覧外の専用診断欄なら、欠落カード自体が描画できなくても対象sceneを確認できる。
- reloadを明示ボタンに限定すると、自動修復やファイル削除を伴わず、ユーザーが外部状態を直した後に安全に再試行できる。
- runnerを一括実行し、失敗後も残りを続行すると、最初の失敗だけで後続回帰を隠さず、CI相当の失敗一覧を得られる。

## Why not

- 破損revisionを自動削除・空sceneとしてカードへ戻す方式は、原因の証跡を失いデータを変更するため採用しない。
- diagnosticsを正常カードへ擬似カードとして混ぜる方式は、クリック・表示/退避・削除の対象と誤認されるため採用しない。
- 最初のrunner失敗で即終了する方式は、後続runnerの故障を同時に観測できないため採用しない。

## Consequences and risks

- 一覧に診断欄が常時表示されるため、保存カードがない場合でも安全説明と再読込操作が見える。
- pathを表示するが、破損ファイルの内容をUIへ展開せず、診断の対象と理由だけを明示する。
- `test-all.sh`はbuildを一度行うため単独runnerより時間がかかるが、実行漏れと失敗集約を防げる。

## Reconsideration conditions

- 診断をアプリ内の履歴画面へ移す要件、または復旧操作の承認契約が追加された場合は、再読込以外の導線を再検討する。
- SwiftPMまたはCIが専用cacheを標準提供し、runner product構成が変わった場合はscriptのrunner一覧とbuild方式を更新する。

## Related executable tests

- `SceneShelfPresentationTestRunner`: diagnostic rowのscene ID・日本語理由・一覧全体row、diagnostic viewのreload control boundary
- `scripts/test-all.sh`: Core / AX / RoundTrip / P0Four / Presentation / Persistence / Management / Switchingの8 runner集約実行
