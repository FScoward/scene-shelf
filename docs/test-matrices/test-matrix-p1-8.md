# Scene Shelf P1-8 テストマトリクス

## 前提・仕様サマリ

- P1-8当時は一般アプリ候補のread-only列挙とShelf表示だけを扱い、候補から保存・復元・AX writeへ接続しなかった。現行の明示選択保存・復元はP1-9/DR-025の別契約で扱う。
- AX raw referenceはadapter actor内に閉じ、公開値は`AXApplicationProcessSnapshot`、`AXApplicationCandidate`、`AXWindowSnapshot`だけとする。
- permission deniedは候補空、`permissionDenied`、write 0。Scene Shelf自身、Bundle IDなし、UIなし、background-only、windowなしは除外する。
- group keyはBundle IDだけでなくPIDを含む。同Bundleの別processは別候補として残す。

## 認可デシジョンテーブル

| 判断ID | permission | 対象 | UI/background | Bundle ID | window | 期待判断 | 対応TC |
|---|---|---|---|---|---|---|---|
| AUTH-801 | denied | any | any | any | any | `permissionDenied`、候補空、write 0 | TC-801 |
| AUTH-802 | granted | Scene Shelf | UIあり | Scene Shelf ID | あり | 除外、write 0 | TC-802 |
| AUTH-803 | granted | 一般アプリ | UIあり | あり | あり | 候補へ採用 | TC-803 |
| AUTH-804 | granted | process | UIなし | あり/なし | any | 除外 | TC-804 |
| AUTH-805 | granted | background app | any | あり/なし | any | 除外 | TC-805 |
| AUTH-806 | granted | 一般アプリ | UIあり | なし/空 | あり/なし | 除外 | TC-806 |
| AUTH-807 | granted | 一般アプリ | UIあり | あり | なし | 除外 | TC-807 |

## テストケース一覧

| ID | 技法 | 分類 | テスト観点 | 前提条件 | 入力 / 操作 | 期待結果 | 優先度 |
|---|---|---|---|---|---|---|---|
| TC-801 | 認可デシジョン | 異常系 | permission denied | Fake adapter permission denied | catalog request | `permissionDenied`、候補0、write 0 | 高 |
| TC-802 | 同値分割 | セキュリティ境界 | Scene Shelf除外 | Scene Shelf bundle、windowあり | pure normalize | 候補0 | 高 |
| TC-803 | 同値分割 | 正常系 | 通常アプリ採用 | UIあり、Bundle IDあり、windowあり | pure normalize | app name/bundle/PIDとwindow値を保持 | 高 |
| TC-804 | 同値分割 | 除外系 | UIなし除外 | `hasUserInterface=false` | pure normalize | 候補0 | 高 |
| TC-805 | 同値分割 | 除外系 | background-only除外 | `isBackgroundOnly=true` | pure normalize | 候補0 | 高 |
| TC-806 | 同値分割 | 除外系 | Bundle IDなし | `bundleIdentifier=nil` | pure normalize | 候補0 | 高 |
| TC-807 | 境界値 | 除外系 | windowなし | windows=[] | pure normalize | 候補0 | 高 |
| TC-808 | エラー推測 | 識別境界 | 同Bundle別process | same bundle、PID 501/502 | pure normalize | 2候補、IDが異なる | 高 |
| TC-809 | 型境界 | 値保持 | title/identifier/frame/minimized | 一般候補1、window1 | normalize | 全フィールドを値型で保持 | 高 |
| TC-810 | ユースケース | read-only | system catalog uses no writes | permission granted | live catalog request | read attribute only、既存write counter 0 | 高 |
| TC-811 | UI | 入口 | candidate inspection button | Presentation values | render/label boundary | identifier固定、日本語read-only notice | 中 |
| TC-812 | UI | 表示 | grouped candidate list | candidate 2 process | Presentation formatter | app group + window detailsを表示 | 中 |
| TC-813 | 回帰 | Fixture | existing fixture save/restore | existing AX runner | existing fixture operation | 既存write contract不変 | 高 |
| TC-814 | UI／識別境界 | 異常系 | duplicate window rows | same PID/title、identifier=nil、window 2件 | `windowRows` | 2 rows、ID一意、値詳細を保持 | 高 |
| TC-815 | 権限状態遷移 | 安全側 | granted→denied refresh | candidate表示後にpermission denied | `catalogState` | candidates空、権限取消しメッセージ | 最重要 |
| TC-816 | UI文言 | 端末内read-only | title/PID read notice | Presentation boundary | readOnlyNotice | window title/PIDを端末内で読み表示する旨を明示 | 中 |

## 状態×イベントマトリクス

| 現在状態 | catalog click | fixture save | fixture restore | 期待結果 |
|---|---|---|---|---|
| permission denied | ✅ failure + write 0 | ❌ no-op | ❌ no-op | read-only catalogもwriteしない |
| permission granted / no candidates | ✅ empty success | 既存経路 | 既存経路 | candidate UIは空文言 |
| permission granted / candidates shown | ✅ 値を更新 | 既存Fixtureのみ | 既存Fixtureのみ | 候補行自体は操作不可 |

## カバレッジサマリ

- 正常系: 2件（TC-803、TC-809）
- 異常・拒否・除外系: 6件（TC-801、TC-802、TC-804〜TC-807）
- 識別境界: 1件（TC-808）
- UI read-only境界: 5件（TC-811〜TC-816）
- 回帰: 1件（TC-813）
- 自動runner実績: AX runner 20件、Presentation runner 14件（review Green時点）

## 未カバー・検討事項

- 実機で一般アプリを列挙したGUI表示、VoiceOver、候補の大量件数・スクロールは未実施。
- P1-8時点では候補を保存対象へ昇格しなかった。任意アプリへのwriteとPID再利用時のrestore matcherはP1-9/DR-025で明示選択・安全境界を追加済み。複数displayは引き続き対象外。
- `NSRunningApplication.activationPolicy`の実機分類精度はread-only manualで再確認する。
