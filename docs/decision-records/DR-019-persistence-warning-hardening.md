# DR-019: persistence warning hardening

## Metadata

- Phase: Phase 1 / persistence warning correction
- Kind: 通常判断（Decision D19）
- Scope: exact revision cleanup, overflow boundaries, revision payload validation, fail-closed load preparation
- Related: `SceneShelfPersistence`, `InMemorySceneStore`, persistence/management runners
- Reversible: local code/tests/docs only; no app launch or external state change

## Decision

1. revision cleanupは文字列prefixではなく、`revisionIdentity`でscene IDとrevision番号が完全一致するファイルだけを削除する。`foo` cleanupは`foo-bar-1.json`を残す。
2. scene/revision採番の`Int.max`到達は`addingReportingOverflow`で検出し、atomic writeやindexを進めずfail closedする。save/duplicateはpublish前に次番号をreserveし、publish成功後のoverflow throwを許さない。
3. revision commitはloadと同じ意味的不変条件（windows非空、window identity重複なし）を検証する。
4. `loadPersisted`はdisk load、index全entry構築、scene number採番、orphan scanまでローカル値で検証してからactorのscene/state/indexを一括反映する。後段検証失敗では旧actor状態を保持する。
5. orphan走査のdirectory read failureは`try?`で黙殺せず`atomicWriteFailed`としてfail closedする。テスト用fault injectionで同じ契約を実行確認する。

## Why

部分commit後のファイルを安全に診断可能なまま保持しつつ、別sceneのrevision削除、数値wraparound、意味的に無効な保存、読み込み途中のactor状態破壊を防ぐため。

## Why not

- filename prefixだけでcleanupする方式はscene IDのprefix衝突で他sceneを削除するため不採用。
- overflowを自然な`+ 1`へ任せる方式はtrapまたは負値化を起こし、保存済みindexとの衝突を招くため不採用。
- load途中でactorを先に更新する方式は後段のdisk scan失敗時にmemoryとdiskを不一致にするため不採用。

## TDD and verification

- Red: `foo`/`foo-bar` cleanup、Int.max採番、empty/duplicate windows commit、load後段失敗、orphan scan failureを先行追加し、旧実装のcleanup誤削除を実測。
- Green: Persistence 20 tests、Management 14 testsをstrict concurrency付きでPASS。atomicWriteのrename後fsync警告は別判断として今回変更しない。
