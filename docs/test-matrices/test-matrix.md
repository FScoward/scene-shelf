# Scene Shelf P0-1 テストマトリクス

## 前提・仕様サマリ

- 対象は `SceneCoordinator` のfake scene状態遷移と、AppKit/SwiftUIの最小click入口。
- fake sceneは順序付き `開発`、`会議`。empty scenesは安全な空Shelfとして扱う。
- 状態は `stashed`（しまい済み）、`preparing`（準備中）、`displayed`（表示中）。
- `preparing`中の同一／別カードclickは `busyRejected`、キュー追加なし。
- 実AX、永続化、成功したA→B切替はP0-1対象外。

## 状態×イベントマトリクス

| 現在状態 | 同じカードclick | 別カードclick | empty scenes | 観測する契約 |
|---|---|---|---|---|
| `stashed` | ✅ `preparing`→`displayed` | ✅ 対象カードの`preparing`→`displayed`（別カードの操作は逐次） | N/A（カードなし） | clickで表示へ進む |
| `displayed` | ✅ `preparing`→`stashed` | N/A（P0-1では成功A→B切替を実装しない） | N/A（カードなし） | 再clickで退避へ進む |
| `preparing` | ❌ `busyRejected`、キューなし | ❌ `busyRejected`、キューなし | N/A（カードなし） | 処理中の全clickを拒否 |
| empty (`[]`) | N/A（click対象なし） | N/A（click対象なし） | ✅ 空Shelf、終了なし、安全なno-op | empty状態でクラッシュしない |

## テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| TC-001 | 同値分割 | 正常系 | fake scene順序 | `開発`,`会議`を登録 | snapshot取得 | 表示順が`開発`,`会議` | 高 |
| TC-002 | 状態遷移 | 正常系 | stashed→displayed | `開発=stashed` | `開発`click | `preparing`を経て`displayed`、accepted | 高 |
| TC-003 | 状態遷移 | 正常系 | displayed→stashed | `開発=displayed` | `開発`再click | `preparing`を経て`stashed`、accepted | 高 |
| TC-004 | 状態遷移 | 境界 | preparing中の同card | `開発`操作が待機中 | `開発`click | 即時`busyRejected`、追加操作なし | 高 |
| TC-005 | 状態遷移 | 境界 | preparing中の別card | `開発`操作が待機中、`会議=stashed` | `会議`click | 即時`busyRejected`、`会議`は`stashed`のまま、キューなし | 高 |
| TC-006 | 同値分割 | 異常系 | empty scenes | scene配列`[]` | snapshotと任意scene click | 空Shelf、クラッシュなし、安全なempty結果 | 高 |
| TC-007 | ユースケース | 正常系 | menu bar入口 | app起動済み | status item click | borderless vertical panelを表示／再clickで非表示 | 高 |
| TC-008 | 同値分割 | 表示契約 | 状態とVoiceOver | fake cardあり | card描画 | 日本語状態labelと安定identifierが付く | 中 |

## 0-switch / 1-switch 状態遷移カバレッジ

| カバレッジ | 対象 | 対応ケース |
|---|---|---|
| 0-switch | `stashed`,`displayed`,`preparing`,emptyを少なくとも観測 | TC-001〜TC-006 |
| 1-switch | `stashed→preparing→displayed`、`displayed→preparing→stashed` | TC-002, TC-003 |
| 無効遷移 | `preparing`中の同card／別cardはerror相当の拒否 | TC-004, TC-005 |
| P0-1対象外 | 成功したA→B switch、実AX、永続化 | Phase 1/P0-2以降で別契約 |

## 認可・外部境界

| 観点 | 判定 |
|---|---|
| アクター／権限 | P0-1はローカルUIのみ。正式な認可ロールは該当なし。 |
| TCC/Accessibility | P0-1では該当なし。実AXと権限案内はP0-2。 |
| 外部送信 | 該当なし。 |

## カバレッジサマリ

