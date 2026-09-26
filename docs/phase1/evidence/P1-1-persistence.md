# P1-1 persistence evidence

更新日: 2026-09-26 JST
対象: `Scene Shelf` Phase 1 P1-1 create/reload persistence
正本: GitHub Issue #1 Plan revision 1

## 判定

P1-1の自動検証は PASS。Application Support配下を論理rootとする`index.json` + immutable revision構成、再読込時の順序と全SavedScene window data、再起動後のscene ID継続、index fail-closed、revision単位のdiagnostic、revision先行/index最後のartifact公開を専用runnerで確認した。

今回の実機manualでは、保存済み配置の名称・個数がアプリ再起動後に復元され、削除済みのcopyが復活しないことをPASS確認した。TCC/AXによる再起動後の実window復元、任意アプリ、複数display、破損データを実GUIから復旧する操作は未確認であり、PASSを主張しない。

## Red

production変更前に`SceneShelfPersistenceTestRunner`をstrict concurrency付きで実行した。初期runnerは`await reloaded.scenes()`を同期autoclosureへ渡しており、strict concurrency compile errorとなった。

```text
error: call to actor-isolated instance method 'scenes()' in a synchronous main actor-isolated context
error: 'await' in an autoclosure that does not support concurrency
```

このRedはテストコードの並行性境界を検出したもので、保存データはまだ生成していない。runnerを明示的な中間値assertへ修正し、missing revisionケースを追加した。

レビュー対応のbehavioral Redとして、壊れたrevisionが最大ID（`scene-3`）になるfixtureを追加し、旧実装（healthy scenesだけで再commitし、healthy scenesだけで次IDを計算）を一時再現した。新規saveが既存の壊れたrevisionへ衝突し、元index entryも保持できないことを実行時に確認した。

```text
Swift/ErrorType.swift:254: Fatal error: Error raised at top level: SceneShelfCore.ScenePersistenceError.revisionAlreadyExists("scene-3")
```

これは個別revision診断後にsaveしても参照を落とさず、全index entryからIDを採番する必要を示すbehavioral Redである。その後、entry保持・全entry基準ID採番・fsync/rename実装を戻してGreenを再取得した。

## Green

環境:

- macOS Command Line Tools / Apple Swift 6.3.3
- SwiftPM sandboxを避ける専用scratch/module-cache
- Swift 6 strict concurrency complete

実行コマンド:

```sh
rm -rf .build-p1-1-review-final
mkdir -p .build-p1-1-review-final/module-cache .build-p1-1-review-final/spm
CLANG_MODULE_CACHE_PATH="$PWD/.build-p1-1-review-final/module-cache" \
  swift build --disable-sandbox --scratch-path .build-p1-1-review-final/spm \
  -Xswiftc -strict-concurrency=complete \
  --product SceneShelfPersistenceTestRunner
.build-p1-1-review-final/spm/arm64-apple-macosx/debug/SceneShelfPersistenceTestRunner
```

結果:

```text
Build of product 'SceneShelfPersistenceTestRunner' complete!
SceneShelfPersistenceTestRunner: PASS (12 tests)
```

検証内容:

- indexなしのloadはemptyでファイルを作らない
- create→reloadでscene ID、name、order、全window identity/frame/minimizedを保持
- reload後の次createが`scene-2`となりIDを再利用しない
- corrupt/unsupported indexはfail closed、bytesを変更しない
- load failure後のsaveは拒否され、index bytesを変更しない
- save成功後にindexとscene revisionが公開され、一時ファイルを残さない
- corrupt/missing/unsupported revisionはhealthy sceneを妨げずdiagnosticを返し、source fileを保持
- corrupt revisionを読み込んだ後の新規saveでも元index entryを保持し、全entry基準でID衝突を回避
- revision/indexのatomic commitでtemp file、file fsync、rename、destination/directory fsyncを実行
- Application Support初期化失敗時はload/saveともfail closedで、in-memory sceneを作らない

## 実装範囲

