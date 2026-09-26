# DR-019: QG state-transition and busy safety

## Metadata

- Phase: Phase 1 / Core state-transition hardening
- Kind: 通常判断（Decision D19）
- Scope: same-card hide failure, scene switching retry, management busy matrix, persisted reload boundary
- Related: `SceneRoundTrip`, `SceneManagement`, `SceneShelfManagementTestRunner`, `SceneShelfSwitchingTestRunner`, `SceneShelfRoundTripTestRunner`
- Reversible: local code/tests/docs only; no app launch or external state change

## Purpose

実ウィンドウが残る失敗状態を「current sceneなし」と誤認せず、復元・退避・管理操作の競合時にmemoryとindexを壊さない。

## Constraints and facts

- hideが全対象失敗でも、実窓が残る可能性があるため、完全に`stashed`と確定できるまでcurrent sceneを解除できない。
- `rename`、`overwrite`、`duplicate`、`delete`、`move`、`save`はrestore中に受け付けてはならず、失敗時もmemory/indexを不変に保つ。
- `loadPersisted`はrestore中に既存state・report・currentSceneID・busyをリセットしてはならない。
- captureはduplicate candidateとunregistered selectionを拒否し、identifierがnilのmatching classも曖昧さを安全に扱う必要がある。
- Persistence agentが`SceneRoundTrip.swift`の永続化境界を更新中だったため、runner/test先行後に最新本体を読み直して修正した。

## Decision

1. `SceneRestoreReport.currentSceneID`はhideが完全成功した場合だけnilとし、hideに失敗が残る場合は成功対象の有無にかかわらずscene IDを保持する。
2. current Aがhide失敗した後のB clickは、A hideを再試行し、Aが完全stashedになった時だけB displayへ進む。AまたはBの失敗後は同じ安全境界からretryできる。
3. `loadPersisted`はrestore busy中に`SceneManagementError.busy`を返し、既存actor stateを変更しない。
4. busy matrixはsave/rename/overwrite/duplicate/delete/move/loadPersistedを同じ公開境界で検証する。

## Why

- current sceneを「完全退避済み」の証拠として扱うことで、実窓が残ったまま別sceneやdeleteへ進む混在配置を防ぐ。
- retryを同じactor境界に戻すことで、失敗したA/Bのreportを保持しつつ安全に回復できる。
- reloadをbusy拒否にすることで、stateのリセットと永続化読み込みの競合を明示的に閉じる。

## Why not

- hide失敗を常にcurrent nilへ写像する方式は、実窓を追跡できなくなりdelete安全境界を破るため不採用。
- busy中の`loadPersisted`を許可して最後に読み込んだ値で上書きする方式は、進行中restoreのstate/reportを失うため不採用。

## Consequences and risks

- all-target hide failureでもcurrent sceneが残るため、ユーザーは再試行してから別scene切替・deleteを行う必要がある。
- busy中のloadは一時的に失敗するが、状態を保持したまま再試行できる。
- identifier nilの候補が複数ある場合は安全側に曖昧扱いし、誤ったwindowへのwriteを避ける。

## Reconsideration conditions

- 実AX adapterが「全対象hide失敗でも確実に退避済み」を証明する別の観測契約を提供した場合、hide reportのcurrent判定を再評価する。
- reloadを安全にmergeできるCAS契約が追加された場合、busy拒否から明示的mergeへ再検討する。

## Related executable tests

- `SceneShelfSwitchingTestRunner`: same-card hide failure current保持、A/B retry、delete拒否
- `SceneShelfManagementTestRunner`: partiallyRestored delete拒否、全busy matrix、loadPersisted busy拒否、order境界
- `SceneShelfRoundTripTestRunner`: capture duplicate/unregistered、identifier nil matching class
