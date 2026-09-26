# DR-020: persistence retry and semantic revision validation

## Metadata

- Phase: Phase 1 / persistence retry boundary
- Kind: 通常判断（Decision D20）
- Scope: transient load retry, initialization failure UI boundary, duplicate window identity revision
- Related: `InMemorySceneStore`, `ShelfViewModel`, `SceneShelfPersistenceDiagnosticsView`, persistence/presentation runners
- Reversible: local code/tests/docs only; no app launch or external state change

## Decision

1. 通常の`loadPersisted()`は既存のfail-closedを維持する。外部修復後の再読込は明示的な`retryLoadPersisted()`だけが一時的な`persistenceLoadFailure`をクリアして実行する。
2. Application Support初期化失敗は再生成可能なstoreではないため、UIの再読込buttonを表示せず、設定確認とアプリ再起動を促す具体的な日本語メッセージを表示する。
3. revisionのwindow identity重複はdecode成功でも意味的に無効として`invalidRevision` diagnosticにし、公開sceneから除外する。除外sceneにはrestore executorを到達させない。
4. index orderは非負かつ`Int.max`未満に制限し、save/duplicateの次order計算もchecked incrementでpublish前に失敗させる。

## Why

一時的な破損・外部修復と不可逆な初期化失敗を同じ再試行操作に混ぜず、ユーザーが安全に修復後の再読込を行えるようにする。duplicate identityを復元すると同一windowへの複数writeになり得るため、load時点で除外する。

## Why not

- 通常loadが失敗後も自動で再試行する方式は、fail-closed契約を崩し、修復前の上書きを許すため不採用。
- Application Support初期化失敗をin-memoryへ切り替える方式はproduction保存成功表示と実disk状態を乖離させるため不採用。

## TDD and verification

- Red: 外部修復後の通常load再試行が失敗を保持すること、retry APIで成功すること、duplicate identity revisionがinvalidRevisionで除外されexecutorに到達しないことを先行追加。
- Green: Persistence runner 25 tests、strict build/test、全runner、bundle/codesign/plistを再確認する。atomicWriteのrename後fsync警告は別判断で変更しない。