- 正常系: 5件（TC-001〜TC-003、TC-007〜TC-008のうちUI契約を含む）
- 異常・拒否系: 3件（TC-004〜TC-006）
- 境界値: 2件（busy同card/別card、empty）
- 状態遷移: 4状態観測、主要2往復、busy無効遷移2種
- 認可境界: 該当なし（P0-2へ送る）

## 未カバー・検討事項

- AXのlive再解決、曖昧一致、PID再利用、TCCはP0-2/P0-4。
- disk persistenceと破損／旧version契約はPhase 1。
- 成功したA→B切替はPhase 1。P0-1はカード入口とbusy拒否のみ。
- full XcodeによるGUI test、archive、署名配布は環境制約により未検証。

## Scene Shelf P1-3 シーン切り替えテストマトリクス

### 前提・仕様サマリ

- 対象は保存済みシーンAが表示中に、別シーンBのカードをクリックするA→B切り替えである。
- 切り替えは1つのglobal busy区間で、Aの登録対象をhideして完全に`stashed`になった場合だけBをdisplayする。
- Aのhideがpartial／failedなら、成功した対象の操作結果とAのreport/state/currentSceneIDを保持し、Bは未操作のまま中止する。
- Aのhide成功後にBのdisplayがpartial／failedでも、Aは`stashed`、Bは既存のreport規則で確定する。
- 同一card、legacy bool executor、missing targetは既存契約を維持する。

### 状態×イベントマトリクス

| 現在状態 | イベント | 前提条件 | 期待遷移／副作用 | 期待結果 |
|---|---|---|---|---|
| A=`displayed`, B=`stashed` | B click | A hide全対象成功 | A=`stashed`→B display | B=`displayed`、`currentSceneID=B` |
| A=`displayed`, B=`stashed` | B click | A hide一部成功 | Aの成功hideを保持、B displayしない | A=`failed`、A report/reason保持、`currentSceneID=A`、B=`stashed` |
| A=`displayed`, B=`stashed` | B click | A hide全失敗 | Aの失敗reportを保持、B displayしない | A=`failed`、`currentSceneID=A`、B=`stashed` |
| A=`displayed`, B=`stashed` | B click | A hide成功、B display一部成功 | Aを退避後Bを実行 | A=`stashed`、B=`partiallyRestored`、`currentSceneID=B` |
| A=`displayed`, B=`stashed` | B click | A hide成功、B display全失敗 | Aを退避後Bを実行 | A=`stashed`、B=`failed`、`currentSceneID=nil` |
| A=`displayed` | 同一A click | 切り替えではない | A hideのみ | 既存の表示／退避往復 |
| A=`displayed`, B=`stashed` | 任意card click | A→B操作中 | global busy中 | `busyRejected`、追加writeなし |
| A=`displayed` | missing B click | Bがstoreにない | Aへ作用しない | `sceneNotFound`、A=`displayed`、`currentSceneID=A` |

### テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| P1-3-TC-001 | 状態遷移 | 正常系 | A hide→B displayの順序 | A表示中、B退避済み | B click | actionsが`A.hide,B.display`、B表示中、current=B | 高 |
| P1-3-TC-002 | デシジョンテーブル | 異常系 | A hide partial | Aに2対象、B退避済み | B click、Aの1対象を失敗 | A failed、B未操作、A report/reason/currentを保持 | 高 |
| P1-3-TC-003 | デシジョンテーブル | 異常系 | A hide failed | A表示中、B退避済み | B click、Aを全失敗 | A failed、B未操作、切替中止 | 高 |
| P1-3-TC-004 | デシジョンテーブル | 異常系 | B display partial | A hide成功、Bに2対象 | B click、Bの1対象を失敗 | A stashed、B partial、current=B、B report保持 | 高 |
| P1-3-TC-005 | デシジョンテーブル | 異常系 | B display failed | A hide成功、B表示を全失敗 | B click | A stashed、B failed、current=nil、B report保持 | 高 |
| P1-3-TC-006 | 状態遷移 | 境界 | 切替中のglobal busy | A→B executor待機中 | AまたはBを追加click | `busyRejected`、二重実行なし | 高 |
| P1-3-TC-007 | 状態遷移 | 回帰 | same card | A表示中 | A click | A hideのみ、既存往復契約 | 高 |
| P1-3-TC-008 | 同値分割 | 異常系 | missing target | A表示中、Bなし | missing ID click | `sceneNotFound`、A不変 | 中 |
| P1-3-TC-009 | 同値分割 | 回帰 | legacy bool executor | A表示中、B退避済み | A hide成功→B display失敗 | A hideを保持、B失敗を既存bool境界で返す | 高 |
| P1-3-TC-010 | 状態遷移 | 異常系 | A hide失敗後のdelete | A表示中、B退避済み | B clickでA hide失敗→A delete confirmed | `sceneActive`で拒否、Aのstate/report/currentとBのstashedを維持 | 高 |

