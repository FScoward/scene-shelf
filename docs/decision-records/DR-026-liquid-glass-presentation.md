# DR-026: Liquid Glassの段階的Presentation適用

## 目的

macOS 26以降ではScene Shelfのヘッダー、シーンカード、主要操作をnative Liquid Glassで視認しやすくし、旧OSでは既存のMaterial／button styleで同じ操作性を保つ。

## 制約・確認済み事実

- SDKの`View.glassEffect`、`Glass.clear`、通常の`glass` button styleはmacOS 26.0以降でavailabilityが付いている。
- `GlassButtonStyle`の引数付きinitializerはmacOS 26.1以降であり、今回の最低native分岐には使わない。
- Packageの最低deployment targetはmacOS 14であるため、availability分岐なしにnative APIを呼べない。
- ShelfScrollContainerのviewportはnative glassの背後効果を残すsystem materialで覆い、一般アプリ候補の本文カードはreadable content surfaceで保護する。
- CLT環境ではNSHostingViewを使う実assertion runnerで、layoutとクリック結果を観測する。

## 選択

1. `SceneShelfGlassPresentation`にOS version policyを置き、macOS 26以上をnative、macOS 25以下をMaterial fallbackとして値型で判定する。
2. `SceneShelfPresentation`にheader/card用の再利用modifierと、主要button用のstyle modifierを置く。
3. native分岐では`glassEffect(.clear)`／`glassEffect(.clear.interactive())`と通常の`buttonStyle(.glass)`を使い、fallback分岐では`thinMaterial`／`regularMaterial`と`bordered`を使う。
4. AppDelegateではheader、fake/saved scene card、候補確認・保存・Fixture操作などの主要操作へ適用する。viewportはsystem material、一般アプリ候補本文カードはreadable content surfaceとして別の可読性境界を維持する。

## Why / Why not

OSが提供するnative glassへ委ねることで、Reduce Transparencyやlight/dark appearanceの扱いを独自に再現せず、OSのアクセシビリティと将来の外観更新に追従できる。modifierをPresentation層へ閉じ込めることでAppDelegateにavailability分岐を散らさず、クリック対象のButton labelへsurfaceを置いて既存のhit actionを保持する。全面透明化は、system materialとreadable content surfaceで守る可読性境界を失うため採用しない。固定色やAppKit独自の透明効果は、OS外観・Reduce Transparencyと競合するため採用しない。

## 帰結

macOS 26以降では対象surfaceと主要buttonがnative glassになり、macOS 14〜25ではMaterial／既存button styleへ安全にfallbackする。カードの固定layoutとクリック導線、viewportのsystem material、本文のreadable content surfaceを維持する。実機でのLiquid Glassの最終見た目、Reduce Transparency時のOS挙動、macOS 25以下での実外観は手動確認を残す。

## 再検討条件

native glass適用後に実機でクリック領域、文字コントラスト、Reduce Transparency、または保存カードの縦スクロールが崩れる場合は、surfaceの適用範囲とbutton label境界を再検討する。macOS 26.1以降の引数付きGlassButtonStyleが最低サポート条件になった場合は、button tint／interactive設定を再評価する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: macOS 26／25 policy、current policy、header/card fixed layout、card click actionを検証。
- 同runner既存テスト: viewport全面のsystem material、透明panel、continuous clip、scroll操作を維持。

## D3追補: viewport materialとreadable content surface

### 目的

native glass直下をopaqueなwindow backgroundで塞がず、viewportの背後効果を保ちながら、長い本文カードの文字可読性を守る。

### 制約・確認済み事実

- 実機スクリーンショットで、完全不透明な`windowBackgroundColor`がnative glassの背後効果を消していることが確認された。
- viewport全面透明化は、壁紙依存で本文が読みにくくなるため禁止する。
- `NSVisualEffectView`はsystem material、window背後合成、active stateを提供する。SwiftUIの`accessibilityReduceTransparency`はreadable surfaceのopacity policyへ渡せる。

### 選択

`ShelfViewportBackgroundNSView`を`NSVisualEffectView`へ変更し、`.hudWindow`、`.behindWindow`、`.active`、hitTest nilを設定する。viewport全面サイズを維持し、viewport root全体をcontinuous rounded cornerでclipする。一般アプリ候補GroupBoxとアクセシビリティ技術検証GroupBoxには、`windowBackgroundColor`高濃度（通常opacity 0.88、Reduce Transparency時1.0）のlight/dark対応readable content surfaceと薄いseparator borderを適用する。surface modifier自身へ識別子を持たせず、既存GroupBoxのaccessibility identifierを正本とする。

### Why / Why not

system materialをOSに合成させれば、native glassの背後効果を残しつつ、固定opaque layerより壁紙依存を抑えられる。本文GroupBoxは通常時に高濃度system background、Reduce Transparency時に完全不透明なsystem backgroundで保護し、viewport全体はmaterialのままにする。全面透明化は可読性を失い、固定色の独自描画はlight/dark appearanceとReduce TransparencyのOS制御を競合するため採用しない。

