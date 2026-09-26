# DR-004: P0-2のfixture限定AX境界

## 目的

P0-2でmacOS Accessibility APIの実環境境界を確認しつつ、Scene Shelfがユーザーの任意アプリや未登録windowへ誤って書込みしないことを保証する。

## 制約・確認済み事実

- 正本は GitHub Issue #1 Plan revision 1。Phase 0のP0-2は別process fixtureを対象にしたpermission/AX技術検証である。
- full Xcodeは導入しない。CLT + SwiftPM + 手動`.app` bundleを使う。
- Accessibility permissionはTCC状態に依存する。アプリからOS設定を勝手に変更せず、`AXIsProcessTrusted()`を読むだけにする。
- `AXUIElement`と`NSRunningApplication`はSendable値型ではないため、保存・actor外送出・UI渡しを禁止する。

## 選択

許可対象をbundle ID `com.fscoward.SceneShelfAXFixture`に固定し、stable titleとidentifierで一意照合する。同bundleのprocessが複数存在する場合は`.first`を選ばず`ambiguousMatch`で停止する。各AX writeの直前にfixture processとwindowを再解決し、PID/hintが変わった場合はwriteせず値型FailureReasonを返す。Shelf UIの手動操作対象はstable Main title `Scene Shelf AX Fixture - Main` / identifier `main`に固定し、目標frameは`(120,140,800,600)`とする。fixtureは2つのstable windowを持つ別process `.app`として手動bundle化する。

## Why

- fixture限定なら、実AX/TCCを検証しながら任意ユーザーアプリへの副作用を遮断できる。
- 同一bundleの複数processを曖昧として止めることで、`.first`選択によるPID取り違えを防げる。
- write直前再解決なら、保存したraw AX参照・古いPID・window順序に依存しない。
- pureなSafetyPolicy/Matcherとactor adapterを分けることで、TCC未許可でもmissing/ambiguous/PID reuse/window changedのwrite-0契約をCLI runnerで検証できる。

## Why not

- 任意のbundle IDを受け付ける方式は、P0-2の安全境界を実環境で証明できず、誤操作の影響範囲が大きい。
- raw AXUIElementをsnapshotへ保持する方式は、Sendable境界を破り、window変更後の stale reference操作を誘発する。
- `AXIsProcessTrustedWithOptions`で起動時promptを出す方式は、ユーザーの明示clickなしにOS設定導線を発生させるため採用しない。
- 失敗時に自動retryする方式は、対象変化を見落とし、意図しないwindowへの連続writeを招くため採用しない。

## 帰結

- 実fixtureが起動中かつTCC許可済みなら、unique windowへのmove/resize/minimizeを検証できる。
- TCC未許可またはfixture未起動なら、permission/read-onlyまたはwrite-0のBLOCKED証跡を残す。
- 任意ユーザーアプリ、fixture以外のwindow、force quit/closeはP0-2の対象外である。

## 再検討条件

- Issueの承認済み要件がfixture限定から変わった場合。
- P0-3で複数display mappingを追加する場合。
- full Xcode/TCC付きの実環境で別process adapterの契約が変わる証拠が得られた場合。

## 関連テスト

- `../test-matrices/test-matrix-p0-2.md` TC-201〜TC-214
- `SceneShelfAXTestRunner` の permission denied / wrong bundle / missing / ambiguous / PID reuse / window changed / unique plan
