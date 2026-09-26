# Scene Shelf P1-9 テストマトリクス

## 前提・仕様サマリ

- P1-8 catalogのwindowをユーザーが明示選択し、最新read結果から選択identityだけをsceneへ保存する。
- 保存sceneのidentity集合はwrite allowlistの正本。`AXAuthorizationScope`がrequestへ渡され、adapterでもscope外を拒否する。
- generic restoreはbundle ID＋PID完全一致、同PID内title＋identifier一意一致、operationごとの再解決を要求する。
- PID変化、window欠落、同title・identifierなし複数、hint変更、scope外はwrite 0。アプリ自動起動はしない。
- 保存時は最新catalog全体で選択identityの存在・一意性を検証し、storeへは選択済み候補だけを渡す。catalog failureは候補・selectionを空にし、同一identityの重複rowは選択不可とする。一般アプリsceneのoverwriteは未対応で保存不変とする。

## 認可デシジョンテーブル

| 判断ID | 認証 | 権限 | 対象scope | Bundle/PID | window hint | 期待判断 | 対応TC |
|---|---|---|---|---|---|---|---|
| AUTH-901 | 済 | granted | 選択済み | 一致 | 同PID内で一意 | 許可してwrite候補へ | TC-901 |
| AUTH-902 | 済 | granted | 未選択 | 一致 | 一意 | `targetNotAuthorized`、write 0 | TC-902 |
| AUTH-903 | 済 | granted | 選択済み | PID不一致 | 同じhint | `pidReused`、write 0 | TC-903 |
| AUTH-904 | 済 | granted | 選択済み | 一致 | 同title＋identifier=nilが複数 | `ambiguousMatch`、write 0 | TC-904 |
| AUTH-905 | 済 | granted | 選択済み | 一致 | operation間で変更 | 前段成功を保持、変更後はwrite 0 | TC-905 |
| AUTH-906 | 済 | granted | 選択済み | bundle空／Scene Shelf | any | `bundleNotAllowed`、write 0 | TC-906 |
| AUTH-907 | 済 | granted | 選択済み | 同hintが別PIDにも存在 | 同PID内一意 | same PIDをmatched | TC-911 |
| AUTH-908 | 済 | granted | 選択済み | catalog failure | permissionDenied等 | candidates/selection空、理由表示 | TC-913 |

## テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| TC-901 | ユースケース | 正常系 | catalog選択をsceneへ保存 | candidate 2件、1件選択 | save | SavedSceneは選択identity 1件だけ | 最重要 |
| TC-902 | 認可デシジョン | セキュリティ境界 | wrong/unselected target | scopeは別windowだけ | scoped perform | `targetNotAuthorized`、write 0 | 最重要 |
| TC-903 | 同値分割 | 異常系 | PID reuse | same bundle、別PID | scoped perform | `pidReused`、write 0 | 最重要 |
| TC-904 | 境界／エラー推測 | 異常系 | nil identifier ambiguity | same bundle＋PID＋title、identifier=nilを2件 | generic matcher/perform | `ambiguousMatch`、write 0 | 最重要 |
| TC-905 | 状態遷移 | 部分成功 | operation毎の再解決 | 1回目match、2回目hint変更 | move→resize | moveだけ成功、resize前に停止 | 最重要 |
| TC-906 | 同値分割 | 禁止境界 | bundle禁止 | empty／Scene Shelf target | authorization | `bundleNotAllowed`、write 0 | 高 |
| TC-907 | 同値分割 | 正常系 | generic unique match | bundle＋PID＋hint一致1件 | generic matcher | matched | 高 |
| TC-908 | ユースケース | UI | window selection toggle/name/save入口 | catalog表示 | toggle、名前入力、save | 日本語label・安定identifier、選択0なら保存不可 | 高 |
| TC-909 | エラー推測 | 運用 | app/process discovery grouping | 2 app/process、同process複数window | restore preparation | 各bundle＋PIDを1回だけread | 中 |
| TC-910 | 回帰 | Fixture | existing Fixture経路 | scopeなし旧request | existing runner | 既存write/roundtrip不変 | 最重要 |
| TC-911 | 境界 | 正常系 | same PID優先 | same bundle、same hintが別PIDにも存在 | matcher resolve | same PID候補をmatched、same PIDなしは`pidReused` | 最重要 |
| TC-912 | 境界 | 安全側 | 未選択重複の隔離 | selected A、unselected B duplicate | latest catalog save preparation | selected候補だけstoreへ渡し、A保存成功 | 最重要 |
| TC-913 | エラー推測 | 安全側 | 保存直前catalog failure | selectionあり、permissionDenied | save前catalog | catalogState経由で候補・selection空、理由更新 | 最重要 |
| TC-914 | UI／認可 | 禁止境界 | duplicate row選択 | same PID/title/identifier duplicate | windowRows / toggle surface | row非選択、日本語理由、selection setへ追加不可 | 高 |
| TC-915 | 管理操作 | 禁止境界 | generic overwrite | saved scene bundle != Fixture | overwrite | 明確な未対応理由、write 0、scene/index不変 | 最重要 |

## 状態×イベントマトリクス

| 現在状態 | catalog refresh | select toggle | save | display/hide click | 期待結果 |
|---|---|---|---|---|---|
| 権限 denied | ❌候補空 | ❌ | ❌ | ❌ | write 0、日本語理由 |
| granted / 候補なし | ✅空 | ❌ | ❌ | 既存sceneのみ | 保存対象なし |
| granted / 候補表示 | ✅値更新 | ✅選択集合更新 | 1件以上なら✅ | 既存sceneをread/perform | selected identityだけ保存 |
| saved / target unique | read exact PID | N/A | N/A | ✅ | 各operation前に再解決してwrite |
| saved / target missing/ambiguous/PID reuse | read failure | N/A | N/A | ❌安全停止 | write 0、理由表示 |

## カバレッジサマリ

- 正常系: TC-901、TC-907、TC-908
- 異常・認可・禁止: TC-902〜TC-906
- 状態遷移: TC-905、状態×イベント全行
- 回帰: TC-910
- 自動runner実績（focused）: AX 26件、RoundTrip 12件、Presentation 15件、Management 15件

## 未カバー・検討事項

- 実機で一般アプリを選択して保存・カードクリックrestoreするmanualは未実施。
- アプリ終了後の再起動、PIDをまたぐ復元、複数display・Space・fullscreenは対象外。
- 実アプリごとのAX title/identifier安定性はTCC許可済み環境で別途確認する。
