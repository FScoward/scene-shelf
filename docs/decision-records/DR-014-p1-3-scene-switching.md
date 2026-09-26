# DR-014: P1-3 A→B scene switching safety boundary

## Metadata

- Phase: Phase 1 / P1-3
- Kind: 通常判断（Decision D14）
- Spec: GitHub Issue #1 AT-5 / AT-10、`design.md` §2.4・§6.3
- Related: `sprint-contract.md`、`../test-matrices/test-matrix.md` P1-3 section
- Reversible: code and local evidence only; no external OS or remote state is changed

## Purpose

A表示中にBカードをクリックしたとき、Aの登録対象を残したままBを重ねて表示する混在配置を防ぎ、クリック操作を一つの直列処理として確定する。

## Constraints and facts

- D14は、A hide成功後だけB displayへ進み、A hide partial/failed時はBを続行しないことを確定している。
- `InMemorySceneStore`は既存のP0-3 bool executorとP0-4 detailed reportの両方を公開している。
- actorの`isBusy`はawait中も保持できるため、同一actorの再入clickを`busyRejected`にできる。
- `SceneRestoreReport`は対象別outcomeを保持し、displayのpartial/failedとcurrentSceneID規則が既存テストで固定されている。
- 管理操作の既存契約では`failed` sceneは通常削除可能だが、A hide失敗後は`currentSceneIDValue == A`が残り、画面上のactive sceneであることを表す。

## Options

1. UIがA hideとB displayを別々の公開操作として呼び出す。
2. Storeの一つの`clickDetailed`呼び出し内で、A hideとB displayを同じexecutorへ順次渡す。
3. 切り替え専用の別actor／新commandを追加し、既存clickを経由させない。

## Decision

案2を採用する。`currentSceneIDValue`が要求Bと異なるAを指す場合、storeがglobal busyを設定したままAのhide planを実行する。Aのreport/stateを確定し、stateが完全な`stashed`でなければAのcurrentSceneIDを保持してAのoutcomeを返す。完全stashed時だけBのdisplay planを同じexecutorで実行し、Bのreport/state/currentSceneIDを既存規則で確定する。

hideに失敗対象がある場合は、対象別成功をreportへ残しつつカードstateを`failed`へ写像する。これは設計書の「hideの一部失敗はFailed」契約を既存のdisplay partialと区別するためである。switch中のA失敗は返却outcomeのscene IDをAにするため、UIは要求Bではなく実際に失敗したAのreportを取得して表示できる。

legacy bool executorでは、同一cardの失敗時に既存のatomic rollbackを維持する。A→B切り替え中のB失敗では、すでに成功したA hideをrollbackせず、A stashedとBのbool失敗結果を保持する。

T4レビューで、A hide失敗後の`failed` stateだけを見て削除を許可すると、画面に一部残るAを消せることが判明した。`delete`は`failed`でも`currentSceneIDValue == sceneID`の場合だけ`sceneActive`を返し、Aのstate/report/currentとBのstashed状態を維持する。current sceneがない通常の`failed` sceneは従来どおりconfirmed deleteを許可する。

## Why

- 一つのactor境界で順序とbusyを管理するため、A hide完了とB display開始の間に別clickが入り込まない。
- Aの対象別outcomeを保存してから中止するため、部分退避の成功を失わず、再試行時に失敗理由を使える。
- UIがカード間の順序制御を持たないため、AppKit/SwiftUIとAX adapterの責務を増やさず、既存のlive snapshot→plan→write境界を再利用できる。

## Why not

- 案1は二つの公開操作の間がbusyで保護されず、Aだけ退避された状態でB操作が別clickと競合し得るため不採用。
- 案3は新しいcommand/stateを増やしてP0/P1-2のclickとreport境界を二重化し、legacy executorの互換境界を広げるため不採用。

## Consequences and risks

- A hide失敗時はBを操作しないため、切替完了までの自動リトライは行わず、ユーザーがAの理由を確認して再操作する。
- A hide失敗後は表示中のAを管理操作で削除できないため、先に再試行または退避を完了させる必要がある。current sceneがない失敗sceneの削除可能性は維持する。
- B display partial/failedではAはstashedのままなので、ユーザーはAを再表示して戻せる。
- 実macOS AXのアプリ起動、複数display、VoiceOver、UIレイアウトはfocused runnerでは証明できずmanual境界に残る。

## Reconsideration conditions

- UIが切替途中の明示的cancel/retryを提供する場合、A failure後の再試行単位を再設計する。
- `SceneRestoreReport`のcurrentSceneID規則を変更する場合、P0-4 regressionとDR-006を再評価する。

## Related executable tests

- `SceneShelfSwitchingTestRunner` P1-3-TC-001〜TC-010
- Existing `SceneShelfRoundTripTestRunner`、`SceneShelfP0FourTestRunner`、`SceneShelfManagementTestRunner`
