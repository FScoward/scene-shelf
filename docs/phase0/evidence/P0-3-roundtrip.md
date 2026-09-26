# P0-3 roundtrip evidence

更新日: 2026-09-25 JST
対象: `SceneShelf` Phase 0 P0-3
正本: GitHub Issue #1 Plan revision 1

## 判定

Coreの自動検証は PASS。in-memory capture、選択対象だけの保存、空選択拒否、表示時の
`unminimize → move → resize`、再クリック時の登録対象だけの `minimize`、除外対象への
write 0、`stashed ↔ displayed` 往復を `SceneShelfRoundTripTestRunner` で確認した。

P0-3の実AX手動往復は、2026-09-25 JSTにユーザー操作で実施した。最新Scene ShelfをAccessibility一覧へ追加して許可後、Fixture Mainだけを登録し、Secondaryを除外した保存カードを作成した。保存カードのクリックで表示、再クリックで退避し、Secondaryが動かないことを確認した。P0-3のCP-3はPASSとする。ただし、これはP0-3の対象範囲の確認であり、real AXの全AT PASSやP0-4の曖昧/部分成功を意味しない。

## Red / Green

### Red

P0-3開始時点の実装確認では、P0-2のUIにFixture検出と単発の固定操作はあったが、現在配置の選択・除外、in-memory scene保存、保存カードの表示/退避往復を結ぶUI経路がなかった。対象変更を先に検証可能にするため、`SceneShelfRoundTripTestRunner` の8ケースをP0-3契約として用意した。Red段階の対象は「未実装の往復契約」であり、real AXへの書き込みは行っていない。

この作業セッションでは、別作業で先行生成されていた `SceneRoundTrip.swift` と
`SceneShelfRoundTripTestRunner` が作業ツリーに存在したため、初期Redの失敗ログを再実行可能な形では再現できなかった。再現できない失敗をPASS/FAILとして捏造せず、以下に実行可能なGreen証跡と、P0-3 UIのreal AX manual確認で観測できなかった境界を記録する。

### Green

環境:

- macOS Command Line Tools / Swift 6.3.3
- SwiftPMのsandbox制約を避けるため、リポジトリ内scratch/module cacheを指定
- XCTest/Swift Testingは使用せず、runnerの実assertionを使用

実行コマンド:

```sh
mkdir -p .build-p0-3-ui/module-cache .build-p0-3-ui/spm
CLANG_MODULE_CACHE_PATH="$PWD/.build-p0-3-ui/module-cache" \
  swift build --disable-sandbox \
  --scratch-path "$PWD/.build-p0-3-ui/spm" \
  -Xswiftc -strict-concurrency=complete

CLANG_MODULE_CACHE_PATH="$PWD/.build-p0-3-ui/module-cache" \
  .build-p0-3-ui/spm/arm64-apple-macosx/debug/SceneShelfRoundTripTestRunner
```

結果:

```text
PASS: capture stores selected fixture windows only
PASS: empty selection is rejected without storing a scene
PASS: blank scene name uses the Fixture default
PASS: display plan restores saved frame after unminimize
PASS: hide plan minimizes registered windows only
PASS: excluded and unregistered windows produce zero restore writes
PASS: roundtrip transitions stashed to displayed and back
PASS: failed restore keeps the saved scene stashed
SceneShelfRoundTripTestRunner: 8 tests passed
```

併せて既存runnerを再実行した。

```text
SceneShelfCoreTestRunner: 6 tests passed
SceneShelfAXTestRunner: 10 tests passed
```

`SceneShelfAXTestRunner` では、P0-3の表示経路で追加した `unminimize` が fixture限定のAX契約で成功し、権限拒否・bundle外・missing・ambiguous・PID再利用・window変更ではwrite 0となることも確認した。これはfake AX値型runnerの結果であり、P0-3実AX手動往復の代替ではない。

## 実装範囲

- `SceneShelfCore` に値型の `SceneWindowSnapshot`、`SavedScene`、`SceneRestorePlan` と `InMemorySceneStore` を置いた。
- 保存時は検出候補と選択identityを突き合わせ、選択対象だけをsceneへ保持する。空選択は拒否し、disk I/Oは行わない。
- 表示カードのクリックは、保存時の状態が `stashed` なら `unminimize → move → resize`、`displayed` なら `minimize` を登録対象だけへ送る。
- UIではFixture検出後にMain/Secondaryを個別toggleでき、既定名は `Fixture配置`。保存カードは通常のクリックで往復する。
- `SceneShelfAccessibility` のlive AX actorは既存のfixture限定・write直前再解決境界を維持し、Coreへraw `AXUIElement`を返さない。
- 既存のP0-1 fakeカード、coordinator、P0-2権限診断/単発検証UIは残した。

## 未実施・残課題

- Scene Shelf UIから別process Fixtureを実際に保存し、Mainを除外した状態でSecondaryだけを往復する手動real AX確認。
- P0-4の曖昧一致、部分成功、失敗理由のカード表示。
- disk persistence、再起動後復元、複数display、任意アプリ対応、scene CRUD。
- P0-4のsame-title/identifier duplicate window、PID再利用、部分成功のreal AX手動確認。
- このビルドを再署名して起動する場合、Accessibility許可がアプリ署名/状態に依存して再確認を求められる可能性がある。今回のP0-3手動確認の許可状態を、別ビルドのP0-4証跡へ自動継承したとは扱わない。
