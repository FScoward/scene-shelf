# P0-2 real AX boundary evidence

更新日: 2026-09-26 JST

## 判定範囲

これは GitHub Issue #1 の全受入れテスト結果ではなく、P0-2 の Accessibility API 境界検証です。実際に書込み可能な対象は、別processの bundle ID `com.fscoward.SceneShelfAXFixture` とその stable window だけに限定しています。任意のユーザーアプリ、未登録window、force quit、close は操作しません。

## Decision Record

- D4: `com.fscoward.SceneShelfAXFixture` のみを実AX書込み対象にする。
- D5: `AXIsProcessTrusted()`で権限を読むだけにし、OS設定はUIの明示クリックでのみ開く。
- D6: `AXUIElement` と `NSRunningApplication` は `AXSystemAdapter` actorの各呼出し内に閉じ、書込み直前にprocess/windowを再解決する。同bundle processが複数なら`.first`を選ばず`ambiguousMatch`で安全停止する。missing、ambiguous、windowChanged、pidReusedは値型の失敗理由としてwrite 0回で停止する。

Decision Record本体: [`DR-004`](../../decision-records/DR-004-p0-2-fixture-ax-boundary.md)

## TDD Red

P0-2のpackage targetと、空の`SceneShelfAccessibility` placeholderを先に置き、test runnerから未実装の`PermissionState`を参照しました。専用module cache/scratchとSwiftPM内部sandbox無効化を指定したため、production未実装のコンパイル診断まで到達しています。

```text
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-p0-2-red" \
swift run --disable-sandbox \
  --scratch-path "$PWD/.build-spm-p0-2-red" \
  -Xswiftc -strict-concurrency=complete SceneShelfAXTestRunner
exit 1

error: cannot find 'PermissionState' in scope
```

最初のscaffold実行ではfixture targetのsource不足が先に検出されました。これはproduction behavioral RedではないためRed成功とは扱わず、placeholder sourceを追加してから上記の未実装シンボルRedを取得しました。

## Green: pure境界とrunner

`SceneShelfAccessibility`にSendable値型、`AXSafetyPolicy` pure resolver、`AXSystemAdapter` actorを実装しました。`SceneShelfAXTestRunner`は以下を実assertionし、9/9 PASSです。

- permission denied、wrong bundle、candidate 0、candidate 2
- PID再利用、window hint変更
- unique fixtureのmove→resize→minimizeと正確なwrite数
- 次のwrite直前にcandidateが変わった場合のpartial report
- public contractがraw `AXUIElement` / `NSRunningApplication`を返さない型境界

```text
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-p0-2-green" \
swift run --disable-sandbox \
  --scratch-path "$PWD/.build-spm-p0-2-green" \
  -Xswiftc -strict-concurrency=complete SceneShelfAXTestRunner
exit 0

PASS: permission denied performs zero writes
PASS: non-fixture bundle is rejected before writes
PASS: missing candidate performs zero writes
PASS: ambiguous candidates perform zero writes
PASS: PID reuse performs zero writes
PASS: window hint change performs zero writes
PASS: unique fixture plan applies exact requested operations
PASS: write-before-resolve rejects a changed candidate
PASS: public AX contract contains Sendable values only
SceneShelfAXTestRunner: 9 tests passed
```

P0-1の既存runnerも再実行し、6/6 PASSです。

```text
SceneShelfCoreTestRunner: 6 tests passed
```

## 追加Green: discovery reason /副作用 read-back（2026-09-26 JST）

P1-3後のAX/UI品質レビューで、旧`fixtureWindows() -> []`だけでは permission denied、Fixture未起動、同一Bundleの複数processを区別できず、保存・復元UIが`windowMissing`へ誤変換し得ることを確認した。`AXWindowDiscoveryResult`（Sendable値型）と`fixtureWindowResult()`を追加し、live adapterは次のreasonを空候補と一緒に返す。既存のraw `AXUIElement`／`NSRunningApplication`境界は変更していない。

```text
PASS: discovery preserves permission, unavailable, and ambiguous reasons
PASS: save preparation reports discovery failure instead of missing window
SceneShelfAXTestRunner: 14 tests passed
```

同じrunnerのstateful fakeへmove→resize→minimizeの副作用を反映し、操作後に同じadapterからread-backした値をassertした。

```text
PASS: unique fixture plan applies exact requested operations
  read-back: frame=(120,140,800,600), isMinimized=true
```

これは実AX/TCCのread-backではなく、AX adapter値型契約の自動検証である。下記の実AX manual evidenceは`AXOperationReport.appliedOperations`を根拠としており、実AX frameの操作後read-backを取得したとは主張しない。

## Swift 6 strict build / package test

```text
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-p0-2-green" \
swift test --disable-sandbox \
  --scratch-path "$PWD/.build-spm-p0-2-green" \
  -Xswiftc -strict-concurrency=complete
exit 0

CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-p0-2-green" \
swift build --disable-sandbox \
  --scratch-path "$PWD/.build-spm-p0-2-green" \
  -Xswiftc -strict-concurrency=complete
exit 0
```

