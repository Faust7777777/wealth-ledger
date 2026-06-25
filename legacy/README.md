# finwealth — Flutter + Rust Wealth App

**Visual direction (locked):**  
Monarch Money dashboard IA + Kikoff financial trust & cards + Wonderous whitespace/typography/restrained motion.

**Core rules (non-negotiable):**
- Net worth = sole absolute visual hero
- Deep graphite / warm gray
- Windows 3-column | Android bottom-nav + vertical cards (consistent IA)
- No trading terminal red/green chaos, no heavy skeuomorphism
- fl_chart + flutter_animate (Rive reserved)
- Rust for all money math + core logic (flutter_rust_bridge)

## Current Status
- Visual language + first clickable homepage fully designed
- Design went through full write → review → revise loop
- **现在支持用别的模型重新生成/迭代设计**（见 `design/` 目录）

## Key Artifacts (from design run)
- Full spec + tokens + wireframes + PR Plan（旧版）: `C:\Users\15892\tmp\grok-design-doc-d7d51e2a.md`
- **用别的模型跑设计的材料**（推荐）:
  - `design/prompts/visual-language-and-first-screen.md` （自包含 Prompt）
  - `design/HOW_TO_USE_OTHER_MODELS.md` （详细使用指南）
  - `design/current-design-tokens-seed.md` （当前 tokens + M1 seed，便于保持一致性）

## Next Steps (exact order)

1. Install toolchains (see commands below)
2. `flutter create . --platforms=windows,android` (or in empty dir)
3. Follow PR Plan in the design doc (starts with bootstrap + contracts + tokens)
4. Copy the exact `AppColors`, `AppTypography`, `AppSpacing` from the design doc into `lib/theme/`

## Install on Windows (pwsh)

```powershell
# Rust
winget install --id Rustlang.Rustup -e

# Flutter (recommended)
winget install -e --id Google.Flutter

# After install, restart terminal and verify
flutter --version
cargo --version
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android  # for android if needed
```

## Recommended packages (from design)

```bash
flutter pub add fl_chart flutter_animate riverpod flutter_riverpod google_fonts go_router talker
cargo install flutter_rust_bridge_codegen
```

## First Screen Goal (M1)
Clickable NetWorthHero (48px Inter) + time series chart + second layer cards + quiet list, working on Windows (3-col) and Android (flow).

See the design doc for exact hex, component signatures, M1 seed data, and PR breakdown.
