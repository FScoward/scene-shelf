# P1-2 scene management evidence

更新日: 2026-09-26 JST
対象: `Scene Shelf` Phase 1 P1-2 scene management
正本: GitHub Issue #1 Plan revision 1
設計判断: [`DR-013`](../../decision-records/DR-013-p1-2-scene-management.md)

## 判定

Coreの管理契約と永続化境界は自動検証 PASS。rename、overwrite、duplicate、delete、上下移動、busy拒否、再起動後reload、永続化失敗時の不変性、delete cleanup失敗時のorphan保持、overwrite失敗後にorphanを保持したままrev3へ再試行できることを確認した。SceneShelf本体のSwiftUI/AppKit UIもstrict concurrencyでbuildでき、明示的な`…` Menu、inline rename、confirmation delete、操作statusを含む。

今回の実機manualでは、Accessibility再登録、rename・duplicate・上下移動・confirmation delete、再起動後の一覧復元、overwrite後のMain位置/size復元をPASS確認した。VoiceOver、端での移動、busy/error GUI、任意アプリ、複数displayは未確認であり、PASSを主張しない。

## Red

production管理実装の前に `SceneShelfManagementTestRunner` を追加し、strict concurrency付きtarget buildを実行した。未実装の公開契約が意図どおり compile Red になった。

```text
error: cannot find type 'SceneManagementError' in scope
error: value of type 'InMemorySceneStore' has no member 'rename'
error: value of type 'InMemorySceneStore' has no member 'overwrite'
error: value of type 'InMemorySceneStore' has no member 'duplicate'
error: value of type 'InMemorySceneStore' has no member 'delete'
error: value of type 'InMemorySceneStore' has no member 'move'
```

その後、actor-isolated値を同期autoclosureへ直接渡していたassertionを中間値へ直し、production実装を追加してGreenへ進めた。

## Green

実行環境:

- macOS Command Line Tools / Apple Swift 6.3.3
- Swift 6 strict concurrency complete
- SwiftPMの専用scratch/module-cache、必要なbuildでは`--disable-sandbox`

管理runner:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/scene-shelf-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/scene-shelf-swift-cache \
swift build --product SceneShelfManagementTestRunner
.build/arm64-apple-macosx/debug/SceneShelfManagementTestRunner
```

```text
PASS: rename trims and persists metadata
PASS: rename rejects blank and missing scenes
PASS: overwrite creates a revision without changing targets
PASS: overwrite rejects an incomplete live snapshot without mutation
PASS: duplicate gets a unique deep-copied stashed scene
PASS: delete requires confirmation and protects active scenes
PASS: delete keeps index commit when revision cleanup fails
PASS: move persists order and rejects edges
PASS: management operations reject while restore is busy
PASS: restart reloads management results
PASS: persistence failure leaves memory and index unchanged
PASS: overwrite skips orphan revisions on retry
SceneShelfManagementTestRunner: PASS (12 tests)
```

既存runnerとの回帰確認:

- `SceneShelfCoreTestRunner`: 6 tests passed
- `SceneShelfRoundTripTestRunner`: 8 tests passed
- `SceneShelfP0FourTestRunner`: 12 tests passed
- `SceneShelfPresentationTestRunner`: 8 tests passed
- `SceneShelfPersistenceTestRunner`: 12 tests passed
- `swift test --disable-sandbox --scratch-path /private/tmp/scene-shelf-test-spm -Xswiftc -strict-concurrency=complete`: build/test target PASS

配布用bundle:

- `scripts/build-app.sh`: PASS、`.build/SceneShelf.app`を生成
- `codesign --verify --deep --strict .build/SceneShelf.app`: PASS
- `plutil -lint .build/SceneShelf.app/Contents/Info.plist`: `OK`
- ad-hoc署名（`TeamIdentifier=not set`）のため、実機で再build後はAccessibility登録を再確認する必要がある

## Manual PASS（2026-09-26 JST）

- latest bundleをAccessibility一覧から旧登録削除→再追加し、SceneShelfのswitchがonであることを確認した。latest app PIDは`92305`。
- Fixtureを検出してsceneを保存し、保存カードと明示的な`…` buttonが表示されることを確認した。
- 配置名変更に成功し、複製、copyの上移動、confirmation後のcopy削除を実機操作で確認した。
- appを停止・再起動（PID `96358`）し、変更後名のoriginal cardが1件残り、削除済みcopyが復活しないことを確認した。
- Fixture Mainを別位置・sizeへ変更して「現在の配置で上書き」を実行し、その後Mainを別位置へ移動してcardをクリックすると、上書き時の位置・sizeへ戻ることを確認した。
- overwrite成功後のprimary read-only最終観測では、`/Users/fumiyasu/Library/Application Support/SceneShelf/index.json`の1 entryがsceneID `scene-1`、name `現在の配置を保存　別の名前`、order 0、revision 2となっていた。revision 1は再起動直後・overwrite前の観測である。

## 実装範囲

- `SceneShelfPersistence`: index-only atomic commit、revision commitの再利用、exact scene IDに限定した次revision走査、delete後revision cleanupのbest-effort、検証用index/cleanup failure注入境界。
- `InMemorySceneStore`: trim付きrename、同一ID revision+1 overwrite、target identity集合を変えないlive snapshot検証、deep-copy duplicate、confirmation付きdelete、上下移動、busy拒否、永続化成功後のみmemory更新。
- `ShelfViewModel`: 各管理操作をactorへ委譲し、成功時だけrefresh。失敗時はカードmemoryをrefreshせず日本語statusを表示。overwriteはAX adapterからlive Fixture snapshotを取得する。
- `ShelfView`: 保存カード本体の表示/退避クリックを維持し、常時クリック可能な`…` Menu（名前変更、現在の配置で上書き、複製、上へ、下へ、削除）、inline rename、confirmation dialog、accessibility label/identifierを追加。

## 残る手動境界

- index commit失敗でrev2 orphanが残った後、再起動してもorphanを現在として採用せず、再overwriteがrev3へ成功すること。
- VoiceOverでカード本体と`…` Menuのラベル/identifierが操作可能であること。
- 端での上下移動、busy中の管理操作拒否、対象欠落・PID再利用などのerror GUI表示。
- 任意アプリ、複数display、破損データを実GUIから復旧する操作。

自動検証PASSは、上記の実GUI/実AX境界を代替しない。

## D19 QG管理操作境界（2026-09-26 JST）

- `SceneShelfManagementTestRunner`へpartiallyRestored sceneのconfirmed delete拒否、restore busy中のsave/rename/overwrite/duplicate/delete/move全拒否、memory/cards/index不変、single/last reorder境界、`loadPersisted` busy拒否を追加した。
- Redでは旧実装の`loadPersisted` busy中リセットを1ケースで再現。GreenではManagement 14/14となり、partial sceneは`sceneActive`、busy操作は`busy`で拒否された。
- `SceneRoundTripTestRunner`のcapture duplicate/unregistered、identifier nil matching classを含む全回帰と、Persistence 15/15、strict build/test、bundle/codesign/plistをPASSした。
- D19/`DR-019-qg-state-transition-safety.md`、test matrixへWhy/Why-notと状態遷移契約を記録した。実GUIのbusy/error表示、実ディスク障害、VoiceOverは未確認。launch/relaunch、Accessibility設定変更、commit、push、Issue更新は行っていない。
