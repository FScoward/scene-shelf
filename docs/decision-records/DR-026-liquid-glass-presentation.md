# DR-026: Liquid Glassの段階的Presentation適用

## 目的

macOS 26以降ではScene Shelfのヘッダー、シーンカード、主要操作をnative Liquid Glassで視認しやすくし、旧OSでは既存のMaterial／button styleで同じ操作性を保つ。

## 制約・確認済み事実

- SDKの`View.glassEffect`、`Glass`、`glassProminent`はmacOS 26.0以降でavailabilityが付いている。
- `GlassButtonStyle`の引数付きinitializerはmacOS 26.1以降であり、今回の最低native分岐には使わない。
- Packageの最低deployment targetはmacOS 14であるため、availability分岐なしにnative APIを呼べない。
- ShelfScrollContainerのviewportはnative glassの背後効果を残すsystem materialで覆い、一般アプリ候補の本文カードはreadable content surfaceで保護する。
- CLT環境ではNSHostingViewを使う実assertion runnerで、layoutとクリック結果を観測する。

## 選択

1. `SceneShelfGlassPresentation`にOS version policyを置き、macOS 26以上をnative、macOS 25以下をMaterial fallbackとして値型で判定する。
2. `SceneShelfPresentation`にheader/card用の再利用modifierと、主要button用のstyle modifierを置く。
3. native分岐では`glassEffect(.regular)`／`glassEffect(.regular.interactive())`と`buttonStyle(.glassProminent)`を使い、fallback分岐では`thinMaterial`／`regularMaterial`と`borderedProminent`を使う。
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

`ShelfViewportBackgroundNSView`を`NSVisualEffectView`へ変更し、`.sidebar`、`.behindWindow`、`.active`、hitTest nilを設定する。viewport全面サイズを維持し、viewport root全体をcontinuous rounded cornerでclipする。一般アプリ候補GroupBoxとアクセシビリティ技術検証GroupBoxには、`windowBackgroundColor`高濃度（通常opacity 0.88、Reduce Transparency時1.0）のlight/dark対応readable content surfaceと薄いseparator borderを適用する。surface modifier自身へ識別子を持たせず、既存GroupBoxのaccessibility identifierを正本とする。

### Why / Why not

system materialをOSに合成させれば、native glassの背後効果を残しつつ、固定opaque layerより壁紙依存を抑えられる。本文GroupBoxは通常時に高濃度system background、Reduce Transparency時に完全不透明なsystem backgroundで保護し、viewport全体はmaterialのままにする。全面透明化は可読性を失い、固定色の独自描画はlight/dark appearanceとReduce TransparencyのOS制御を競合するため採用しない。

### 帰結

native glassの視覚効果とviewportの読解可能性を両立する。visual effect viewとreadable surfaceは入力を奪わず、既存の固定layout・スクロール・クリック導線を維持する。実機の壁紙、Reduce Transparency、各appearanceでの最終見た目は手動確認を残す。

### 再検討条件

materialのbehind-window合成が実機で過度に透明、またはreadable surfaceがGroupBoxの文字・Toggle入力を覆う場合は、material種別・opacity・surface適用範囲を再調整する。

### 関連テスト

- `SceneShelfPresentationTestRunner`: 透明panel上のvisual effect viewのviewport全面、sidebar／behindWindow／active、rootのcontinuous clip、hitTest nilを検証。
- 同runner: readable surfaceの通常／Reduce Transparency opacity policy、実GroupBoxの固定layout、埋め込みButtonのclick actionを検証。識別子はAppDelegateのGroupBoxへ付与した既存境界を使用する。