- `SceneShelfPersistence`: Application Support root、schema version 1、index/revision Codable、atomic write。
- `InMemorySceneStore`: persistence注入時だけload/saveをdiskへ接続し、Application Support初期化失敗・load失敗を記憶してload/saveを拒否。load時は全index entryを保持し、公開scenesはhealthyだけ、transient card stateは全scene `.stashed`へ戻す。
- `ShelfViewModel`: production既定storeをApplication Supportへ接続し、取得失敗時にin-memory fallbackを行わない。テスト注入storeはin-memoryのまま。load/save warning/errorを日本語statusへ反映し、成功時だけ「ローカルに保存しました」と表示。
- atomic writeは同一ディレクトリtemp、file fsync、`renameatx_np`（revisionは`RENAME_EXCL`）、destination fsync、directory fsyncを実行する。

## Manual PASS（2026-09-26 JST）

- latest bundleをAccessibility一覧から旧登録削除→再追加し、SceneShelfのswitchがonであることを確認した。
- latest app（PID `92305`）でFixtureを検出してsceneを保存し、保存カードと明示的な`…` buttonを確認した。
- 配置名変更、複製、copyの上移動、confirmation後のcopy削除を実機操作で確認した。
- appを停止・再起動（PID `96358`）した後、変更後名のoriginal cardが1件残り、削除済みcopyが復活しないことを確認した。
- 再起動直後・overwrite前に、primaryがread-onlyで`/Users/fumiyasu/Library/Application Support/SceneShelf/index.json`を確認し、schemaVersion 1、scene-1、変更後名、order 0、revision 1の1 entryと一致した。
- その後のoverwrite成功後に確認した最終状態では、同じindexの1 entryがschemaVersion 1、sceneID `scene-1`、name `現在の配置を保存　別の名前`、order 0、revision 2となっていた。

## 残る手動境界

- Accessibility許可済みの別process Fixtureで、保存後再起動してlive AX復元が成功することの確認。
- 任意アプリ、複数display、破損データを実GUIから復旧する操作、quarantineおよびorphan cleanup。
- 実機fsync障害・ディスク容量枯渇・kill -9途中のrecovery。

P1-1自動検証PASSはこれらの手動境界を代替しない。

## P1-4 persistence integrity hardening（2026-09-26 JST）

### Red

故障注入可能な`ScenePersistenceFault.indexCommit`でrevision先書きを成功させた後、index commitを失敗させるケースを先に追加した。旧実装では再起動後の新規saveがindexだけを基準に`scene-2-1.json`を再利用し、`revisionAlreadyExists`となる。また旧delete経路はcleanup errorを`try?`で完全に握り潰していた。semantic invalid revision（`windows=[]`）とinvalid index（duplicate scene ID/order、revision<=0、path separator ID）の実行テストも先行追加した。

### Green / implementation

- `SceneShelfPersistence.nextAvailableSceneNumber(after:)`がindexにないrevision filenamesを含むdisk stateを走査し、save/duplicateのscene ID採番を進める。
- 未参照revisionは自動採用・削除せず、`.orphanRevision` diagnosticと物理ファイルで保持する。既存の同一scene revision採番もファイル名の最大値を避ける。
- revisionの`windows`空配列を`.invalidRevision`として公開scenesから除外する。
- `isValidIndex`のfail-closed契約（ID/order重複、revision非正、path separator）を実行テストで固定した。
- deleteのindex commitは維持し、cleanup failureは`SceneManagementError.cleanupFailed`として日本語UI境界へ伝播する。

P1-4 test matrixは8観点（orphan save/duplicate、semantic invalid、invalid index 4分類、cleanup failure通知）。実行runnerではPersistenceを12→15 tests（新規3 test methods、invalid index method内4分類）へ、Managementを既存cleanup assertion強化を含む14 testsへ更新した。旧P1-1/P1-2/P1-3の記録とmanual claimは変更していない。

### 検証境界

focused/full runner、strict build/test、bundle/codesign/plistを再実行し、次を確認した。

