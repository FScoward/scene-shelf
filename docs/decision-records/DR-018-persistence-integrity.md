# DR-018: persistence integrity after partial commits

## Metadata

- Phase: Phase 1 / persistence integrity hardening
- Kind: 通常判断（Decision D18）
- Scope: orphan revision採番、semantic revision validation、index validation、delete cleanup failure
- Related: `SceneShelfPersistence`, `InMemorySceneStore`, `SceneManagement`, persistence/management runners
- Reversible: local code/tests/docs only; no app launch or external state change

## Decision

1. revisionを先に公開してからindex commitが失敗した場合、revisionを自動採用・削除せず、次のscene ID/revision採番ではファイル名を含む全disk stateを避ける。未参照revisionは`.orphanRevision` diagnosticで保持する。
2. revision JSONの`windows`が空の場合はschema上decodeできても意味的に無効として公開scenesから除外し、`.invalidRevision`を返す。
3. indexはscene ID/orderの重複、revision非正、path separatorをfail closedで拒否する。
4. deleteのindex commitを先に確定し、旧revision cleanupだけが失敗した場合は削除をrollbackせず、`SceneManagementError.cleanupFailed`でUIへ通知する。残存ファイルは診断可能なorphanとして保持する。

## Why

indexを唯一のcommit pointとして扱い、途中で公開されたimmutable revisionを破壊せず、再試行が同一ファイル名を再利用しないため。semantic invalidを正常sceneとして公開すると、復元対象が空になるため読み込み段階で安全側に除外する。

## Why not

- orphanを再利用・自動削除する方式は、障害時の証跡を失い、再試行のcollisionを隠すため不採用。
- cleanup failureでdelete全体をrollbackする方式は、既にcommit済みindexとmemoryの不一致を作るため不採用。
- decode成功だけでrevisionを採用する方式は、空windowという意味的不変条件を検証できないため不採用。

## TDD and verification contract

- Red: index commit faultでorphanを作った後のsave/duplicateが旧実装で同一scene IDへ再利用するbehavioral test、空windows、invalid index 4分類、cleanup failure通知を先行追加する。
- Green: disk filename採番、orphan diagnostic、semantic validation、cleanup failure errorを最小実装し、focused runnerと既存runnerを再実行する。
- 手動境界: fsync障害・容量枯渇・kill -9途中の実macOS recoveryとGUI表示はrunnerのPASSだけでは主張しない。
