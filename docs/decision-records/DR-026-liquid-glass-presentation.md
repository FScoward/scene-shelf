# DR-026: Liquid Glassの段階的Presentation適用

## 目的

macOS 26以降ではScene Shelfのヘッダー、シーンカード、主要操作をnative Liquid Glassで視認しやすくし、旧OSでは既存のMaterial／button styleで同じ操作性を保つ。

## 制約・確認済み事実

- SDKの`View.glassEffect`、`Glass`、`glassProminent`はmacOS 26.0以降でavailabilityが付いている。
- `GlassButtonStyle`の引数付きinitializerはmacOS 26.1以降であり、今回の最低native分岐には使わない。
- Packageの最低deployment targetはmacOS 14であるため、availability分岐なしにnative APIを呼べない。
- ShelfScrollContainerのviewportは文字可読性のため完全不透明であり、一般アプリ候補の本文カードは既存表示を維持する。
- CLT環境ではNSHostingViewを使う実assertion runnerで、layoutとクリック結果を観測する。

## 選択

1. `SceneShelfGlassPresentation`にOS version policyを置き、macOS 26以上をnative、macOS 25以下をMaterial fallbackとして値型で判定する。
2. `SceneShelfPresentation`にheader/card用の再利用modifierと、主要button用のstyle modifierを置く。
3. native分岐では`glassEffect(.regular)`／`glassEffect(.regular.interactive())`と`buttonStyle(.glassProminent)`を使い、fallback分岐では`thinMaterial`／`regularMaterial`と`borderedProminent`を使う。
4. AppDelegateではheader、fake/saved scene card、候補確認・保存・Fixture操作などの主要操作へ適用する。viewport背景と一般アプリ候補本文カードは変更しない。

## Why / Why not

OSが提供するnative glassへ委ねることで、Reduce Transparencyやlight/dark appearanceの扱いを独自に再現せず、OSのアクセシビリティと将来の外観更新に追従できる。modifierをPresentation層へ閉じ込めることでAppDelegateにavailability分岐を散らさず、クリック対象のButton labelへsurfaceを置いて既存のhit actionを保持する。全面透明化は、既存の不透明viewportによる文字可読性を壊すため採用しない。固定色やAppKit独自の透明効果は、OS外観・Reduce Transparencyと競合するため採用しない。

## 帰結

macOS 26以降では対象surfaceと主要buttonがnative glassになり、macOS 14〜25ではMaterial／既存button styleへ安全にfallbackする。カードの固定layoutとクリック導線、viewportの完全不透明性は維持される。実機でのLiquid Glassの最終見た目、Reduce Transparency時のOS挙動、macOS 25以下での実外観は手動確認を残す。

## 再検討条件

native glass適用後に実機でクリック領域、文字コントラスト、Reduce Transparency、または保存カードの縦スクロールが崩れる場合は、surfaceの適用範囲とbutton label境界を再検討する。macOS 26.1以降の引数付きGlassButtonStyleが最低サポート条件になった場合は、button tint／interactive設定を再評価する。

## 関連テスト

- `Sources/SceneShelfPresentationTestRunner/main.swift`: macOS 26／25 policy、current policy、header/card fixed layout、card click actionを検証。
- 同runner既存テスト: viewport全面のopaque背景、透明panel、appearance切替、scroll操作を維持。