```text
SceneShelfPersistenceTestRunner: PASS (15 tests)
SceneShelfManagementTestRunner: PASS (14 tests)
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 14 tests passed
SceneShelfRoundTripTestRunner: 10 tests passed
SceneShelfP0FourTestRunner: 12 tests passed
SceneShelfPresentationTestRunner: 9 tests passed
SceneShelfSwitchingTestRunner: 13 tests passed
strict swift build: PASS
strict swift test: PASS (compile-only XCTest target in this CLT environment)
scripts/build-app.sh: PASS
codesign --verify --deep --strict: PASS
plutil -lint Info.plist: PASS
```

実ディスク容量枯渇・fsync障害・kill -9途中の再起動復旧、GUI/VoiceOverはmanual境界として残す。commit、push、Issue更新、app launchは行わない。

## P1-5 persistence warning hardening（2026-09-26 JST）

Round3判断: [`DR-022`](../../decision-records/DR-022-atomic-write-publication-boundary.md)

### Red

旧実装へ対する回帰ケースを先に実行し、`cleanupRevisions(for: "foo")`が単純prefix判定で`foo-bar-1.json`まで削除するbehavioral failureを取得した。併せてInt.max採番、empty/duplicate windows commit、load後段採番失敗、orphan scan failureの実行ケースを追加した。

### Green

- cleanupはrevision filenameを`revisionIdentity`で完全一致判定し、scene ID prefix衝突を防止。
- scene/revision採番は`addingReportingOverflow`でInt.maxを検出し、`atomicWriteFailed`でfail closed。save/duplicateはpublish前に次番号をreserveし、publish後overflow throwによるdisk/memory不一致を防止。
- commitはwindows非空・window identity一意を検証し、loadのsemantic validationと整合。
- `loadPersisted`はpersistence load、entry/state構築、scene採番、disk採番をローカル変数で完了してからactorへ反映。後段失敗時は旧scenes/stateを保持。
- orphan scanの`contentsOfDirectory` failureは`try?`で握り潰さず`atomicWriteFailed`へ伝播。
- rename前のdurability failureはdestinationを変更せずthrowし、呼出側の旧index／actor stateを保持する。
- rename後のdurability failureは目的URLを期待dataと再読込比較し、一致したpublished commitだけを成功扱いして呼出側stateを新状態へ収束させる。不一致はfail closedする。

追加・更新ケースを含む結果:

```text
SceneShelfPersistenceTestRunner: PASS (23 tests)
SceneShelfManagementTestRunner: PASS (14 tests)
```

全runner回帰もPASSした（Core 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 23、Management 14、Switching 13）。strict build/test、`scripts/build-app.sh`、`scripts/build-ax-fixture.sh`、codesign verify、Info.plist lintもPASS。pre-rename failureは旧index／memory保持、post-rename durability failureはpublished data一致後の新index／memory収束を確認した。P1-1〜P1-4の既存記録とmanual claimは変更していない。実filesystem permission/容量枯渇、実fsync障害、kill -9 recovery、GUI/VoiceOverはmanual境界に残す。

## AT-2 保存時live snapshot修正（2026-09-26 JST）

### Red

保存時live snapshot境界を先に`SceneShelfAXTestRunner`へ追加し、未実装の`AXSceneCapturePreparation`と`AXSceneCaptureError`を参照する状態でfocused runnerを実行した。旧実装にはこのテスト可能な保存準備境界が存在しないため、次のcompile Redとなった。

```text
error: cannot find 'AXSceneCapturePreparation' in scope
error: cannot find type 'AXSceneCaptureError' in scope
```

これは検出時の`fixtureWindows`をそのまま保存していたViewModelへ、保存時live再取得・欠落／frame nil拒否の公開値型境界が未実装であることを示すRedである。テスト側では既存`candidateSequence`を使い、検出時B座標と保存時A座標を別snapshotとして準備した。

### Green

`SceneShelfAccessibility`へ`AXSceneCapturePreparation`を追加し、保存時に`AXWindowAdapter.fixtureWindows()`を再取得してselected identityを検証するようにした。`ShelfViewModel.saveFixtureScene()`は検出時の候補配列を再利用せず、保存タスク内でこの境界を通る。selected identityの欠落、曖昧一致、frame nilは日本語理由を設定して保存を開始しない。

