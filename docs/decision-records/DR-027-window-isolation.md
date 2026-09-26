# DR-027: 保存配置表示前の背景ウィンドウ隔離

## Metadata

- Phase: Phase 1 / Scene isolation
- Kind: 通常ウィンドウの一時操作と復元境界を伴う設計判断
- Scope: applicationCatalog、saved-scene display/hide、A→B switching
- Status: 実装済み（Issue #1 Plan revision候補）
- Reversible: code, runner, and documentation only; no automatic app launch

## Decision

1. saved sceneを表示する直前に、read-only applicationCatalog の現在snapshotから、sceneの表示対象とScene Shelf自身を除く非minimized windowを選ぶ。Finder、System Settingsを含む通常のUIアプリは特別扱いしない。
2. 選んだwindowのexact identity集合だけを許可する一時 AXAuthorizationScope を生成し、各windowへ minimize を実行する。成功したsnapshotだけをruntime actorへ保持し、既にminimizedだったwindowや失敗したwindowは保持しない。
3. A→B切替では、Aのhide成功後にBのdisplay前隔離を行う。B表示開始前に、Bの表示対象を除く新しいvisible windowを同じ一時scopeで隔離する。切替途中に背景windowをunminimizeしない。
4. 背景windowの復元は、同じ表示中sceneのhideが完全成功してcurrent sceneがnilになった場合、またはdisplayが全失敗してcurrent sceneがnilになった場合だけ行う。restoreは保持snapshotをexact identityで再解決し、成功したものだけ集合から削除する。
5. catalog取得、背景minimize、restoreの失敗はsaved sceneの SceneRestoreReport／card stateへ混ぜず、status/accessibilityへ日本語で表示する。scene本体の表示は継続し、成功済みの退避集合は必要な境界で安全に復元する。restore失敗はruntime集合に残して次回操作で再試行できる。
6. saved scene本体の操作は従来どおり明示選択されたscene window identityのallowlistを使う。背景隔離はそれとは別の一時scopeであり、保存済みallowlistを拡張しない。

## Why

Stage ManagerがOFFの場合、macOS側の自動グルーピングに頼れないため、Scene Shelfが表示したsceneと、表示中のFinder・System Settingsなどが重なったままになる。scene表示対象以外のvisible windowを操作直前に一時退避することで、クリックによるscene切替でも画面全体を一つの配置として扱える。

値型snapshotをruntimeに保持し、AX参照を保持しないことで、window再生成やPID再利用後の参照を次回のexact identity解決で検出できる。成功したminimizeだけを保持するため、ユーザーが事前にしまっていたwindowを勝手に表示しない。

背景失敗をscene reportへ混ぜないのは、scene本体の成功・partial・failedと、補助的な背景隔離／復元の状態が別の利用者観測だからである。背景失敗をscene stateへ変換すると、scene本体が完全表示できた場合までpartialとして扱い、再試行や削除保護の意味を変えてしまう。

## Why not

- macOSのStage Manager状態に委ねる方式は、OFF時に背景windowを制御できず、ON/OFFで挙動が変わるため採用しない。
- saved sceneのallowlistへcatalog全windowを追加する方式は、明示選択された保存対象の安全境界を壊し、後続の管理操作にも影響するため採用しない。
- isolate失敗時にscene本体表示を中止する方式は、安全性は上がるが、背景一件の一時操作失敗で保存scene自体を表示できなくする可用性低下が大きい。scene表示は継続し、失敗を別statusへ出す。
- hide後に毎回catalog全windowをunminimizeする方式は、Scene Shelfがしまっていないwindowまで表示し、ユーザーの外部操作を上書きするため採用しない。
- AXUIElementやNSRunningApplicationをruntimeへ保存する方式は、プロセス終了・window再生成後の参照が不安定で、Sendable境界とexact identity検証を迂回するため採用しない。

## Consequences and risks

- Stage Manager OFFでも、scene対象以外のvisible normal windowはscene表示前に一時退避される。
- 背景windowのminimizeまたはrestoreに失敗した場合、scene本体の結果とは別に日本語の理由が表示される。failed snapshotは保持されるため、再試行時に同じidentityで再解決する。
- display全失敗時は、今回成功した背景退避だけが復元される。display partial／successでは背景を保持し、scene hide成功後に復元する。
- 実AX環境でFinder/System Settingsのwindow title・identifierが一意でない場合、既存のgeneric matcherにより書き込みは拒否される。推測によるPID／title救済は行わない。
- 複数display、Space、fullscreen、Stage Manager固有の表示状態はframeとminimizedの範囲を越えるため、この変更だけでは保存しない。

## Reconsideration conditions

- macOS AXで通常windowを一意に識別できないアプリが一般化し、title／identifier以外の安定値が得られた場合は、identity schemaとmatcherを別Decisionで再設計する。
- 背景隔離失敗時にscene表示自体を止めるUXを選択する場合は、scene report/stateへ混ぜないまま専用の操作状態と再試行UIを定義する。
- Space／display／fullscreenをscene契約へ含める場合は、現在のframe＋minimized snapshotとは別の保存schemaを設計する。

## Related tests and evidence

- Sources/SceneShelfAXTestRunner/main.swift
  - Finder/System Settingsを含むvisible window選定
  - display前のminimizeとhide相当のunminimize
  - A→Bで前の背景をunminimizeしない
  - 既にminimizedだったwindowを保持・復元しない
  - restore失敗後の保持と再試行
- Sources/SceneShelfAccessibility/AXTypes.swift
  - AXApplicationIsolationPolicy
  - AXWindowIsolationCoordinator
  - AXBackgroundWindowRuntime
