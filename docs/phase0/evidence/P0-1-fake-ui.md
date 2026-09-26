# P0-1 fake UI evidence

更新日: 2026-09-25 JST

## 判定範囲

これは GitHub Issue #1 の全受入れテスト結果ではなく、P0-1 の CP-1 技術証拠です。確認対象はメニューバー入口、縦型 fake Shelf、`開発`/`会議`カード、`SceneCoordinator` の busy 拒否です。実 AX、TCC、ディスク永続化、成功した A→B 切替は後続工程です。

## TDD の証跡

### Red（環境境界のみ。behavioral Redは未取得）

先に `Package.swift`、test target、`SceneCoordinator` 契約を置き、production の Coordinator 実装がない状態で `swift test` を実行しました。初回は exit 1 でしたが、CLT の既定 module cache が書き込み不可でmanifest compileが止まり、production未実装のbehavioral診断には到達していません。

```text
error: unable to open output file .../.cache/clang/ModuleCache/...: Operation not permitted
error: failed to build module 'Swift'
```

この exit 1 は環境境界であり、TDDのbehavioral Red成功として扱いません。behavioral Redの実行証跡は未取得です。以降は `CLANG_MODULE_CACHE_PATH` と専用 scratch path を使い、同じ制約を再現可能にしました。さらにSwiftPMの内部subprocess sandboxがこのCLT-only Codex環境では `sandbox_apply: Operation not permitted` になるため、Green以降の全SwiftPM CLIは `--disable-sandbox` を明示します。これは外部アプリへのアクセス許可を広げる判断ではなく、専用scratch/module-cache pathへ出力を隔離した上でSwiftPM内部の実行境界だけを外す環境対処です。

### Green

CLT では `XCTest` と `Testing` の Swift モジュールが配布されていないため、SwiftPM test target は compile-only とし、実 assertion は `SceneShelfCoreTestRunner` に分離しました。

```text
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-local" \
swift test --disable-sandbox --scratch-path "$PWD/.build-spm-local" \
  -Xswiftc -strict-concurrency=complete
exit 0

CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-local" \
swift run --disable-sandbox --scratch-path "$PWD/.build-spm-local" \
  -Xswiftc -strict-concurrency=complete SceneShelfCoreTestRunner
exit 0

PASS: fake scenes keep the approved display order
PASS: stashed card click completes as displayed
PASS: displayed card click completes as stashed
PASS: busy same card is rejected without a second operation
PASS: busy different card is rejected and not queued
PASS: empty scenes return a safe empty shelf result
SceneShelfCoreTestRunner: 6 tests passed
```

## CLI build gate

```text
swift build --disable-sandbox --scratch-path "$PWD/.build-spm-local" \
  -Xswiftc -strict-concurrency=complete
exit 0

./scripts/build-app.sh
exit 0
Built .../work/scene-shelf/.build/SceneShelf.app
```

`SceneShelf.app` は `.build/SceneShelf.app/Contents/MacOS/SceneShelf` と `Contents/Info.plist` を含み、ad-hoc codesign を適用しています。`scripts/build-app.sh` は `.build-spm-app` を明示的なSwiftPM scratch pathとして使用し、release buildと`--show-bin-path`の両方へ `--disable-sandbox` を渡します。

修正版scriptの再検証:

```text
./scripts/build-app.sh
exit 0
Built .../work/scene-shelf/.build/SceneShelf.app

codesign --verify --deep --strict --verbose=2 .build/SceneShelf.app
exit 0
.build/SceneShelf.app: valid on disk
.build/SceneShelf.app: satisfies its Designated Requirement

plutil -lint .build/SceneShelf.app/Contents/Info.plist
exit 0
.build/SceneShelf.app/Contents/Info.plist: OK
```

## 起動確認

```text
open .build/SceneShelf.app
pgrep -fl '/SceneShelf.app/Contents/MacOS/SceneShelf'
77966 .../.build/SceneShelf.app/Contents/MacOS/SceneShelf
```

プロセスは確認時点で終了せず常駐しました。メニューバーの実クリック、Shelf のスクリーンショット、VoiceOver の実環境確認は親タスクの CP-1 手動確認に残しています。

## 実装された契約

- `開発` → `会議` の順序を固定。
- `しまい済み` → `準備中` → `表示中`、再クリックで `表示中` → `準備中` → `しまい済み`。
- `preparing` 中の同一／別カードクリックは即時 `busyRejected`、キューなし。
- scene が空の場合は空 Shelf と `emptyShelf` を返し、クラッシュしない。
- SwiftUI カードへ日本語 accessibility label と安定 identifier を付与。

## 手動クリック観測契約

- `SceneShelfAppDelegate` は fake operation に決定的な400ms delayを注入する。
- `ShelfViewModel.click` はCoordinatorの`click`を開始した直後に一度yieldし、actorの途中snapshotをrefreshしてからoutcomeをawaitし、完了後に最終snapshotをrefreshする。UI側で状態を二重管理しない。
- そのためShelfを開いて同じカードを短時間に2回クリックすると、1回目は`準備中`、2回目は`別の操作を処理中です`、完了後は`表示中`または`しまい済み`を観測できる。別カードへの2回目クリックも同様に拒否され、キューには積まれない。
- メニューバーからShelfを開くこと、上記の状態表示、VoiceOver treeの実観測は親タスクのCP-1手動確認で完了判定する。

## 未検証・後続

- full Xcode の GUI test、archive、notarization、App Store 配布。
- Accessibility 権限、別 process の AX window 列挙・移動・resize・最小化。
- 複数ディスプレイ、ディスク永続化、完成形 scene CRUD、成功した A→B 切替。

## UI観測修正後の再検証

`ShelfViewModel` の途中snapshot refreshと400ms fake operation delayを追加した後、次を再実行しました。

```text
swift run --disable-sandbox --scratch-path .build-spm-ui \
  -Xswiftc -strict-concurrency=complete SceneShelfCoreTestRunner
exit 0
SceneShelfCoreTestRunner: 6 tests passed

./scripts/build-app.sh
exit 0
Built .../.build/SceneShelf.app

codesign --verify --deep --strict --verbose=2 .build/SceneShelf.app
exit 0

plutil -lint .build/SceneShelf.app/Contents/Info.plist
exit 0
```

手動クリックの期待観測は、1回目のクリック直後に`準備中`、400msの処理中に同一／別カードをクリックすると`別の操作を処理中です`、完了後に`表示中`または`しまい済み`です。実画面のCP-1判定は親タスクで行います。