CLTにはXCTest/Swift Testingモジュールがないため、SwiftPM test targetはcompile-onlyです。behavioral assertionは両CLI runnerで実行しています。`--disable-sandbox`と専用scratch/module-cacheは、このCodexのCLT-only環境でSwiftPM内部sandboxが`sandbox_apply: Operation not permitted`になる境界への対処です。専用pathへの出力隔離は維持し、外部アプリへのアクセス許可を広げるものではありません。

## 手動bundle / 署名 / plist

```text
bash scripts/build-app.sh
exit 0
Built .../.build/SceneShelf.app

bash scripts/build-ax-fixture.sh
exit 0
Built .../.build/SceneShelfAXFixture.app

codesign --verify --deep --strict --verbose=2 .build/SceneShelf.app
exit 0
.build/SceneShelf.app: valid on disk

codesign --verify --deep --strict --verbose=2 .build/SceneShelfAXFixture.app
exit 0
.build/SceneShelfAXFixture.app: valid on disk

plutil -lint .build/SceneShelf.app/Contents/Info.plist
exit 0
.build/SceneShelf.app/Contents/Info.plist: OK

plutil -lint .build/SceneShelfAXFixture.app/Contents/Info.plist
exit 0
.build/SceneShelfAXFixture.app/Contents/Info.plist: OK
```

両scriptは`--disable-sandbox`と明示scratch pathをbuild／show-bin-pathの両方に渡します。fixtureのInfo.plistは固定bundle ID、Main/Secondaryの別process fixture appとして生成されます。

## TCC / 実環境の結果（初回CLI実測）

system probeは`AXIsProcessTrusted()`だけを読み、probe modeでは書込みを呼びません。

```text
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-p0-2-green" \
swift run --disable-sandbox \
  --scratch-path "$PWD/.build-spm-p0-2-green" \
  -Xswiftc -strict-concurrency=complete \
  SceneShelfAXTestRunner --probe-system

SYSTEM permission: denied / アクセシビリティ権限が必要です。設定を開いてScene Shelfを許可してください
SYSTEM AX write: BLOCKED (permission denied; no write attempted)
...
SceneShelfAXTestRunner: 9 tests passed
```

初回CLI probe時点ではTCC未許可のため実AX writeはBLOCKEDでした。設定を変更していません。起動時に`AXIsProcessTrustedWithOptions`を呼ばず、Shelfの「設定を開く」ボタンをユーザーが明示クリックした場合だけSystem Settings URLを開くUI契約にしています。後続のユーザー操作でScene Shelf本体を許可した結果は、末尾の「実AX acceptance PASS」に分離して記録します。

### Launch確認（再実測）

再実測ではLaunchServices起動に成功し、Scene ShelfとFixtureが別processであることをPIDで確認しました。

```text
open .build/SceneShelfAXFixture.app
PID 78539  SceneShelfAXFixture.app/Contents/MacOS/SceneShelfAXFixture

open .build/SceneShelf.app
PID 78541  SceneShelf.app/Contents/MacOS/SceneShelf
```

以前に確認したPID `67492`（Fixture）／`7970`（Scene Shelf）は過去の起動確認値です。上記のPID `78539`（Fixture）／`78541`（Scene Shelf）を最新runtime証跡として採用します。この時点のCLI probeではTCC未許可だったため、実AX writeは実施していません。後続のScene Shelf UI操作結果は末尾に別記します。

### 最新runtimeのCUAアクセシビリティ確認

最新binaryを再起動した状態でCUAアクセシビリティツリーを確認し、Fixtureの別process windowに次を実画面で確認しました。

- title / label: `Scene Shelf AX Fixture - Secondary`
- window identifier: `secondary`
- Scene Shelf process PID: `78541`
- Fixture process PID: `78539`
- Scene ShelfとFixtureは別processとして常駐

この確認はwindowのstable title／identifierがUIツリー上で観測可能であることの証拠です。このサブタスクのprobe時点ではTCC未許可のため、move・resize・minimizeの実書込みは行っていません。後続のユーザー操作による実AX acceptanceは末尾のPASS記録を正とします。

## UI観測契約

Shelfには「アクセシビリティ技術検証」領域を追加し、permission state/reason、許可なしで可能な範囲、対象bundle ID、明示的な設定導線を表示します。権限が許可されるまで「Fixtureを検出」「安全なFixture操作」はdisabledです。Fixture操作はstable title `Scene Shelf AX Fixture - Main` と identifier `main` のMainだけを選び、目標frame `(120,140,800,600)`を使ってmove→resize→minimizeを要求します。Mainが検出できない場合は安全に中止し、失敗理由と適用済み操作数を値型Reportから表示します。

## 初回実測時の残blocker / 後続

