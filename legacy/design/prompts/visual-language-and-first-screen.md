# Prompt: Visual Language + First Clickable Interface for Wealth App (Flutter + Rust)

**Goal**  
You are an expert product designer + senior Flutter + Rust architect.  
Produce a **complete, actionable design document** for the visual language and the first clickable homepage of a personal wealth/finance application.

**Strict Requirements from Product Owner**

**References (study these carefully):**
- Monarch Money (https://www.monarch.com/) — Dashboard information architecture, net worth as central hero, clean asset distribution, high-quality information hierarchy.
- Kikoff (https://flutter.dev/showcase/kikoff) — Calm financial data presentation, progress, action cards, trustworthy feeling. This is a real Flutter showcase.
- Wonderous (https://flutter.gskinner.com/wonderous/) — Exceptional whitespace, typography, restrained high-end motion and polish. Adapt the *quality*, not the fantasy theme.
- Google Pay Flutter showcase (https://flutter.dev/showcase/google-pay) — Clean visual ordering of cards, transactions, amounts and status.
- Rive Flutter showcase (https://flutter.dev/showcase/rive) — High-quality state animations and micro-interactions (reserve complex ones; start simple).

**Non-negotiable Visual Direction**
- Background: deep graphite (#1C1C1E) or warm gray variants. Calm, premium, non-clinical.
- **Net worth is the single absolute visual hero** on the main screen (large prominent number + subtle delta + primary time-series chart directly below it).
- Second layer: Accounts summary, Asset allocation, Pending AI-suggested changes (as ActionCards).
- Third layer: Quiet, high-density but calm transaction list.
- Status colors (quote expired, sync fail, unexplained differences, pending): clear but never jarring or alarming.
- Reject completely: trading terminal green/red overload, heavy skeuomorphic bank cards.

**Platform Layouts (information hierarchy must feel consistent)**
- **Windows / Desktop**: Classic three-column layout
  - Left: navigation / accounts summary
  - Center: hero net worth + main chart + primary content
  - Right: breakdown / details / allocation
- **Android / Mobile**: Bottom navigation + vertical scrolling card flow (stacked sections matching the hierarchy above).

**Tech Stack (non-negotiable)**
- UI: Flutter (Windows desktop + Android primary targets)
- Core logic: Rust (precise money math using rust_decimal, aggregations, future diffing)
- Bridge: flutter_rust_bridge (v2+)
- State: Riverpod (preferred for new projects in 2026)
- Charts: fl_chart (highly customizable, ~7.5k stars)
- Motion (first iteration): flutter_animate (restrained, 150-350ms). Rive reserved for later.

**Output Structure (must follow exactly)**

Your response **must** contain these sections:

1. **Title & Metadata**
2. **Overview** (1-2 paragraphs)
3. **Background & Motivation**
4. **Goals & Non-Goals** (very explicit)
5. **Proposed Design**
   - Information Architecture
   - Mermaid diagrams (layout for desktop + mobile, data flow)
   - **Color System** — complete `AppColors` class with hex values + usage rules (copy-paste ready)
   - **Typography Scale** — complete `AppTypography` using Inter via google_fonts + exact sizes/weights (hero = 48px)
   - **Spacing & Layout Tokens** — `AppSpacing` + column widths (desktop 240-280 | flex | 240-320)
   - **Chart System Guidelines** (detailed fl_chart config for net worth line + allocation pie)
   - **Core Components** — for all of these provide:
     - Visual description
     - Full widget class signature (StatelessWidget or similar)
     - Key build structure / subcomponents
     Components needed:
     - NetWorthHero
     - AccountCard
     - AllocationBreakdown
     - QuietTransactionList
     - StatusBadge
     - ActionCard
6. **Platform Adaptation Strategy** (80/20 shared code)
7. **Animation & Motion Principles** (restrained)
8. **High-level Architecture** (Flutter folder structure, Riverpod, routing, theme)
9. **Rust Core Boundary** (what lives in Rust vs Flutter, narrow bridge surface)
10. **Package Recommendations** with justification
11. **M1 Prototype Data Contract** (exact seed data: number of accounts, transactions, values, net_worth example like 245678.90)
12. **Risks** (toolchain, bridge, dual platform, maintenance — with severity + mitigation)
13. **Key Decisions** (numbered list with rationale)
14. **PR Plan** (5-8 small, independently mergeable PRs)
    Each PR must have:
    - Title
    - Files / components affected
    - Dependencies
    - Short description + what "done" looks like (e.g. "flutter run -d windows shows hero")
15. **Open Questions** (resolved or clearly deferred)
16. **References**

**Quality Bar**
- Extremely concrete and copy-paste ready (code snippets, exact hex, widget signatures).
- Every major visual and layout decision must be justified against the reference apps.
- PR Plan must be realistic for a small team and lead to a **clickable first screen** on both Windows and Android.
- Use the existing design document (if provided) as strong base and improve upon it.

**Current Context (important)**
This is a greenfield project. No existing code yet.  
The user has already run one high-quality design pass and has a detailed spec. You should produce something at least as good, preferably better in precision of models, component APIs, and PR sequencing.

---

## How to Use This Prompt with Different Models

### Option A: Claude.ai (Recommended for design quality)
1. Go to https://claude.ai
2. Create a new Project (or use Artifacts)
3. Paste **everything above** + optionally paste the content of the current design doc.
4. Add: "Output the full design document in Markdown. Use clear headings and lots of code blocks."

### Option B: Cursor / Windsurf / VS Code + Continue.dev
- Open the Composer / Agent chat in the `finwealth` project.
- Paste this entire prompt.
- Or use `@file` to reference the existing design doc and say "Revise/improve using a different perspective".

### Option C: Other frontier models
- Gemini 2.5 Pro, GPT-4.1, Grok-4, etc. — the prompt is self-contained.
- For best results add: "Think step by step. Prioritize specificity and actionability over fluff."

### Option D: Inside this environment (Opencode)
Run the following slash commands (after invoking the opencode-controller skill):
```
/models
# then choose Claude / OpenAI / whatever you want
/agents
# choose "Plan"
```
Then give Opencode the content of this prompt file.

---

## Optional: Iteration Instruction (when you already have a design doc)

If you have access to the previous design document (`grok-design-doc-d7d51e2a.md` or the one in this project), add this at the end of your prompt:

"Here is the previous design document. Review it, keep the strong parts (especially the visual tokens and Monarch/Kikoff/Wonderous fidelity), then produce an improved version addressing these points:
- More complete Rust + flutter_rust_bridge data models with full #[frb] structs and String-only Decimal policy
- Better PR sequencing (data contracts early)
- Full signatures for all 6 core components
- Dedicated Risks section
- Concrete M1 seed data
- Full LineChartData example

Output the full revised design document."

Copy the above block into your chat when iterating.

---

**Ready to use.**  
Copy from "Prompt: Visual Language..." all the way to the end and paste into your chosen model. 

This prompt was engineered to reproduce (and exceed) the quality of the built-in design skill used previously.