focused runner:

```text
SceneShelfAXTestRunner: 14 tests passed
```

追加ケース:

| ケース | 結果 |
|---|---|
| 検出B座標→保存準備A座標 | PASS |
| selected identity欠落 | PASS |
| selected frame nil | PASS |
| Main選択時にSecondaryを除外 | PASS |

既存のAX 10ケース、Core、RoundTrip、P0-4、Presentation、Persistence、Management、Switching runnerは全件PASSした。strict `swift build`／`swift test`もPASSした。

### 実装境界と残る手動確認

- 変更対象は`Sources/SceneShelfAccessibility/AXTypes.swift`、`Sources/SceneShelf/AppDelegate.swift`、`Sources/SceneShelfAXTestRunner/main.swift`。
- 保存時snapshotの再取得はlive AX adapterのSendable値型境界で行い、検出時の選択identity集合だけを引き継ぐ。選択対象以外は既存の除外契約を維持する。
- 実macOS AXでFixture Mainを検出後に移動し、保存カードのframeが保存時位置になること、保存後再起動復元、UI上の日本語メッセージ表示はmanual境界であり、本runnerのPASSだけでは主張しない。

### Bundle verification

- `scripts/build-app.sh`: PASS、`.build/SceneShelf.app`を生成
- `codesign --verify --deep --strict --verbose=2 .build/SceneShelf.app`: PASS（valid on disk / designated requirement）
- `plutil -lint .build/SceneShelf.app/Contents/Info.plist`: PASS（OK）
- launch/relaunch、Accessibility設定変更、commit、push、Issue更新は行っていない。

## Mihari Agent Z Round2 QG（2026-09-26 JST）

P1-1/P1-2/P1-3の保存・復元意味は変更せず、AX/UI境界のQGだけを追加検証した。最新の実行数は次のとおりで、過去節の数値は当時の実行記録として保持する。

```text
SceneShelfAXTestRunner: 17 tests passed
SceneShelfPresentationTestRunner: 11 tests passed
```

AX runnerはテスト実行時の`run`呼び出しを自動集計し、current frame nilのmove/resizeをwrite 0／`operationFailed`として検証した。Presentation runnerはcleanup failure後のwarning保持＋refresh要否と、検出／保存／上書き／復元のdiscovery理由を日本語値型境界で検証した。詳細はP1-4 AX/UI evidenceとDR-020を参照する。

## AT-2 手動受け入れ更新（2026-09-26 JST）

修正版をrelaunchした後、Accessibility警告が表示されないことを確認した。ユーザー操作でFixtureを検出してMainを移動し、「検証A」として保存した。その後、再検出を行わずにMainを別位置へ移動し、「検証B」として保存した。

「検証A」をクリックするとAの保存位置へ正しく復元されることを確認し、AT-2 save-time live snapshotをmanual PASSとした。

## D21 persistence diagnostics / runner aggregation（2026-09-26 JST）

### TDD / 実装

- `SceneShelfPresentationTestRunner`へ、missing/corrupt revisionのscene ID・日本語理由、一覧全体failure、安全な再読込controlの境界テストを先行追加した。
- 先行実行2回は共有Coreファイルの同時更新によりSwiftPMが`input file was modified during the build`で停止したため、意図したbehavioral Redとは数えない。Coreの更新停止後にfocused runnerを再実行した。
- `SceneShelfPersistencePresentation`へ診断row変換と独立診断Viewを追加し、破損・欠落したカードが一覧から消えても対象scene IDと理由を表示できるようにした。
- `ShelfViewModel`はload diagnosticsを保持し、診断欄の「保存済み配置を再読込」から再試行する。破損ファイルの自動削除・採用は行わず、restore busy中の再読込は既存診断を保持する。
- `scripts/test-all.sh`は専用cache/scratchでbuild後、8つの独立runnerを最後まで実行し、失敗runner名を集約してexit 1にする。

### 検証境界

