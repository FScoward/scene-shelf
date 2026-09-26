# DR-024: 一般アプリ候補のread-onlyカタログ境界

## Metadata

- Phase: Phase 1 / P1-8
- Kind: 通常判断（Decision D24）
- Scope: Accessibility read-only discovery and Shelf presentation
- Status: P1-8時点の履歴。候補の明示選択保存・復元はP1-9/DR-025で別境界として追加済み
- Reversible: code, runner, and documentation only; no app launch, AX write, or TCC change

## Decision

1. 一般アプリ候補は、`AXApplicationProcessSnapshot` → `AXApplicationCandidate` のSendable値型境界で返す。候補の識別単位は `bundleIdentifier + processID` とし、同じBundle IDでも別PIDを別groupとして保持する。
2. `AXApplicationCatalogNormalizer`を純粋関数とし、Scene Shelf自身、Bundle IDなし、UIなし、background-only、windowなしの観測を候補から除外する。除外は候補生成だけに適用し、既存Fixtureの限定write契約は変更しない。
3. `AXSystemAdapter.applicationCatalog()`は`AXIsProcessTrusted()`を先に確認し、read attributeだけを列挙する。権限拒否時は`permissionDenied`と空候補を返し、writeを行わない。
4. P1-8当時のShelfには「アプリ候補を確認」ボタンとアプリ単位のgrouped listを置き、候補行は確認用のTextだけとした。現在はP1-9/DR-025で、ユーザーが明示選択した行だけを別の保存・復元操作へ渡す。
5. window表示は生の`AXWindowSnapshot`を直接`ForEach`へ渡さず、Presentation境界で候補ID＋配列indexの`SceneShelfApplicationWindowRow`へ変換する。同一PID・同一title・identifierなしの観測も2行として表示し、SwiftUIの識別子衝突を避ける。
6. `catalogState`を権限状態とcatalog結果の純粋な表示境界とし、grantedからdeniedへ再確認された場合は候補を空にして「権限が取り消された」旨を表示する。read-only noticeにはwindow title/PIDを端末内で読むだけであることを明記する。
7. production adapterはbundle IDなし、Scene Shelf自身、prohibited activation policyをAX application element作成前に除外する。pure normalizerの除外規則はfixture/value型検証用に維持する。

## Why

次に保存対象へ進めるアプリをユーザーがShelf上で確認するには、実AX参照をUIへ漏らさず、アプリ名・Bundle ID・PIDとwindowのtitle・identifier・frame・最小化状態を同じ観測結果として示す必要がある。bundle＋PIDをgroup keyにすれば、同一Bundleの複数processを一つへ誤統合せず、後続の一意照合へ渡す情報を失わない。read-onlyカタログをFixture書込み経路から分離することで、権限不足・曖昧候補の確認機能追加が既存の安全なwrite境界を弱めない。

## Why not

- 一般アプリへそのままmove/resize/minimizeを許可する方式は、P1-8の確認目的を越え、対象アプリ・PID再利用・曖昧一致のwrite安全契約を新たに確定するため採用しない。
- アプリ候補を既存Fixture配列へ混ぜる方式は、保存/復元のbundle限定前提と表示用候補のフィルタ責務を混同するため採用しない。
- Bundle IDだけでgroup化する方式は、同一Bundleの別processを統合して誤ったwindow候補を表示するため採用しない。
- P1-8当時にUIで候補行をButtonにする方式は、確認操作から意図せず保存・復元へ進む経路を作るため採用しなかった。P1-9ではToggleと独立した保存操作で明示選択を要求する。
- 生のwindow identityだけをSwiftUIのIDにする方式は、同一PID・同一title・identifierなしの複数windowを一意に描画できないため採用しない。

## Consequences

- 自動検証では、pure normalizerの除外規則、同Bundle別PID、値型フィールド、permissionDenied＋write 0、Presentationの日本語read-only文言を確認できる。
- 自動検証では、duplicate windowの2行・一意ID、granted→denied時の候補クリアと権限取消しメッセージ、window title/PIDの端末内read-only表示も確認できる。
- P1-8当時は「アプリ候補を確認」でread-only観測だけを表示し、候補を保存対象へ昇格させなかった。現在はカタログ観測自体をread-onlyと説明し、P1-9の明示選択行だけを保存・復元へ渡す。
- Scene Shelf自身はbundle IDで除外される。Fixtureは既存の保存/復元が必要なため、カタログ上の一般候補として表示され得るが、カタログ行からwriteは発生しない。

## Reconsideration conditions

- P1-9/DR-025で、対象bundle allowlist、PID/window matcher、write直前再解決、失敗時write 0を別Decisionとして定義・自動検証済み。今後の変更はこの認可境界を維持する。
- 実機でactivationPolicyだけではUI/background分類が不十分と判明した場合、Accessibility上のwindow有無やLSUIElement等のread-only判定を追加し、normalizerの決定表とrunnerを更新する。
- 複数displayやアプリ内部状態を保存対象へ拡張する場合、P1-8の候補catalogとは別のcapture/restore設計を行う。

## Related tests and evidence

- `Sources/SceneShelfAXTestRunner/main.swift`: P1-8時点のpermission denied、除外、同Bundle別PID、value fieldの20件runner内ケース。
- `Sources/SceneShelfPresentationTestRunner/main.swift`: P1-8時点のread-only notice、button identifier、app/window label、duplicate window row、permission revocationの14件runner内ケース。現行runnerはP1-9選択保存表示を含む15件。
- `docs/test-matrices/test-matrix-p1-8.md`
- `docs/phase1/evidence/P1-8-application-catalog.md`
