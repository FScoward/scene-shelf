# Issue #1 更新コメント案

以下を [FScoward/scene-shelf Issue #1](https://github.com/FScoward/scene-shelf/issues/1) に追記する。

```text
## 保存済み配置一覧のStage Manager風プレビュー

保存済み配置一覧を、保存したウィンドウのframeから生成するサムネイル棚へ更新しました。

- 実スクリーンショットは取得せず、SavedScene.windowsのframeを全体union基準で0...1へ正規化
- 負座標・ゼロサイズ・空配置を安全に処理
- unionのアスペクト比を保持して100×70のサムネイルへaspect-fit
- 複数ウィンドウは矩形を重ねて表示
- 主クリック範囲、名前変更、ellipsis管理メニューの既存アクセシビリティ識別子と操作を維持
- 表示中配置はaccent border/indicatorで強調
- Reduce Motion時は状態変化アニメーションを抑制

検証:

- `scripts/test-all.sh`: 8 runner PASS
- strict concurrency build: PASS
- `git diff --check`: PASS
- 実画面キャプチャを使わないpreview modelの境界テストを追加

設計判断は `docs/decision-records/DR-028-stage-manager-saved-scene-preview.md` に記録しています。
```