- full Xcode GUI test、archive、notarization、App Store配布は未検証。
- TCC許可後の別process fixture実AX writeは末尾の「実AX acceptance PASS」で実施済み。PID/window変更の継続live観測と後処理は別途記録する。
- 任意アプリ操作、Spaces／複数display、永続化はP0-2対象外。

## 追加runtime確認（初回probe時点、2026-09-25 JST）

最新runtimeのPIDを再取得し、対象processだけが別PIDで常駐していることを確認した。

```text
78539 /Users/fumiyasu/Documents/Codex/2026-09-24/t/work/scene-shelf/.build/SceneShelfAXFixture.app/Contents/MacOS/SceneShelfAXFixture
78541 /Users/fumiyasu/Documents/Codex/2026-09-24/t/work/scene-shelf/.build/SceneShelf.app/Contents/MacOS/SceneShelf
```

このサブタスクからのCUA app取得は、`MCP server elicitations can only be requested by the root thread`で拒否された。代替のSystem Events read-only probeも、`UI elements enabled`が`false`で、menu bar/status itemの取得時に「osascriptには補助アクセスは許可されません（-1719）」となった。

したがって、このサブタスクの初回probe時点では、Scene Shelf UIの「権限を再確認」→「Fixtureを検出」→「安全なFixture操作」のユーザークリック相当、Scene Shelf自身のTCC表示、Mainの操作前後frame/read-back、Secondary不変確認を実施できず`BLOCKED`と判定した。CLI `SceneShelfAXTestRunner --probe-system`は別binaryのTCC状態なので、この判定根拠には使用していない。後続のroot CUA／ユーザー操作による実測結果は、末尾の「実AX acceptance PASS」で更新した。

この初回probeではTCC設定変更、Main/SecondaryへのAX write、force quit、closeは行っていない。後続のユーザーUI操作によるMainの3操作結果は、次節の実AX acceptanceに記録する。

## 実AX acceptance PASS（2026-09-25 JST）

その後、ユーザーがmacOSのAccessibility設定でScene Shelfを許可し、Scene Shelf UIから対象Fixtureの操作を実施した。CLIの`SceneShelfAXTestRunner --probe-system`は別binary identityのTCC状態を読むため、以下の判定には使用していない。

- 対象bundle: `com.fscoward.SceneShelfAXFixture`
- 対象window: stable title `Scene Shelf AX Fixture - Main`、identifier `main`のみ
- 別process確認: Scene Shelf PID `78541`、Fixture PID `78539`
- ユーザー観測した`AXOperationReport.appliedOperations`:
  - `move`: `succeeded=true`
  - `resize`: `succeeded=true`
  - `minimize`: `succeeded=true`

したがって、P0-2の実AX acceptance（Mainに対するmove→resize→minimize）はPASSとする。対象解決がstable title／identifierのMainに限定されているため、SecondaryへのAX writeは発生していない。未登録window、他アプリ、force quit、closeも操作していない。

後続のCUA inspectionでMainが再表示された可能性があるため、後処理後の画面状態を「minimized状態の保持」の証拠には使わない。本PASSは、操作時点でReportの3操作すべてが成功したというユーザー観測に基づく。

### 追加のCoreGraphics read-only確認

AX writeを伴わない`CGWindowListCopyWindowInfo` probeでも、同じPIDのwindow boundsを取得した。`kCGWindowIsOnscreen`は`optionAll`／`optionIncludingWindow`のどちらの辞書にも含まれず、`optionOnScreenOnly`にもFixtureの2 windowが含まれなかったため、CoreGraphicsだけから`onscreen=false`を断定しない。

```text
Scene Shelf PID: 78541
Fixture PID: 78539
title=Scene Shelf AX Fixture - Secondary
  bounds: X=600 Y=748 Width=360 Height=252
  kCGWindowIsOnscreen: <nil>
title=Scene Shelf AX Fixture - Main
  bounds: X=16 Y=869 Width=108 Height=99
  kCGWindowIsOnscreen: <nil>
```

Mainのboundsが通常frameではなく`108x99`の縮退表示になっていることは確認できるが、これは補助的なread-only観測であり、上記の実AX operation reportのPASS判定を置き換えない。

## QG Round2 runner count / nil-frame boundary（2026-09-26 JST）

Round2でAX fakeの`move`/`resize`にframeがない場合を追加検証した。`operationFailed`、`appliedOperations`空、write数0、read-back frame nilを同時にassertし、runnerのsummaryは`run`呼び出し数を実行時集計する契約へ変更した。

```text
PASS: move and resize with unavailable frame perform zero writes
SceneShelfAXTestRunner: 17 tests passed
```

この17件はSwiftPMのstateful fake／値型契約の実行数であり、実AX/TCCの追加read-backではない。実AX acceptance PASSの根拠は上記のユーザー観測済み`AXOperationReport`で、Round2は実アプリを起動していない。
