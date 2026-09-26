# P1-8 一般アプリ候補 read-only カタログ evidence

更新日: 2026-09-26 JST
設計判断: [`DR-024`](../../decision-records/DR-024-p1-8-read-only-application-catalog.md)
テストマトリクス: [`test-matrix-p1-8.md`](../../test-matrices/test-matrix-p1-8.md)

## 判定

P1-8時点の自動検証はPASS。一般アプリの候補をSendable値型へ正規化し、Scene Shelf自身・Bundle IDなし・UIなし・background-only・windowなしを除外する。同一Bundle IDの別PIDは別groupとして残る。P1-8当時のShelf UIには「アプリ候補を確認」button、grouped list、候補確認が保存・復元へ未接続である旨の日本語説明を追加した。現行の明示選択保存・復元はP1-9/DR-025で別境界として追加済みである。

P1-8当時はread-onlyカタログであり、候補を保存対象へ昇格する機能、任意アプリへのwrite、実機での一般アプリ列挙manualは未実施だった。現行のP1-9では、明示選択した対象だけを保存・復元へ渡す認可境界を自動検証している。既存Fixture限定のsave/restoreとwrite直前再解決は維持している。

## TDD Red

production追加前に`SceneShelfAXTestRunner`へ次の契約を追加し、未実装のためstrict buildを失敗させた。

```text
cannot find type 'AXApplicationProcessSnapshot' in scope
cannot find type 'AXApplicationCatalogResult' in scope
cannot find 'AXApplicationCatalogNormalizer' in scope
cannot find 'sceneShelfBundleIdentifier' in scope
```

Presentation側でも、formatter未実装のため次を確認した。

```text
cannot find 'SceneShelfApplicationCatalogPresentation' in scope
```

これは新しい公開値型・純粋normalizer・Presentation境界が未実装であることを示すbehavioral/compile Redであり、既存Fixture runnerの失敗ではない。

## Green実装

- `AXTypes.swift`: process observation、candidate、catalog result、pure normalizer、Scene Shelf bundle除外、adapterのread-only default boundary。
- `AXSystemAdapter.swift`: permission read後に`NSWorkspace`のrunning applicationを列挙し、AX attribute readだけでwindow snapshotを生成。SetAttributeValue/terminate/closeは呼ばない。bundle IDなし、Scene Shelf自身、prohibited activation policyはAX query前に除外する。
- `SceneShelfApplicationCatalogPresentation.swift`: button/list identifier、端末内window title/PIDのread-only notice、app/window value formatter、候補ID＋indexの一意window row、権限状態を反映するcatalog state。
- `AppDelegate.swift`: P1-8当時は`inspectApplicationCandidates()`と「一般アプリ候補（読み取り専用）」grouped listを表示し、candidate行はTextだけでsave/restore actionなしだった。現行はP1-9で、選択Toggle・名前入力・選択対象だけの保存を追加している。permission再確認がdeniedになった場合は候補を即時クリアし、権限取消しメッセージを表示する。window行はPresentation row経由で描画する。
- runners: AX fake adapterでpermission/write 0、除外規則、同Bundle別PID、value fields。Presentation runnerでread-only文言と表示値を検証。

## レビュー修正 TDD Red / Green（2026-09-26 JST）

レビュー指摘をrunnerの公開境界へ先に追加し、production変更前に次のRedを取得した。

```text
SceneShelfApplicationCatalogPresentation has no member `windowRows`
SceneShelfApplicationCatalogPresentation has no member `catalogState`
```

Redケースは、同じPID・同じtitle・identifierなしの2 windowを2行かつ一意IDで表示すること、grantedで候補を表示した後にdeniedへ再確認すると候補を空にし「権限が取り消された」と表示することを確認するものだった。read-only noticeの端末内title/PID文言も同時に先行assertした。

最小実装後のfocused Green:

```text
swift build --disable-sandbox --scratch-path .build-p1-8-review-green/spm \
  --product SceneShelfPresentationTestRunner -Xswiftc -strict-concurrency=complete
SceneShelfPresentationTestRunner: 14 tests passed
```

この修正は表示と候補状態だけに閉じ、Fixture限定save/restoreとAX write経路を変更していない。

## 自動検証

Focused Green:

```text
swift build --disable-sandbox --scratch-path .build-p1-8-green/spm \
  --product SceneShelfAXTestRunner -Xswiftc -strict-concurrency=complete
SceneShelfAXTestRunner: 20 tests passed

swift build --disable-sandbox --scratch-path .build-p1-8-review-green/spm \
  --product SceneShelfPresentationTestRunner -Xswiftc -strict-concurrency=complete
SceneShelfPresentationTestRunner: 14 tests passed
```

既存AX fixtureの操作テスト、Scene Shelfのsave/restore、P1-1以降のrunnerは全回帰で再実行する。最終結果は親タスクの全runner/build evidenceへ追記する。

### 全runner回帰（2026-09-26 JST）

`bash scripts/test-all.sh`を専用scratch/module-cacheとSwift 6 strict concurrencyで実行し、8/8 runnerがPASSした。

```text
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 20 tests passed
SceneShelfRoundTripTestRunner: 10 tests passed
SceneShelfP0FourTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 14 tests passed
SceneShelfPersistenceTestRunner: PASS (28 tests)
SceneShelfManagementTestRunner: PASS (14 tests)
SceneShelfSwitchingTestRunner: 13 tests passed
SceneShelf test-all: PASS (8 runners)
```

strict `swift build`、strict `swift test`、`scripts/build-app.sh`、`scripts/build-ax-fixture.sh`、ad-hoc codesign verify、app/fixture `Info.plist` lintを実行し、いずれもexit 0だった。実機launchは行っていない。

## 手動境界・残課題

- 実機で「アプリ候補を確認」をクリックして一般アプリのgrouped listを確認するmanualは未実施。
- Accessibility permission denied/grantedの実機カタログ表示、VoiceOver、候補リスト大量件数のスクロールは未実施。
- P1-8当時は任意アプリへの保存・復元・move/resize/minimizeを意図的に未接続とした。現行P1-9では、候補から明示選択した対象だけを保存・復元するallowlist/matcher/write契約をDR-025として追加済み。実機での一般アプリ選択保存・restoreは未実施。
