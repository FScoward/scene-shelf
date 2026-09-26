# DR-023: single-instance file lock for persistence safety

## Metadata

- Phase: Phase 1 / review-loop W2
- Kind: 通常判断（Decision D23）
- Scope: Scene Shelf process lifetime and Application Support persistence boundary
- Reversible: local code/tests/docs/Info.plist only; no app launch or external state change

## Decision

1. 起動時にApplication Support/SceneShelf/.instance.lockを専用の`SceneShelfInstanceLock`で開き、`flock(LOCK_EX | LOCK_NB)`をprocess lifetime中保持する。
2. 二つ目の独立open FDが`alreadyRunning`になる場合は、日本語の警告を表示して保存storeとAX adapterを生成する前に終了する。
3. lock fileは`index.json`／`scenes/*.json`と別pathに置き、JSON永続化はlock保持中も通常どおり行う。release後は同じpathを再獲得できる。
4. `LSMultipleInstancesProhibited=true`も補助宣言として追加するが、排他の正本はfile descriptor lockとする。

## Why

LaunchServicesの単一起動宣言だけでは、同一bundleを独立プロセスから起動したときの永続化競合を実行時に直接検証できない。OSのfile lockをprocess lifetime中に保持すれば、index commitを並行するプロセスを保存・AX開始前にfail closedできる。Application Support rootを既存Persistenceと共有し、lock pathだけ分離することでlost update防止とJSON形式を混ぜない。

## Why not

- LaunchServices keyだけに依存する方式は、宣言と実際のFD所有の間に競合窓が残るため補助扱いにする。
- PIDや既存プロセス検索は、終了途中・PID再利用・同一bundle判定に依存し、排他そのものを保証しないため採用しない。
- lock fileへJSON状態を書き込む方式は、排他メタデータとscene persistenceを混ぜ、lock破損時の復旧責任を増やすため採用しない。

## TDD / verification

- 独立した二回の`SceneShelfInstanceLock.acquire`で二重獲得を拒否し、最初のownerのrelease後に再獲得できることをrunnerで確認する。
- lock保持中も`index.json`とrevision JSONを保存・再読込でき、lock fileをJSONとして扱わないことをrunnerで確認する。
- AppDelegateはlock取得後にだけ`InMemorySceneStore`と`AXSystemAdapter`を生成し、失敗時は日本語案内と`NSApp.terminate`へ進む。

## 未確認境界

- 実際に二つの独立アプリプロセスを同時起動したGUI表示と、OS終了・kill -9途中のlock解放はmanual/運用境界に残す。runnerの二つのopen FDはfile lock契約の自動証拠であり、GUI起動証跡ではない。
