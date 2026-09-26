# Scene Shelf P0-2 テストマトリクス

## 前提・仕様サマリ

- 対象は `com.fscoward.SceneShelfAXFixture` の stable window だけ。任意のユーザーアプリは操作しない。
- `AXUIElement`、`NSRunningApplication`、process/window object は adapter actor内の1操作呼出しに閉じ、Sendable値型だけを返す。
- Accessibility permission は `AXIsProcessTrusted()` で読むだけ。未許可時は列挙・書込み・OS設定変更を行わない。
- write直前に fixture app、PID、bundle ID、window title、identifier を再解決する。0件・2件以上・PID差・hint差はwrite 0回で失敗理由を返す。
- 1件に一意照合できた場合のみ、要求された move / resize / minimize を順に実行する。無制限retry、force quit、closeは行わない。

## 状態×イベントマトリクス

| 現在状態 | permission read | fixture detect | safe operation | settings click | 観測する契約 |
|---|---|---|---|---|---|
| `denied` | ✅ `denied` + reason | ❌ no-op / `permissionDenied` | ❌ write 0 / `permissionDenied` | ✅ 明示クリック時だけ設定URLを開く | 起動時promptなし、権限なしでAX操作なし |
| `granted` + app missing | ✅ `granted` | ✅ empty + `applicationUnavailable`相当 | ❌ write 0 / `applicationUnavailable` | ✅ 明示クリック時だけ設定URLを開く | fixture以外を探さない |
| `granted` + unique window | ✅ `granted` | ✅ 1 snapshot | ✅ exact requested writes | ✅ 明示クリック時だけ設定URLを開く | write順と値型Report |
| `granted` + missing window | ✅ `granted` | ✅ empty | ❌ write 0 / `windowMissing` | ✅ 明示クリック時だけ設定URLを開く | 安全にskip |
| `granted` + ambiguous windows | ✅ `granted` | ✅ 2+ snapshots | ❌ write 0 / `ambiguousMatch` | ✅ 明示クリック時だけ設定URLを開く | 自動選択しない |
| `granted` + PID changed | ✅ `granted` | ✅ snapshot | ❌ write 0 / `pidReused` | ✅ 明示クリック時だけ設定URLを開く | 古いPIDを使わない |
| `granted` + title/identifier changed | ✅ `granted` | ✅ snapshot | ❌ write 0 / `windowChanged` | ✅ 明示クリック時だけ設定URLを開く | hint不一致を拒否 |

## テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| TC-201 | 同値分割 | 正常系 | permission granted | `AXIsProcessTrusted=true` | permission read | `granted`、理由は空でなく説明可能 | 高 |
| TC-202 | 同値分割 | 異常系 | permission denied | `AXIsProcessTrusted=false` | permission read + operation request | `denied`、write 0、`permissionDenied` | 高 |
| TC-203 | 同値分割 | セキュリティ境界 | wrong bundle | target bundleが許可ID以外 | operation request | `bundleNotAllowed`、write 0 | 高 |
| TC-204 | 同値分割 | 異常系 | application unavailable | fixture processなし | fixture detect / operation | emptyまたは`applicationUnavailable`、write 0 | 高 |
| TC-205 | 境界値 | 異常系 | candidate 0 | candidate配列`[]` | operation request | `windowMissing`、write 0 | 高 |
| TC-206 | 境界値 | 異常系 | candidate 2 | 同じstable hintsのcandidate 2件 | operation request | `ambiguousMatch`、write 0 | 高 |
| TC-207 | エラー推測 | 異常系 | PID reuse | title/identifier同一、PIDのみ変更 | operation request | `pidReused`、write 0 | 高 |
| TC-208 | エラー推測 | 異常系 | window changed | PID同一、title/identifier変更 | operation request | `windowChanged`、write 0 | 高 |
| TC-209 | ユースケース | 正常系 | unique fixture plan | unique Main fixture | move→resize→minimize | requested operationsのみを順序通り適用、Report成功 | 高 |
| TC-210 | 状態遷移 | 境界 | write直前再解決 | 1回目resolve後にcandidate変更 | multi-step operation | 次write前に失敗、後続writeなし、partial report | 高 |
| TC-211 | エラー推測 | 安全性 | force quit / close禁止 | adapter呼出し | safe operation | close/terminate APIを呼ばない | 高 |
| TC-212 | 型境界 | 安全性 | raw reference leak | public result inspection | compile / type review | public型にAXUIElement/NSRunningApplicationを含めない | 高 |
| TC-213 | ユースケース | UI | startup no prompt | app起動、permission denied | app startup | status readだけ、OS設定を開かない | 高 |
| TC-214 | ユースケース | UI | explicit settings click | UI表示済み | 設定を開くclick | click時だけsettings URLをopen | 中 |
| TC-215 | エラー推測 | 安全性 | 同bundle複数process | 許可bundleのprocess候補が2件以上 | fixture detect / safe operation | `.first`を選ばず`ambiguousMatch`またはempty、write 0 | 高 |
| TC-216 | ユースケース | UI | stable Main target | Main/Secondaryを検出済み | 安全なFixture操作 | title `Scene Shelf AX Fixture - Main` + identifier `main`だけを選び、目標frame `(120,140,800,600)`を要求。Mainなしは安全中止 | 高 |

## 状態遷移カバレッジ

| カバレッジ | 対象 | 対応ケース |
|---|---|---|
| 0-switch | denied / granted / unavailable / missing / ambiguous / pidReused / windowChanged / unique | TC-201〜TC-209 |
| 1-switch | permission → detect → resolve → write / permission → denied stop | TC-202, TC-204, TC-209 |
| 無効遷移 | denied→write、non-allowed→write、ambiguous→write、changed→next write、複数process→write | TC-202, TC-203, TC-206〜TC-210, TC-215 |

## カバレッジサマリ

- 正常系: 4件（TC-201、TC-209、TC-214、TC-216）
- 異常・拒否系: 8件（TC-202〜TC-208、TC-215）
- 境界値: 2件（candidate 0/2）
- 状態遷移: 8状態、1-switch 2経路、無効遷移4種
- 安全性・型境界: 5件（TC-211〜TC-216）

## 未カバー・検討事項

- TCC許可済みの実fixture write成否は、環境のpermission実測結果に応じてPASSまたはBLOCKEDと記録する。
- 実環境でのfixtureのAX identifier露出がtitleのみの場合、stable title照合を正本としidentifierは補助hintに留める。
- 画面座標・display mapping・複数displayはP0-3以降。