### 0-switch / 1-switch 状態遷移カバレッジ

| カバレッジ | 対象 | 対応ケース |
|---|---|---|
| 0-switch | `displayed`,`preparing`,`stashed`,`failed`,`partiallyRestored`を観測 | P1-3-TC-001〜TC-009 |
| 1-switch | `A displayed→A preparing→A stashed→B preparing→B displayed/partial/failed` | P1-3-TC-001, TC-004, TC-005 |
| 無効遷移 | A hide中／B display中の追加click、missing B | P1-3-TC-006, TC-008 |
| 回帰 | same-card、legacy bool executor | P1-3-TC-007, TC-009 |
| 管理境界 | A hide失敗後のconfirmed delete | P1-3-TC-010 |

### 未カバー・manual境界

- 実macOS AXでのA→Bウィンドウ移動、アプリ起動／前面化、複数display、VoiceOverはfocused runnerでは証明しない。
- UIの明示statusと実カード表示はCLIで完全には観測できないため、manual確認境界へ残す。

## Scene Shelf AT-2 保存時live snapshotテストマトリクス

### 前提・仕様サマリ

- 検出時のFixture snapshotは選択対象のidentity集合を決めるためだけに使い、保存ボタン押下時に`AXWindowAdapter.fixtureWindows()`でlive snapshotを再取得する。
- 保存対象のidentityがlive snapshotから欠落、曖昧、またはframe nilの場合は保存を中止し、検出時の古い座標へfallbackしない。
- 選択していないFixture windowは保存対象へ追加しない既存契約を維持する。

### 状態×イベントマトリクス

| 現在状態 | イベント | 前提条件 | 期待遷移／副作用 | 期待結果 |
|---|---|---|---|---|
| 検出済み | save | identityあり、live frameあり | 保存準備がlive snapshotを返す | 検出時B座標ではなく保存時A座標を保存候補にする |
| 検出済み | save | 選択identityがliveから欠落 | 保存準備で停止 | stale fallbackなし、日本語エラー、保存なし |
| 検出済み | save | 選択identityのframeがnil | 保存準備で停止 | stale fallbackなし、日本語エラー、保存なし |
| 検出済み | save | selected Main、未選択Secondary | live snapshot再取得 | Mainだけ保存候補、Secondaryを追加しない |

### テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| AT2-TC-001 | ユースケース／状態遷移 | 正常系 | 検出後の移動を反映 | 検出時B座標、保存時A座標、同一identity | detect→save準備 | live候補のframe=A、Bへrollbackしない | 高 |
| AT2-TC-002 | 同値分割 | 異常系 | 選択対象の欠落 | 検出時identityがliveに存在しない | save準備 | `windowMissing`相当、日本語エラー、保存なし | 高 |
| AT2-TC-003 | 同値分割 | 異常系 | 選択対象frame nil | identityはliveにあるがframe=nil | save準備 | `frameUnavailable`相当、日本語エラー、保存なし | 高 |
| AT2-TC-004 | 同値分割 | 回帰 | 選択除外 | Main/Secondary検出、Mainのみ選択 | save準備 | Mainのみが保存候補、Secondary非追加 | 高 |

### カバレッジサマリ

- 正常系: 1件
- 異常系: 2件
- 回帰／選択除外: 1件
- 状態遷移: 検出済み→live再取得→保存準備

### 未カバー・manual境界

