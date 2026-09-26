# DR-025: 明示選択した一般アプリ配置の保存とwrite認可境界

## Metadata

- Phase: Phase 1 / P1-9
- Kind: セキュリティ境界を伴う実装判断（Decision D25）
- Scope: P1-8 catalog selection, scene capture, generic AX restore
- Reversible: code, runner, and documentation only; no app launch, AX write, or TCC change

## Decision

1. P1-8のcatalog windowをcheckboxで明示選択し、保存時に最新のread-only catalogを再取得する。全catalogで選択identityの存在・一意性を検証した後、選択済み候補だけを`store.save`へ渡す。未選択windowや未選択側の重複identityはsceneのallowlistに入れず、選択対象の保存を妨げない。
2. 保存済みsceneのwindow identity集合から`AXAuthorizationScope`を作り、各`AXOperationRequest`へ渡す。adapterのwrite境界でもbundleが空／Scene Shelf自身／scope外identityを拒否するため、UIの選択状態だけを認可根拠にしない。
3. scoped generic requestは保存identityのbundle ID＋PIDでrunning applicationを解決する。PIDが一致しない場合は推測せず失敗し、title＋optional identifierが同一PID内で一意に一致したときだけ操作対象へ進む。
4. move/resize/minimize/unminimizeの各operation直前に同じ解決を再実行する。曖昧、欠落、PID再利用、window hint変更、scope外はwrite 0（既に成功した前段operationの結果はreportへ保持）とする。
5. Fixtureの既存scopeなし経路は維持する。一般アプリの自動起動、PIDをまたぐ推測、候補からの暗黙保存はP1-9へ含めない。
6. catalog取得失敗はPresentationの`catalogState`へ通し、候補と選択集合を空にして日本語理由を表示する。保存済み一般アプリsceneのoverwriteはP1-9対象外とし、scene種別をwrite前に判定して明示的に拒否する。
7. 同一PID・同一title・同一identifierの重複window rowはToggleを出さず、「一意に識別できないため保存対象にできません」と表示する。

## Why

P1-8のread-only候補を保存対象へ進めるには、ユーザーが選んだidentityをscene自体の正本にし、UIから離れたwrite境界でも同じ許可範囲を検証する必要がある。bundle＋PIDを固定してからtitle＋identifierを毎回再解決すると、別processを同じ窓として扱う推測を避けつつ、windowの再生成や変化をwrite前に検出できる。scopeをrequestへ値として運ぶことで、既存のFixture限定経路を壊さずにgeneric writeを追加できる。

## Why not

- catalog取得時のsnapshotをそのままAXUIElementへ保持する方式は、保存後のwindow変化をwrite直前に検出できないため採用しない。
- UIで選択済みと表示されたwindowだけを操作し、adapter側でscopeを検証しない方式は、別経路のrequestや未選択identityを防げないため採用しない。
- 同Bundleの別PIDをtitle一致で救済する方式はPID再利用・別process混同を起こすため採用しない。
- windowが見つからないときにアプリを起動する方式は、ユーザーの明示操作範囲と安全境界を越えるため採用しない。

## Consequences

- 一般アプリの選択windowだけをsceneへ保存でき、保存済みカードのクリックでgeneric read/performへ進める。
- 同一title・identifierなしの複数window、wrong/unselected target、PID変化は日本語理由とwrite 0で失敗する。
- 同一PIDと別PIDに同じhintがある場合は、同一PIDの一意候補を優先する。保存済み一般アプリsceneの上書きは保存内容を変えず、未対応理由を表示する。
- アプリ終了、PID変化、window変更は自動回復せず、ユーザーが再検出・再保存する必要がある。
- 実機の任意アプリ選択・restore manualはこの変更の自動検証には含めない。

## Reconsideration conditions

- ユーザーがアプリ起動やPIDをまたぐ復元を明示的に要求した場合、起動権限・bundle allowlist・新しいmatcherを別Decisionで定義する。
- Accessibilityのwindow identifierが実アプリで安定しない事実が得られた場合でも、titleだけの曖昧一致を許可せず、追加の値型hintを定義してから再検討する。
- 複数display、space、fullscreenなどframe以外の配置状態を保存する場合は、現行scene schemaと別の保存契約を設計する。

## Related tests and evidence

- `Sources/SceneShelfAXTestRunner/main.swift`: authorization scope、wrong/unselected zero-write、ambiguous nil identifier、PID reuse、per-operation re-resolution、process discovery grouping。
- `Sources/SceneShelfRoundTripTestRunner/main.swift`: selected generic identityだけをSavedSceneへ保存、同hint別PID時のsame-PID優先、generic matcher unique/ambiguous境界。
- `Sources/SceneShelfPresentationTestRunner/main.swift`: 選択toggleに対応する識別子・日本語ラベル、catalog failure時のselection clear、重複row非選択、generic overwrite理由。
- `Sources/SceneShelfManagementTestRunner/main.swift`: 一般アプリscene overwriteのzero-write・保存不変。
- `docs/test-matrices/test-matrix-p1-9.md`
- `docs/phase1/evidence/P1-9-application-scene.md`
