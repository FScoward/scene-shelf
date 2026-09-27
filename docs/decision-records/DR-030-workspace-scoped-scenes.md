# DR-030: Spaceごとの保存済み配置スコープ

## Decision

保存済み配置は、保存時の全displayについて `display identifier + current
Space UUID` を持つworkspace contextに所属させる。表示・保存・復元は現在の
contextが一致する場合だけ許可する。Spaceのid64は同一性ではなく、実行時の
window membership検証に使う。

Space情報の取得はSkyLightとAccessibilityの読み取り専用シンボルを遅延ロードし、
次の4シンボルだけを使用する。

- `SLSMainConnectionID`
- `SLSCopyManagedDisplaySpaces`
- `SLSCopySpacesForWindows`
- `_AXUIElementGetWindow`

Spaceの作成・移動・削除APIは使用しない。取得不能、構造不正、対象windowの
outside/multiple/missingはfail closedとし、AX writeを行わない。

## Why

Space番号は再起動やdisplay変更で再採番され得るため、UIのスコープキーには
UUIDを使う。保存・復元時はAccessibilityの対象アプリ・PIDのwindow listから
title+identifierで候補を絞り、同じidentityの候補が複数ある場合だけ保存frameの
近似で一意化する。解決した生AXUIElementから読み取り専用の`_AXUIElementGetWindow`
でCGWindowIDを取得し、そのIDだけをSkyLightのmembership確認へ渡す。
候補が1件なら、ユーザーが保存後に移動・リサイズしていても採用する。そのうえで
SkyLightのmembershipで現在Spaceとの一致を再確認する。これにより別Spaceのwindowを
推測して操作しない。

CGWindowListのtitleやframeはScreen Recordingの権限・プライバシー保護でredactされ
得るため、Space membershipの解決には使用しない。AX解決、window ID取得、membershipの
いずれかが不明な場合は保存・復元を停止し、AX writeを行わない。

active sceneと並び順もSpace scopeごとに管理し、Spaceを切り替えても別scopeの
active sceneをhideしたり、別scopeのsceneを隣接移動の対象にしたりしない。AX操作は
background isolation前、restore plan準備後、各AX write直前にscopeを再確認し、
不一致なら残りのwriteを行わずfail closedにする。ただしmacOS側にSpace切替と
AX writeを一つの原子操作としてロックする公開手段はないため、境界間の切替まで
完全には防げない。この限界を許容できなくなった場合は公開APIの提供状況と合わせて
再評価する。

## Why not

Space番号の直接管理、他Spaceへのwindow移動、CGWindowListの全デスクトップ画像
取得、非公開のSpace移動/作成APIは採用しない。公開APIだけでは他アプリのSpace所属を
正確に取得できず、推測による復元は誤操作とプライバシー漏えいにつながる。

## Distribution and re-evaluation

SkyLightは非公開APIのためApp Store配布を対象外とする。macOS更新でsymbolや
payloadが変わった場合は取得不能として保存・復元を停止する。Appleが他アプリの
Space所属を取得できる公開APIを提供した場合、またはApp Store配布が必要になった
場合に、この境界を再評価する。

## Persistence migration

workspace contextを持たない旧revisionは初回load時に現在contextを付与した
新revisionとして一度だけ移行する。revision群を先に書き、最後にindexを置換する
ため、途中失敗時は旧indexと旧sceneを保持する。