- 実macOS AXでの実ウィンドウ移動と保存後再起動復元は手動確認境界に残す。
- UI上の日本語メッセージ描画、VoiceOver読み上げはCLI runnerではPASSを主張しない。

## Scene Shelf saved scene card click areaテストマトリクス

### 前提・仕様サマリ

- saved scene cardの主要部Buttonは視覚領域全体をhit shapeに含め、最低44pt相当の操作高さを持つ。
- 管理用「…」Menuは主要部Buttonの兄弟として独立し、主要部のgestureでMenu操作を奪わない。

### 状態×イベントマトリクス

| 現在状態 | イベント | 前提条件 | 期待結果 |
|---|---|---|---|
| saved card | 主要部の文字／余白click | Menu以外のcard視覚領域 | 同じButtonへhitし、表示／退避操作入口になる |
| saved card | Menu click | Menu領域 | 管理Menuがhitし、主要部clickへ伝播しない |
| saved card | keyboard/accessibility focus | card label | 主要部の操作高さが44pt以上で、既存label/identifierを維持 |

### テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| UX-TC-001 | ユースケース／hitTest | 正常系 | 主要部の余白クリック | NSHostingViewにprimary ButtonとMenu | Menu手前の透明余白をhitTest | primary領域がhitする | 高 |
| UX-TC-002 | 境界値 | 境界 | 最低操作高さ | primary label component | fitting/hitTest | 高さ44pt以上 | 高 |
| UX-TC-003 | 状態遷移 | 回帰 | Menu独立 | primary ButtonとMenuが兄弟 | Menu領域をhitTest | Menu領域が存在しprimaryへ吸収されない | 高 |

### 未カバー・manual境界

- 実機でのマウス／トラックパッド余白clickとMenu項目操作、VoiceOverの実操作はmanual確認境界に残す。

## Scene Shelf AX discovery / UI event quality follow-up

### 前提・仕様サマリ

- AX discoveryの候補が空でも、permission denied、Fixture未起動、同一Bundleの複数process、対象window欠落は異なる失敗理由として保持する。
- 保存・検出・overwrite・保存済み配置の復元UIは、失敗理由を対象ウィンドウの誤った`windowMissing`へ潰さず日本語で表示する。
- AX move/resize/minimizeは成功reportだけでなく、stateful fakeからframeと最小化状態をread-backして副作用を検証する。
- 保存カードのprimary whitespace clickは実`NSHostingView`のAppKit eventでactionを正確に1回実行し、Menu領域のeventはprimaryへ伝播しない。

### 状態×イベントマトリクス

| 現在状態 | イベント | 前提条件 | 期待結果 |
|---|---|---|---|
| discovery | permission denied | TCC未許可 | 空候補 + `permissionDenied`、UIはアクセシビリティ権限理由 |
| discovery | application unavailable | Fixture未起動 | 空候補 + `applicationUnavailable`、UIはFixture未起動理由 |
| discovery | ambiguous process | 同一Bundle processが2件以上 | 空候補 + `ambiguousMatch`、UIは一意特定不可理由 |
| save preparation | discovery failure | selected identityが残っている | `discoveryFailed(reason)`、stale候補／誤ったwindowMissingへfallbackしない |
| AX operation | move→resize→minimize | unique fixture fake | report成功 + read-back frame=目標、`isMinimized=true` |
| saved card | primary whitespace click | Menu手前の空白 | primary actionが1回だけ発火 |
| saved card | Menu click | Menu viewへhit | Menu viewがeventを受け、primary action countは増えない |

### テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| AX-UI-TC-001 | 同値分割 | 異常系 | permission reason preservation | discovery resultが`permissionDenied` | fixture discovery | 空候補とreasonを保持、labelが権限案内 | 高 |
| AX-UI-TC-002 | 同値分割 | 異常系 | unavailable reason preservation | discovery resultが`applicationUnavailable` | fixture discovery | 空候補とreasonを保持、labelが未起動案内 | 高 |
| AX-UI-TC-003 | 同値分割 | 異常系 | ambiguous reason preservation | discovery resultが`ambiguousMatch` | fixture discovery | 空候補とreasonを保持、一意特定不可案内 | 高 |
| AX-UI-TC-004 | 状態遷移 | 異常系 | save preparation failure | selected identityあり、discovery failure | save preparation | `discoveryFailed(reason)`、保存候補へfallbackしない | 高 |
| AX-UI-TC-005 | ユースケース | 正常系 | AX side-effect read-back | unique fake target | move→resize→minimize→再検出 | 目標frameと最小化状態がread-back一致 | 高 |
| AX-UI-TC-006 | 境界値／副作用 | 異常系 | move/resize frame unavailable | unique fake targetだが現在frame=nil | moveまたはresize | `operationFailed`、applied/write=0、frame nilを維持 | 最重要 |
| UX-AX-TC-006 | ユースケース | 正常系 | primary whitespace action | NSHostingView + AppKit window event | whitespace mouseDown/up | primary action count=1 | 高 |
| UX-AX-TC-007 | 状態遷移 | 境界 | Menu event isolation | NSHostingView + sibling Menu | Menu mouseDown/up | Menu viewがhit、primary action count不変 | 高 |
| UX-AX-TC-008 | 状態遷移／故障注入 | 警告系 | cleanup failure後の一覧更新 | store delete済み、旧revision cleanupのみ失敗 | confirmed delete | warningを保持しrefresh、削除済みカードを一覧から除去 | 最重要 |
| UX-AX-TC-009 | 同値分割 | 異常系 | discovery理由のUI表示 | permission/unavailable/ambiguous | detect/save/overwrite/restore | 各reasonの日本語メッセージ／対象別report | 高 |

### 0-switch / 1-switch 状態遷移カバレッジ

| カバレッジ | 対象 | 対応ケース |
|---|---|---|
| 0-switch | 3 discovery failures、save failure、AX read-back、nil-frame、primary/Menu event、cleanup refresh | AX-UI-TC-001〜006, UX-AX-TC-006〜009 |
| 1-switch | detection failure→UI reason、operation→read-back、mouseDown/up→action count、delete→refresh | AX-UI-TC-001〜006, UX-AX-TC-006〜009 |
| 無効遷移 | discovery failureをwindowMissingへ変換、nil frameを成功扱い、Menu eventをprimaryへ伝播、削除済みカードを残す | AX-UI-TC-001〜006, UX-AX-TC-007〜009 |

### カバレッジサマリ

- discovery reason異常系: 3件
- save propagation異常系: 1件
- stateful AX read-back正常系: 1件
- nil-frame副作用異常系: 1件
- AppKit event境界: 2件
- cleanup failureのwarning + refresh: 1件
- UI reason presentation boundary: 1件
- 実行runner値: AX 17件、Presentation 12件（summaryは実行時集計）
- real TCC付きAX read-back、VoiceOver、実機Menu popup表示: manual境界（このrunnerではPASSを主張しない）

## QG 状態遷移・busy安全性テストマトリクス（D19）

### 状態×イベント

| 現在状態 | イベント | 期待結果 |
|---|---|---|
| A=`displayed` | same-card click、hide全失敗 | A=`failed`、current=A、delete拒否、次B clickでA hide再試行 |
| A=`displayed` | same-card click、hide partial | A=`failed`、current=A、成功hideを保持、次B clickでA hide再試行 |
| A=`failed`, current=A | B click、A hide成功 | A=`stashed`後にB displayを実行 |
| B=`failed`, current=nil | B click、display成功 | B=`displayed`、current=B |
| A=`displayed`, B=`stashed` | A hide失敗→B click retry | Aが完全stashedになるまでB未操作 |
| 任意restore busy | save/rename/overwrite/duplicate/delete/move/loadPersisted | `busy`拒否、state/report/current/isBusy/index不変 |
| A=`partiallyRestored` | confirmed delete | `sceneActive`拒否、sceneとcurrent維持 |
| persisted single scene | move up/down | up/downとも`orderBoundary`、memory/index不変 |
| capture candidates | duplicate candidate / unregistered selection | `duplicateWindow` / `unregisteredWindow`、保存なし |
| target/candidates | identifier nil matching classes | unique nil matchのみ成功、複数候補はambiguous、誤writeなし |

