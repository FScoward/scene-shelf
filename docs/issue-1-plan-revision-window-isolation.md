# Issue #1 Plan revision draft: Stage Manager OFF時の背景window隔離

> Issue本文への反映は親タスクで行う。このファイルは正本Issue更新用の文案であり、実装の機械的なAPI一覧ではない。

## 目的

Stage ManagerがOFFでも、saved sceneをクリックしたときにscene対象以外のFinder・System Settingsなどのvisible windowが残り、配置が混在する問題を解消する。

## Plan revision

1. saved scene表示直前にread-only application catalogを再取得する。
2. 表示対象とScene Shelf自身を除く非minimized normal windowを、windowのBundle ID・PID・title・identifierのexact identityで一時認可し、minimizeする。
3. Scene Shelfが今回minimizeに成功したsnapshotだけをruntimeで保持する。事前にminimizedだったwindow、対象外window、失敗windowは保持しない。
4. A→B切替中は背景を復元せず、B表示前に新しくvisibleになった背景windowだけを追加で退避する。
5. 同じ表示中sceneのhideが完全成功してcurrent sceneがnilになった時だけ、保持した背景windowをexact identityでunminimizeする。
6. displayが全失敗してcurrent sceneがnilになった場合は、成功済みの背景退避を復元する。
7. 背景catalog／minimize／restoreの失敗はscene本体のstateへ混ぜず、日本語のstatus/accessibility messageとして表示する。restore失敗のsnapshotはruntimeに残し、次回操作で再試行可能にする。
8. saved scene本体の明示選択allowlistと、背景隔離の一時scopeを分離する。

## Acceptance criteria

- [ ] Stage Manager OFFで配置Aをクリックすると、Aの対象以外のvisibleなFinder／System Settingsがしまわれ、Aの対象が表示される。
- [ ] A→Bの切替で、Aの背景windowが途中で再表示されない。
- [ ] 同じ配置を再クリックして完全にしまうと、Scene Shelfが今回しまった背景windowだけが元へ戻る。
- [ ] もともとminimizedだったwindowは、scene操作後もminimizedのままである。
- [ ] scene表示が全失敗した場合、成功済みの背景退避だけが復元される。
- [ ] 背景windowの操作失敗が日本語で表示され、次回操作で再試行できる。
- [ ] 保存時に明示選択していないwindowがsaved sceneのwrite allowlistへ混入しない。
- [ ] FakeAXテストでFinder／System Settings、exact identity、restore retryを確認する。

## Evidence

- Decision Record: docs/decision-records/DR-027-window-isolation.md
- Automated runner: SceneShelfAXTestRunner
