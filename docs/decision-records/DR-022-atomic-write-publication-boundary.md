# DR-022: atomic write publication and durability boundary

## Metadata

- Phase: Phase 1 / P1-5 review warning correction
- Kind: 通常判断（Decision D22）
- Scope: `SceneShelfPersistence.atomicWrite` rename前後の故障境界
- Reversible: local code/tests/docs only; no app launch or external state change

## Decision

1. rename前のtemp write/fsync失敗は`atomicWriteFailed`としてthrowし、destination indexと呼出側actor stateを旧状態のまま保つ。
2. rename後のdestination/directory durability failureは、目的URLを再読込して期待dataと一致するか検証する。一致すればbytesはpublished済みと判断して成功を返し、呼出側stateも新状態へ進める。一致しなければ`atomicWriteFailed`でfail closedする。
3. `ScenePersistenceFault.preRenameDurability`と`.postRenameDurability`で両境界をrunnerから再現可能にする。production pathではfaultなしの実fsyncを使用する。

## Why

rename後に単純throwすると、diskには新indexが残る一方で`InMemorySceneStore`は旧状態を保持し、次の操作・再起動で観測が分岐する。rename後は公開済みかどうかをbytesで確認し、確認できた公開commitだけを呼出側へ伝える。

## Why not

- rename後も常に旧状態としてthrowする方式は、実際に公開された新indexを呼出側が見失うため採用しない。
- fsync失敗を無条件に成功扱いする方式は、destinationが欠落・別dataになった場合の誤収束を許すため採用しない。
- fsync失敗時にindexを再構築・自動修復する方式は、今回のatomic write境界を越え、破損時の証跡を変更するため採用しない。

## TDD / verification

- pre-rename fault: renameされず、旧index bytesとactor memoryを保持することを確認。
- post-rename fault: 期待index bytesのread-back一致後、rename成功、actor memory更新、再load後の名前一致を確認。
- `SceneShelfPersistenceTestRunner`: 23 tests、全runner・strict build/test・bundle/codesign/plist PASS。
