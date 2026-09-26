# DR-006: P0-4は対象別matchと部分結果を値型で集約する

日付: 2026-09-25
対象: Scene Shelf / P0-4
関連: GitHub Issue #1 Plan revision 1、`SceneShelfCore/SceneRoundTrip.swift`

## 目的

同一bundleの複数windowを安全に照合し、特定できない対象にはwriteせず、成功した対象の操作を継続しながら対象別の失敗理由とカード状態を保持する。ユーザーが「一部復元」「失敗」を見て、次のクリックで安全に再試行できる状態を作る。

## 制約・確認済み事実

- P0-2のlive AXは`SceneShelfAccessibility` actor内にraw `AXUIElement`を閉じ、許可bundleを専用Fixtureへ限定し、各write直前に再解決する。
- P0-3はin-memory sceneとクリック往復を実装済みで、保存対象以外へwriteしない契約を持つ。
- CLT環境ではXCTest/Swift Testingを実行できないため、runnerの実assertionを使う。
- 同一title/identifierのduplicate、PID再利用、missingは自動操作してはならない。P0-4のreal AX manualは別途必要だが、今回の実装検証では行わない。

## 決定

1. `SceneMatcher`をCoreの純粋な値型関数として置き、bundle、title、identifier、processIDを複合手掛かりとして`matched`、`ambiguous`、`pidReused`、`windowChanged`、`missing`、`bundleNotAllowed`を返す。
2. `SceneRestorePlanner.resolve`は`matched`だけをwrite instructionへ渡し、それ以外を`preflightFailures`へ保持する。
3. `SceneTargetRestoreOutcome`を対象単位の結果、`SceneRestoreReport`をscene単位の集約結果とし、成功対象の操作を後続対象の失敗で取り消さない。
4. 一件以上成功かつ失敗ありを`partiallyRestored`、全成功をactionに応じた`displayed`/`stashed`、全失敗を`failed`とする。表示actionは成功対象が1件以上なら`currentSceneID`にscene IDを保持する。退避actionは全対象成功ならすべて退避済みなのでnil、部分退避は成功対象を保持するためscene ID、全失敗はnilとする。
5. `stashed`、`partiallyRestored`、`failed`の次クリックはdisplay planを再作成し、`displayed`だけがhide planへ進む。これにより部分/全失敗を安全に再試行できる。
6. UIは対象titleと日本語failure labelを保存カードへ表示し、raw enum名を表示しない。AX reportのfailure reasonは同じ値型境界でCore reasonへ変換する。
7. P0-3互換のbool executorが全失敗を返した場合は、カードstateだけでなく、その前の`currentSceneID`と対象別reportも復元する。詳細な部分/失敗カードを表示するP0-4 UIは`clickDetailed`を使う。

## Why

- 一意一致だけをwrite計画へ通すことで、曖昧なduplicateやPID再利用による誤操作を、AX writeより前に止められる。
- 対象別reportなら、一件の失敗で成功対象まで失敗扱いにせず、ユーザーが部分結果と再試行対象を理解できる。
- actionと成功対象から`currentSceneID`を導出すると、表示・部分退避・全退避・全失敗の内部状態をUI文言やraw enum表示から独立して検証できる。
- retryをdisplay方向へ固定すると、部分的にminimize済み/表示済みの対象へ再度安全に現在配置を適用でき、失敗カードのクリックが無操作や意図しない全退避にならない。
- 互換bool executorの失敗を状態一式でロールバックすると、P0-3の単純な成功/失敗契約を保ったままP0-4の詳細reportを内部に残さずに済む。

## Why not

- 失敗時に全sceneを中断する方式は、成功した対象を保持できず、P0-4の部分成功要件を満たさないため採用しない。
- matcherをUIやAX raw referenceに置く方式は、CLT runnerでの純粋な再現性とactor境界を失うため採用しない。
- 曖昧候補をscoreや「最初の候補」で選ぶ方式は、ユーザー確認なしの誤writeを許すため採用しない。
- 失敗理由をraw enum名で表示する方式は、内部契約をUIへ漏らし、ユーザーに意味が伝わらないため採用しない。
- 永続化、任意アプリ、複数display、force quitは、P0-4の照合/部分結果を超えるため採用しない。

## 帰結

- P0-4のmatcher、write計画、対象別report、状態遷移は実行可能なrunnerで検証できる。
- real AXでのduplicate表示、PID再利用、部分成功は未確認であり、自動runnerのPASSだけではCP-final manual PASSにならない。
- P0-3の`click` bool executorは互換のため残し、失敗時はstate/currentSceneID/reportを原子的に復元する。部分/失敗カードを扱うUIは`clickDetailed`を使う。
- fixture操作用にduplicate MainとSecondaryの閉じる/再表示ボタンを追加したが、実機での手動確認は後続とする。

## 再検討条件

- real AX manualでadapterの対象別failureやduplicateの挙動が確認されたとき、failure reasonの表示粒度とretry UXを見直す。
- 任意アプリ対応を承認したとき、fixture固定matcherをアプリごとのidentity policyへ分割する。
- disk persistenceや複数displayを承認したとき、report/revision/display mappingの永続化契約を別DRで設計する。

## 関連テスト

- `Sources/SceneShelfP0FourTestRunner/main.swift`: unique、ambiguous write 0、PID reuse write 0、partial、all failure/currentSceneID、target-specific reason、表示→退避のcurrentSceneID解除、bool executor失敗のstate/currentSceneID/reportロールバック、busy、partial retry、Secondary非操作（12件）。
- `Sources/SceneShelfRoundTripTestRunner/main.swift`: P0-3 capture/selection/display/hide往復。
- `Sources/SceneShelfAXTestRunner/main.swift`: permission、fixture安全境界、直前再解決、unminimize。
