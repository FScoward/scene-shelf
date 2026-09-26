# P1-9 明示選択した一般アプリ配置 evidence

更新日: 2026-09-26 JST  
設計判断: [`DR-025`](../../decision-records/DR-025-p1-9-explicit-application-scene-authorization.md)  
テストマトリクス: [`test-matrix-p1-9.md`](../../test-matrices/test-matrix-p1-9.md)

## 判定

P1-9の実装と自動検証はPASS。P1-8 catalogの選択windowだけをSavedSceneへ保存し、保存identity集合をwrite authorization scopeとしてgeneric restoreへ渡す。Fixture限定の既存経路はscopeなし旧契約として維持する。

実機で一般アプリを選択・保存・復元するmanual、アプリ自動起動、PID変更をまたぐ推測は未実施／未実装。

## TDD Red

production変更前に`SceneShelfAXTestRunner`へ認可・generic matcherのケースを追加し、strict buildを失敗させた。

```text
cannot find type 'AXAuthorizationScope' in scope
cannot find 'AXAuthorizationPolicy' in scope
cannot find 'AXApplicationSafetyPolicy' in scope
extra argument 'authorizationScope'
```

Redは次の外部契約を先に固定するものだった。

- selected identityだけがauthorizedで、wrong/unselected targetはwrite 0。
- 同一bundle＋PID＋同title＋identifier=nilの複数windowはambiguousでwrite 0。
- generic requestはoperationごとに再解決し、途中のhint変更後はwriteしない。
- PIDが変わった場合はpidReusedでwrite 0。

## Green実装

- `AXAuthorizationScope`と`AXAuthorizationPolicy`を追加し、requestへ明示選択由来のallowlistを値として渡す。
- `AXApplicationSafetyPolicy`を追加し、generic bundle/PID/hint matcherをFixture matcherから分離した。
- `AXSystemAdapter.windowResult(for:)`でbundle＋PIDのread境界を追加し、`perform`のgeneric scoped pathは各operation前にraw windowを再解決する。
- `SceneShelfRoundTrip`のmatcherを一般bundleへ拡張し、SavedSceneは選択identityだけを保持する。
- AppDelegateにcatalog window checkbox、アプリ配置名入力、選択保存を追加。保存済みscene restoreはapp/process単位でreadし、各requestへsceneの全identity scopeを付与する。
- Presentation境界に選択save/nameのstable identifierと日本語selection labelを追加。
- Core matcherは同bundle＋same PIDへ先に絞り、同hintが別PIDにもある場合でもsame PIDの一意候補をmatchedとする。same PIDなしで別PIDの同hintだけがある場合は`pidReused`とする。
- 最新catalog全体で選択identityの存在・一意性を検証した後、`selectedCandidates`だけをstoreへ渡す。未選択側の重複identityは別選択の保存を妨げない。
- 保存直前catalog failureは`catalogState`経由で候補・selectionを空にし、日本語理由を表示する。同一PID・title・identifierの重複rowはToggleを出さず、一意に識別できない理由を表示する。
- 一般アプリsceneのoverwriteはP1-9対象外とし、AppDelegateとstoreのwrite前判定で明確に拒否する。scene/indexは変更しない。

Focused Green:

```text
SceneShelfAXTestRunner: 26 tests passed
SceneShelfRoundTripTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 15 tests passed
SceneShelfManagementTestRunner: 15 tests passed
SceneShelf (strict): build complete
```

Presentationの`readOnlyNotice`は、候補観測自体がread-onlyであり、端末内のwindow title/PIDを表示し、明示選択したwindowだけを保存・復元へ渡す契約を検証する。

## 自動検証

全runner回帰は`bash scripts/test-all.sh`（専用scratch/module-cache、strict concurrency）で実行した。

全runner回帰:

```text
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 26 tests passed
SceneShelfRoundTripTestRunner: 12 tests passed
SceneShelfP0FourTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 15 tests passed
SceneShelfPersistenceTestRunner: PASS (28 tests)
SceneShelfManagementTestRunner: PASS (15 tests)
SceneShelfSwitchingTestRunner: 13 tests passed
SceneShelf test-all: PASS (8 runners)
```

strict `swift build --disable-sandbox --scratch-path .build-p1-9-final/strict-build -Xswiftc -strict-concurrency=complete`と同条件の`swift test --scratch-path .build-p1-9-final/strict-test`もexit 0。app/fixture bundle build、codesign verify、plist lintはこの証跡更新後の最終bundle生成で実行する。実機launchは行わない。

## 残るmanual境界

- Accessibility許可済みの実機で一般アプリ候補を確認し、windowを選択して名前を保存する操作。
- 保存カードをクリックしたとき、対象アプリが既に起動中かつ同じPIDである場合の表示／退避。
- app終了、PID reuse、同title nil identifier複数でwrite 0と日本語理由が表示されること。