### 実行可能テストケース

| ID | 観点 | 期待 |
|---|---|---|
| QG-TC-001 | same-card hide all failure | current Aを維持しA deleteを拒否 |
| QG-TC-002 | A hide failure/B display failure retry | A成功後B失敗、再clickでB表示へ回復 |
| QG-TC-003 | partiallyRestored delete | `sceneActive`、memory/current/index不変 |
| QG-TC-004 | busy management matrix | 6操作すべて`busy`、memory/index不変 |
| QG-TC-005 | loadPersisted while restore busy | `busy`拒否、restore state/isBusy不変 |
| QG-TC-006 | reorder boundary | single scene up/down、last downを拒否 |
| QG-TC-007 | capture duplicate/unregistered | capture拒否、scene未追加 |
| QG-TC-008 | nil identifier matching | unique/ambiguous/mismatch classesを安全側に判定 |

### 未確認境界

- 実macOS AXでの「全対象hide失敗でも実窓が残る」実測、GUI retry、VoiceOverは自動runnerではPASSを主張しない。

## P1-4 persistence integrity hardening（D18）

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| P1-4-TC-001 | 故障注入／状態遷移 | 異常系 | revision先書き後のsave採番 | index commit failureでscene-2-1.jsonが孤児化 | 再起動後save | scene-2を再利用せずscene-3、orphanは保持・diagnostic | 最重要 |
| P1-4-TC-002 | 故障注入／状態遷移 | 異常系 | revision先書き後のduplicate採番 | 同上、healthy scene-1が存在 | duplicate(scene-1) | orphan IDと衝突せず新revisionを公開 | 最重要 |
| P1-4-TC-003 | 同値分割 | 異常系 | semantic invalid revision | revision JSONのwindows=[] | reload | healthy sceneだけ公開、invalidRevision diagnostic | 高 |
| P1-4-TC-004 | デシジョンテーブル | 異常系 | index duplicate scene ID | index entriesのsceneID重複 | load | invalidIndexでfail closed | 高 |
| P1-4-TC-005 | デシジョンテーブル | 異常系 | index duplicate order | index entriesのorder重複 | load | invalidIndexでfail closed | 高 |
| P1-4-TC-006 | 境界値 | 異常系 | index revision <= 0 | revision=0 | load | invalidIndexでfail closed | 高 |
| P1-4-TC-007 | 同値分割 | 異常系 | path separator scene ID | sceneIDに`/`または`\` | load | invalidIndexでfail closed | 高 |
| P1-4-TC-008 | 故障注入／副作用 | 警告系 | delete cleanup failure | index commit成功後cleanup fault | delete confirmed | deleteは維持、cleanupFailedを呼び出し元へ通知、旧revision保持 | 高 |

### P1-4 未確認境界

- 実ディスク容量枯渇、fsync失敗、kill -9途中の再起動復旧は自動runnerで再現せず、manual/運用検証境界に残す。

## Persistence diagnostics / aggregated QG（D21）

### 状態×イベント

| 現在状態 | イベント | 期待結果 |
|---|---|---|
| index正常、revision正常 | 初回load | 診断行なし、保存カードを表示 |
| index正常、revision missing/corrupt | load | 対象sceneをカードから除外し、scene ID＋日本語理由を診断一覧へ表示 |
| index正常、複数revision異常 | load | 各scene IDの診断行を保持し、1行へ潰さない |
| index全体がcorrupt/unsupported/invalid | load | 「一覧全体」対象の安全説明を表示し、カード操作を誘導しない |
| 診断あり | 再読込click | loadを再試行し、修復・削除・自動採用を行わない |
| restore busy、診断あり | 再読込click | busyを表示し、既存diagnostic/stateを不変に保つ |
| 任意runner | test-all | 全8 runnerを実行し、失敗名を集約。1件以上失敗ならexit 1 |

### 実行可能テストケース

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| D21-TC-001 | 同値分割 | 異常系 | missing revision診断 | index entryあり、revision fileなし | `SceneShelfPersistencePresentation.rows` | scene IDと「保存ファイルが見つかりません」を同一行へ投影 | 最重要 |
| D21-TC-002 | 同値分割 | 異常系 | corrupt revision診断 | revision JSON decode不可 | presentation rows | scene IDと「保存ファイルが壊れています」を表示 | 最重要 |
| D21-TC-003 | デシジョンテーブル | 異常系 | global load failure | corrupt/unsupported/invalid index | `globalRow` | 対象「一覧全体」と安全な日本語理由を表示 | 高 |
| D21-TC-004 | ユースケース | 正常系 | diagnostic view boundary | rowsあり | View生成 | scene ID/reason labelとreload identifierを持つ描画可能なView | 高 |
| D21-TC-005 | 状態遷移 | 正常系 | explicit reload | diagnostic rows表示中 | reload button | load再試行へ到達し、自動削除・自動採用をしない | 高 |
| D21-TC-006 | エラー推測 | 異常系 | reload during busy | restore busy + diagnostic rows | reload click | busy拒否、診断とscene stateを保持 | 高 |
| D21-TC-007 | ユースケース | 回帰 | aggregated runner | 8 independent runners | `scripts/test-all.sh` | 全runnerを順次実行、失敗一覧を出力、失敗時exit 1 | 最重要 |

### カバレッジサマリ

- 0-switch: 正常load、revision単位missing/corrupt、index全体failure、diagnostic view
- 1-switch: load→diagnostic表示→reload、restore busy→reload拒否
- 無効遷移: diagnosticをscene cardとしてclick/deleteする経路は提供しない

### 未確認境界

- 実破損ファイルをユーザーがGUIで修復した後の再読込manual、VoiceOverでの診断行読み上げ、実ディスク容量枯渇は自動PASSを主張しない。

## P1-5 persistence warning hardening（D19）

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| P1-5-TC-001 | 同値分割 | 異常系 | cleanup exact identity | `foo-1.json`、`foo-bar-1.json`が存在 | cleanup(foo) | fooだけ削除、foo-barは保持 | 最重要 |
| P1-5-TC-002 | 境界値 | 異常系 | revision Int.max | after=Int.max | nextAvailableRevision | overflowせずatomicWriteFailed | 高 |
| P1-5-TC-003 | 境界値 | 異常系 | scene number Int.max | after=Int.max | nextAvailableSceneNumber | overflowせずatomicWriteFailed | 高 |
| P1-5-TC-004 | 意味検証 | 異常系 | commit windows empty | revision windows=[] | commit | invalidIndex、index/revision未公開 | 高 |
| P1-5-TC-005 | 意味検証 | 異常系 | commit duplicate identities | 同じidentityを2件 | commit | invalidIndex、index/revision未公開 | 高 |
| P1-5-TC-006 | 状態遷移 | 異常系 | load後段検証失敗 | 既存memory、disk indexのscene IDがInt.max | loadPersisted | error、旧scenes/stateを保持 | 最重要 |
| P1-5-TC-007 | 故障注入 | 異常系 | orphan scan read failure | valid index/revision、scan fault | load | atomicWriteFailedでfail closed | 高 |
| P1-5-TC-008 | 境界値／副作用 | 異常系 | save/duplicate publish後overflow | scene numberがInt.max直前 | save、duplicate | commit前に拒否しindex/memory不変 | 最重要 |
| P1-5-TC-009 | 故障注入／状態遷移 | 異常系 | pre-rename durability failure | 旧index公開済み、temp fsync境界でfault | rename | `atomicWriteFailed`、旧index bytes／actor memoryを維持 | 最重要 |
| P1-5-TC-010 | 故障注入／状態遷移 | 警告系 | post-rename durability failure | rename後のdestination fsync境界でfault、目的data一致 | rename | published commitとして成功、index／actor memory／reloadが新状態へ収束 | 最重要 |

### P1-5 実行数

- `SceneShelfPersistenceTestRunner`: 23 tests（P1-5追加2件を含む）
- `SceneShelfManagementTestRunner`: 14 tests
- 全runner: Core 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 23、Management 14、Switching 13

### P1-5 未確認境界

- 実filesystem permission/容量枯渇による`contentsOfDirectory`失敗、実volumeでのfsync障害、kill -9途中の復旧はmanual/運用境界に残す。post-rename faultのread-back収束はstateful runnerで検証済みだが、実ディスク耐久性そのものは主張しない。

## P1-6 persistence retry and semantic validation（D20）

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| P1-6-TC-001 | 状態遷移 | 異常系 | transient load failure保持 | corrupt indexをload後、外部修復済み | 通常load | fail-closedを維持し再読込しない | 最重要 |
| P1-6-TC-002 | 状態遷移 | 回復系 | explicit retry load | 上記の後indexを修復 | retryLoadPersisted | failureをclearしscene/stateを再読込 | 最重要 |
| P1-6-TC-003 | 意味検証 | 異常系 | duplicate identity revision | revision windowsに同一identity重複 | load | invalidRevision、公開scene除外 | 高 |
| P1-6-TC-004 | 副作用 | 安全性 | excluded scene restore | duplicate revisionがindexに残る | click/restore | sceneNotFound、executor/writeなし | 高 |
| P1-6-TC-005 | UI状態 | 異常系 | initialization failure retry boundary | Application Support準備失敗 | diagnostic表示 | 再読込buttonを出さず設定確認/再起動を提示 | 高 |
| P1-6-TC-006 | 境界値 | 異常系 | maximum index order | order=Int.max | load/commit | invalidIndex、採番trapなし | 高 |
| P1-6-TC-007 | 境界値／副作用 | 異常系 | save/duplicate order reserve | order採番が上限直前 | save、duplicate | publish前に拒否しindex/memory不変 | 最重要 |

### P1-6 実行数

- `SceneShelfPersistenceTestRunner`: 25 tests（retry、duplicate identity、order Int.max境界を含む）
- `SceneShelfManagementTestRunner`: 14 tests

## P1-7 single-instance lock / lost-update safety（D23）

### 状態×イベント

| 現在状態 | イベント | 期待結果 |
|---|---|---|
| lock file未保有 | 1つ目の`acquire` | lock fileを作成し、exclusive lockをprocess lifetimeで保持 |
| lock fileを別FDが保有 | 2つ目の独立`acquire` | `alreadyRunning`、新しいstore/AX開始へ進まない |
| lock保有中 | JSON save/load | `.instance.lock`と`index.json`／revision JSONを混同せず永続化成功 |
| lock保有中 | owner `release` | FDをunlock/closeし、lock file自体は残す |
| release済み | 次の`acquire` | lockを再獲得できる |

### 実行可能テストケース

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| P1-7-TC-001 | 状態遷移／エラー推測 | 異常系 | independent FD二重獲得拒否 | 同じlock path | owner A acquire→owner B acquire | Bは`alreadyRunning`、Aのexclusive ownershipを維持 | 最重要 |
| P1-7-TC-002 | 状態遷移 | 回復系 | release後再獲得 | owner Aがlock保有 | A release→owner B acquire | Bのacquire成功、lock fileは保持 | 最重要 |
| P1-7-TC-003 | 同値分割／副作用 | 正常系 | lockとJSON永続化の分離 | lock保有中、empty store | save→load | `index.json`／revision JSONが保存・再読込され、lock fileはJSON対象にならない | 高 |
| P1-7-TC-004 | コード監査／手動境界 | 異常系 | 起動時lock失敗境界 | second acquireが`alreadyRunning` | AppDelegate起動準備 | 日本語案内後にstore/AXを初期化せず終了 | 最重要 |

### P1-7 実行数

- `SceneShelfPersistenceTestRunner`: 27 tests（P1-7 lock 2件を含む）
- 全runner: Core 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 27、Management 14、Switching 13

### P1-7 未確認境界

- 実際の二つの独立アプリプロセス同時起動、GUI警告表示、kill -9途中のOS lock解放はmanual/運用境界。runnerは同一process内の独立open FD契約を検証する。