### 帰結

native glassの視覚効果とviewportの読解可能性を両立する。visual effect viewとreadable surfaceは入力を奪わず、既存の固定layout・スクロール・クリック導線を維持する。実機の壁紙、Reduce Transparency、各appearanceでの最終見た目は手動確認を残す。

### 再検討条件

materialのbehind-window合成が実機で過度に透明、またはreadable surfaceがGroupBoxの文字・Toggle入力を覆う場合は、material種別・opacity・surface適用範囲を再調整する。

### 関連テスト

- `SceneShelfPresentationTestRunner`: 透明panel上のvisual effect viewのviewport全面、hudWindow／behindWindow／active、rootのcontinuous clip、hitTest nilを検証。
- 同runner: readable surfaceの通常／Reduce Transparency opacity policy、実GroupBoxの固定layout、埋め込みButtonのclick actionを検証。識別子はAppDelegateのGroupBoxへ付与した既存境界を使用する。

## D4追補: decision-brief選択「ダークスモーク」

### 目的

decision-briefで選択された「ダークスモーク」をScene Shelf全体の外観契約へ反映し、暗い作業環境でglassの深度と操作対象の識別を両立する。

### 制約・確認済み事実

- `SceneShelfPanel`はメニューバー由来のaccessory panelであり、キー入力・スクロール・既存identifier・click actionを維持する必要がある。
- macOS 26の`Glass.clear`と通常の`glass` button styleは、OSのdarkAqua・Reduce Transparency制御に委ねられる。
- 長文カードはviewportのsystem materialだけでは壁紙とのコントラストが不安定なため、readable content surfaceを残す。
- AppKitの高contrast appearance名は`bestMatch`用のmatching-only名称で直接生成できないため、実panelのdarkAquaとcontrast policy名を分離して観測する。

### 選択

- `SceneShelfPanel`のappearanceを`darkAqua`へ統一する。
- viewportのmaterialを`.hudWindow`／`.behindWindow`／`.active`へ変更し、rootのcontinuous clipとhitTest nilを維持する。
- macOS 26のheader/cardは`.clear`系glassを使い、cardだけ`.interactive()`を維持する。必要最小のdark tintとlight outlineを重ねる。
- 主要buttonは`glassProminent`から通常の`glass`へ下げ、disabled状態・accessibility identifier・ラベルは既存のButton契約に委ねる。旧OSは`bordered`へfallbackする。
- readable GroupBoxはdarkAquaのsystem `windowBackgroundColor`を通常opacity 0.88、Reduce Transparency時1.0で使う。
- `SceneShelfGlassRenderingConfiguration`へnative/fallback、clear/regular、interactive、outline opacity、glass/bordered button styleを集約し、glass modifierとbutton modifierが同じ値型policyを消費する。
- contrast注入時はpure policyを`accessibilityHighContrastDarkAqua`として保持し、実panelはdarkAquaを使いながらconfigured policy nameを外部観測可能にする。

### Why / Why not

panel全体をdarkAquaへ揃えると、viewportのhud material、clear glass、readable surfaceが同じ暗色系のappearanceを共有し、個別の固定色変換を増やさずに深度を出せる。`hudWindow`はsidebarより暗い作業用surfaceとしてbehind-window効果を残し、clear glassはregularの乳白感を抑える。通常glass buttonはprominentの強い青を避けながらOS標準のhover・pressed・disabled表現を保つ。pure rendering configを一つにすることで、modifier側のhardcodeと公開tokenの乖離を防ぐ。readable surfaceは長文本文だけを保護し、glassの軽量な見た目を壊さない。

軽量なMaterial fallbackと固定outlineは、macOS 14〜25の互換性と最小限の境界表示のために残す。一方、全面clear化は本文の可読性を壁紙へ依存させ、全体へ濃い不透明overlayを置く案はLiquid Glassの背後効果と軽量さを失うため採用しない。

### 帰結

Scene ShelfはdarkAqua／hud material／clear glassを基調とし、既存のlayout、click、scroll、identifier、disabled契約を維持する。実機での最終色、壁紙、Reduce Transparency、旧OS fallbackは手動再確認を残す。

### 再検討条件

実機でdarkAquaが文字コントラスト、GroupBox入力、scroll hit area、disabled識別またはglass depthを損なう場合は、tint／outlineの濃度とsurface適用範囲を再評価する。clear glassのOS仕様が変わる場合はpolicy tokenとavailability分岐を再確認する。

### 関連テスト

- `SceneShelfPresentationTestRunner`: panel darkAqua／high-contrast policy、viewport hudWindow／behindWindow／active、root clip、layout／scroll／clickを検証。
- 同runner: rendering configの通常／Reduce Transparency／Increase Contrast分岐、readable GroupBox policy、enabled／disabled major button actionを検証。
