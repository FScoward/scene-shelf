# DR-013: P1-2のscene管理はindex commitとactor後更新を共通境界にする

日付: 2026-09-26
対象: Scene Shelf / P1-2 scene management
関連: GitHub Issue #1 Plan revision 1、`design.md` 7.2〜7.4、DR-012

## 目的

保存済み配置を安全に整理できるよう、名前変更、現在の配置での上書き、複製、上下移動、削除を追加する。操作が失敗したとき、画面・actorのメモリ状態・indexのどれかだけが先に変わる中間状態を作らない。

## 制約・確認済み事実

- `index.json` はrevisionの参照とmetadataを確定するcommit pointであり、revisionはimmutableである（DR-012、設計7.2）。
- Sceneの表示・退避は同じactor内で直列化され、`preparing` / `displayed` / `partiallyRestored` は削除できない。
- overwriteで使える対象は、保存時のidentity集合とlive Fixture snapshotが一意に一致した対象だけである。対象の追加・除外UIはP1-2の範囲外とする。
- SwiftPM/CLTでは専用runnerが実assertion境界であり、Swift 6 strict concurrencyを有効にする。

## 決定

1. rename・reorder・deleteはrevisionを生成せず、index-only atomic commitを使う。
2. overwriteは同じscene IDの`current revision + 1`以上で、ディレクトリ上の同scene ID revisionファイルと衝突しない最初のrevisionへ新revisionを先に公開し、その後indexを更新する。対象identity集合は既存sceneから変えない。
3. duplicateは新しいscene ID・revision 1で保存し、名前を`<元名> のコピー`、状態を`stashed`にする。
4. すべての管理操作は、永続化成功後にだけactorのmemoryを更新し、続けてViewModelがUIをrefreshする。永続化失敗時はmemory/indexを変更しない。revisionだけが残るoverwrite失敗はDR-012のorphan契約に従う。
5. `isBusy` 中の管理操作は拒否する。deleteはUIの確認を通過した呼び出しだけを受け付け、`displayed`・`partiallyRestored`・`preparing` は「先にしまう」として拒否する。index commit後のrevision cleanupはbest-effortとし、失敗しても削除結果を取り消さない。
6. 保存カードには常時クリックできる明示的な`…` Menuを置く。renameはinline入力、deleteはconfirmation dialogとし、既存のカード本体クリックによる表示/退避は維持する。

## Why

- indexを最後にcommitしてからactorを更新すると、失敗した操作の結果をUIへ先に見せず、再起動後のdisk状態とも一致する。
- overwriteを新revisionに限定すると、直前の正常な配置を保持したままライブ状態を再取得でき、index commit失敗時に復旧可能なorphanとして残せる。
- index commit失敗で残ったorphan revisionを削除・自動採用せず、exact scene IDのファイル名だけを走査して次回採番からスキップすると、調査可能性と再試行可能性を両立できる。
- identityをmatcherで全件検証すると、PID再利用・曖昧一致・対象消失を「別のウィンドウを上書きする」成功として扱わない。
- index-only操作はrevisionを書き換えないため、名前や表示順の変更でwindow targetの履歴を増やさない。

## Why not

- 保存済みsceneを先にactorから消してからdiskを書き換える方式は、index commit失敗時にUIだけが消えるため採用しない。
- overwriteで現在検出できた対象だけを部分的に保存する方式は、対象identity集合を黙って変え、次回復元の意味を変えるため採用しない。
- context-clickだけの管理メニューは、クリックで切り替えるというUI方針とアクセシビリティ操作を阻害するため採用しない。
- delete時に旧revision cleanupをcommit条件にする方式は、不要ファイルの削除失敗でindexの正しい削除まで巻き戻すため採用しない。

## 帰結

- 管理操作成功後、カードの名前・順序・個数・revision・stateが更新される。
- 名前が空白だけ、端での移動、対象不在、busy、確認なし、active scene削除、live snapshot不一致は観測可能な日本語エラーになり、状態は変わらない。
- overwriteのindex commit失敗時は旧revisionがcurrentのまま維持され、新revisionがorphanとして残る可能性がある。これは起動時に自動採用しない。
- orphanが残った状態での再overwriteは、既存revisionの最大値より大きい番号（通常はrev3）へ保存し、旧orphanを保持したままindexを更新する。

## 再検討条件

- 対象選択UIや任意bundle対応を追加するときは、overwriteのidentity契約と権限境界を別DRで見直す。
- cleanup failureを診断画面で扱う必要が生じた場合は、orphan diagnosticの公開契約を追加する。

## 関連テスト

- `Sources/SceneShelfManagementTestRunner/main.swift`: rename、overwrite、duplicate、delete、move、busy、restart、永続化失敗時の不変性、orphan後の再overwrite。
- `Sources/SceneShelfCore/SceneRoundTrip.swift`: actor管理契約とmemory更新境界。
- `Sources/SceneShelfCore/ScenePersistence.swift`: index-only commit、revision commit、cleanup boundary。