- focused Presentation runner、`bash -n scripts/test-all.sh`、`scripts/test-all.sh`を実行済み。test-allは8/8 runner PASS（Core 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 21、Management 14、Switching 13）。strict `swift test`、`scripts/build-app.sh`、codesign verify、Info.plist lintもPASSした。
- 実破損ファイルをGUIで修復した後の再読込、VoiceOverでの診断行読み上げ、実ディスク容量枯渇はmanual境界に残す。
- 詳細なWhy/Why-notは[`DR-021`](../../decision-records/DR-021-persistence-diagnostic-ui-and-test-all.md)、ケースは[`test-matrix.md`](../../test-matrices/test-matrix.md) D21を参照する。

## P1-6 persistence retry and semantic validation（2026-09-26 JST）

- Red: 外部修復後も通常`loadPersisted()`はfail-closedを維持し、明示retryだけが回復すること、duplicate identity revisionが復元対象へ到達しないことを先行追加。
- Green: `retryLoadPersisted()`をAppDelegateの診断再読込へ接続。Application Support初期化失敗時は再読込buttonを出さず、設定確認・再起動を案内。duplicate identityは`invalidRevision`で除外し、`clickDetailed`は`sceneNotFound`でexecutor/writeなし。order Int.maxはindex invalid、save/duplicate orderはpublish前reserve。index不在時もrevision orphanを診断し、初回空ディレクトリは空診断を維持。

```text
SceneShelfPersistenceTestRunner: PASS (28 tests)
SceneShelfManagementTestRunner: PASS (14 tests)
```

通常loadのfail-closed、初期化失敗の再試行不可境界、duplicate revisionのsource保持を維持。atomicWriteのrename後fsync警告は別判断として変更していない。

最終回帰確認では全8 runnerがPASSした（Core 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 28、Management 14、Switching 13）。strict `swift build`／`swift test`、`scripts/build-app.sh`、`codesign --verify --deep --strict --verbose=2 .build/SceneShelf.app`、`plutil -lint`（bundle／Resources）もPASS。実GUI修復後のretry、VoiceOver、実ディスク障害、kill -9 recoveryはmanual境界であり、app launch/relaunch、commit、push、Issue更新は行っていない。

## P1-7 single-instance lock / lost-update safety（2026-09-26 JST）

### Red / Green

独立した2回の`SceneShelfInstanceLock.acquire`とrelease後再獲得をrunnerへ先に追加し、未実装時のcompile Red（`SceneShelfInstanceLock`／`SceneShelfInstanceLockError`未定義）を確認した。`SceneShelfInstanceLock`はApplication Support配下の専用`.instance.lock`を`flock(LOCK_EX | LOCK_NB)`で保持し、2つ目の独立open FDを`alreadyRunning`として拒否する。releaseはunlock/closeのみ行い、lock fileをJSON保存領域へ混ぜない。

AppDelegateはApplication Support root決定→lock獲得→`InMemorySceneStore`／`AXSystemAdapter`生成の順へ変更した。獲得失敗時は日本語警告を表示して`NSApp.terminate`し、保存・AX処理へ進まない。`LSMultipleInstancesProhibited=true`は補助宣言として追加し、実排他はFD lockを正本とする。詳細は[`DR-023`](../../decision-records/DR-023-single-instance-file-lock.md)を参照する。

### 自動検証

```text
SceneShelfPersistenceTestRunner: PASS (27 tests)
```

lock保持中のsave/load、二重獲得拒否、release後再獲得を確認した。P1-7時点の全runnerはCore 6、AX 17、RoundTrip 10、P0Four 12、Presentation 12、Persistence 27、Management 14、Switching 13。`scripts/test-all.sh`、strict `swift build`／`swift test`、`scripts/build-app.sh`、`scripts/build-ax-fixture.sh`、app/fixtureのcodesign verify、Info.plist lintをPASSした。実二プロセス同時起動、GUI警告、kill -9途中のOS lock解放、VoiceOverはmanual/運用境界として残す。commit、push、Issue更新、app launchは行わない。
