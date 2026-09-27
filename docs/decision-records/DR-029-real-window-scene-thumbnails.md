# DR-029: 保存済み配置の実ウィンドウ合成サムネイル

## 目的

保存済み配置の一覧で、保存時のウィンドウ配置図だけでなく、実際のウィンドウ内容を識別できるプレビューを表示する。画面全体や他のウィンドウをキャプチャせず、ユーザーが選択した配置に属するウィンドウだけを扱う。

## 制約・事実

- 対象OSはmacOS 14以降で、実ウィンドウの取得にはScreenCaptureKitを使う。
- `SCWindow`にはAX保存時の`identifier`に相当する公開プロパティがない。
- そのため、解決キーは保存済みのowner bundle identifier・process ID・titleの完全一致とし、0件は欠落、2件以上は曖昧として撮影を中止する。
- キャプチャは`SCContentFilter(desktopIndependentWindow:)`と`SCScreenshotManager.captureImage`に限定し、デスクトップ全体を撮影しない。カーソルは非表示にする。
- 画像は保存済みJSONの契約ではなく派生キャッシュであり、Application Support/SceneShelf/thumbnails配下へatomicに公開する。キャプチャ失敗時は既存PNGを保持する。
- 画面収録権限の初回許可後は、OSの制約によりアプリ再起動が必要な場合がある。

## 選択

実ウィンドウごとのRGBA画像を値型へ変換し、保存frameのunionを基準に最大400x280へ合成してPNGキャッシュへ書き込む。UIはキャッシュが有効なときだけ実画像を表示し、欠落・破損・失敗時は既存の配置図へ戻す。保存時には撮影を試み、管理メニューから明示的にプレビューを更新できる。

## Why

保存frameを合成基準にすることで、複数ウィンドウの相対位置と配置全体の縦横比を保ちながら、キャプチャ対象を各ウィンドウへ閉じ込められる。キャッシュを派生データとして分離することで、画像が作れない環境でも配置の保存・復元を壊さず、失敗時に既存プレビューを安全に残せる。

## Why not

- デスクトップ全体のスクリーンショットは、対象外ウィンドウや機密情報を混ぜるため採用しない。
- 保存frameから図形だけを描く方式は権限不要で決定的だが、今回の目的である「何が開いているか」の識別性が低いため、実画像のfallbackとして残す。
- `SCWindow`のwindow IDだけを識別子にする方式は、AX保存のidentityと対応せず、プロセス再起動や同名ウィンドウで誤撮影するため採用しない。

## 帰結・再検討条件

- ScreenCaptureKitの権限、対象ウィンドウの欠落、同名ウィンドウの曖昧さは日本語の状態として表示される。
- 現行の公開APIではAX identifierをSCKへ引き継げないため、同一bundle・PID・titleの複数ウィンドウは原則プレビュー対象外になる。ただし、候補の`SCWindow.frame`が保存時frameと許容誤差内で一致するものがちょうど1件だけなら、その候補に限って安全に採用する。
- Xcode本体がなくScreenCaptureKitをimportできないCLT-only環境では、CoreGraphicsのwindow listで候補を列挙し、単一window IDの取得へfallbackする。CoreGraphicsの現行SDKでは`CGWindowListCreateImage`がobsoleted指定のため、利用可能なシンボルを動的解決してmacOS 14のdeployment targetでもビルドを維持する。
- CoreGraphics fallbackでは、内部補助・オーバーレイwindowの誤撮影を防ぐため、`kCGWindowLayer == 0`、`kCGWindowSharingState != 0`、正のboundsだけを候補に残す。同名候補が残る場合も、保存frameと近似一致する候補が1件だけのときに限って採用し、それ以外は曖昧として中止する。
- 将来macOSがAX identifier相当をSCKへ提供する場合、またはwindow IDとの安全な対応付けが検証できる場合は、解決キーを強化できる。

## 関連テスト

- `SceneShelfPersistenceTestRunner`: exact解決、欠落/曖昧拒否、frame合成、400x280境界、atomic公開、旧画像保持、複製・削除・更新。
- `SceneShelfPresentationTestRunner`: 実画像データを優先し、欠落時は既存配置図へfallbackするUI境界。
