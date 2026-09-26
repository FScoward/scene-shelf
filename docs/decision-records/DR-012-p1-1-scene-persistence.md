# DR-012: P1-1はindexをcommit pointとするローカルscene persistenceを採用する

日付: 2026-09-26
対象: Scene Shelf / P1-1 create/reload persistence
関連: GitHub Issue #1 Plan revision 1、`design.md` 7.1〜7.4

## 目的

アプリ再起動後もSavedSceneのID・名前・表示順・全window dataを復元し、壊れた保存データによる上書きや他sceneの巻き添えを防ぐ。

## 制約・確認済み事実

- P1-1のスコープはsceneのcreate/reloadであり、rename/order/deleteの専用操作は後続スコープである。
- `SavedScene`と`SceneWindowSnapshot`は既にCodable値型で、AX生参照を含まない。
- SwiftPM/CLT環境では専用runnerが実assertion境界であり、Swift 6 strict concurrencyを有効にする。
- 設計7.2はrevision先行、index最後のatomic commitを要求する。

## 決定

1. `Application Support/SceneShelf/index.json`にschema version、scene ID、current revision、名前、表示順を保存する。
2. window dataは`scenes/<scene-id>-<revision>.json`へ保存し、revisionファイルは一度公開したら上書きしない。
3. 同一ディレクトリのtempへwrite→file fsync→`renameatx_np`→destination fsync→directory fsyncを行う。revisionは`RENAME_EXCL`、indexはreplaceを使い分ける。
4. revisionをatomicに公開してからindexをatomicに公開する。indexのdecode失敗・未知version・不正参照はfail closedとし、保存を拒否する。
5. 個別revisionの欠落・破損・未知versionは当該sceneだけをdiagnostic付きで除外し、元index entryは保持して他sceneを読み込む。元ファイルは移動・上書きしない。
6. production `ShelfViewModel`の既定storeだけをApplication Supportへ接続し、取得失敗時は初期化エラーを保持して保存を拒否する。テスト注入された`InMemorySceneStore`は従来どおりdisk I/Oなしで動かす。

## Why

- indexを最後のcommit pointにすると、revision書込み途中の失敗で既存indexを空データへ置き換えずに済む。
- scene単位のrevision読込みを独立させると、一つの破損ファイルが健全なsceneの再表示を止めない。
- 壊れたrevisionのindex entryを保持すると、後続saveで参照を黙って落とさず、scene ID採番も壊れたentryと衝突しない。
- schema versionとsafe file componentを検証することで、未知形式を誤解釈せず、revision pathをscene IDから安全に導出できる。
- load後にscene IDの最大数値を次の番号へ進めるため、再起動後のcreateで既存IDを再利用しない。

## Why not

- 1つのJSONへ全sceneを保存する方式は、単一ファイル破損時に全sceneを失うため採用しない。
- indexを先に更新する方式は、参照先revisionが未公開の中間状態をcommit pointとしてしまうため採用しない。
- 破損revisionを自動削除・quarantineへ移動する方式は、P1-1の読み込み境界を越え、元データの調査可能性を損なうため採用しない。
- Application Supportをテストへ直結する方式は、実ユーザーデータとの干渉とテスト順序依存を生むため、rootURL注入を残す。
- Application Support取得失敗時にin-memoryへfallbackする方式は、ユーザーの保存要求をメモリ内成功と誤表示するため採用しない。

## 帰結

- 保存成功時はindexとrevisionが残り、UIは「ローカルに保存しました」と表示する。
- indexが壊れている間はloadもsaveも停止し、index bytesを変更しない。Application Support初期化失敗時も同じfail-closed境界を取る。
- 個別revisionのdiagnosticは返るが、P1-1では自動修復・孤児cleanup・scene CRUDは行わない。

## 再検討条件

- rename/order/deleteを実装するときはindex metadataだけのcommitと旧revision cleanupの契約を追加する。
- fsync失敗の実機再現やvolume差異が確認された場合は、Darwin POSIX境界とエラー分類を再評価する。
- schema version 2を導入するときはmigration方針と旧revision保持期間を別DRで決める。

## 関連テスト

- `Sources/SceneShelfPersistenceTestRunner/main.swift`: 12件のcreate/reload、順序、ID継続、index fail-closed、revision diagnostic後のentry保持/ID衝突回避、Application Support初期化失敗のload/save fail-closed、atomic artifact assertion。
- `Sources/SceneShelfCore/ScenePersistence.swift`: version検証、revision単位のdiagnostic、index/revision commit境界。
- `Sources/SceneShelf/AppDelegate.swift`: production Application Support接続、注入storeの互換、ローカル保存成功文言。
