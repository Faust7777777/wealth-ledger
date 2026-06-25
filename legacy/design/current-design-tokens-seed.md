# Current Design Tokens + M1 Seed (from previous high-quality run)

Use this as reference material when asking other models to generate or improve the design.

## Core Colors (AppColors)

```dart
static const Color bgGraphite = Color(0xFF1C1C1E);
static const Color bgWarmGray = Color(0xFF2A2826);
static const Color surface0 = Color(0xFF2C2C2E);
static const Color surface1 = Color(0xFF38383A);
static const Color surface2 = Color(0xFF48484A);

static const Color textPrimary = Color(0xFFF2F2F7);
static const Color textSecondary = Color(0xFF8E8E93);
static const Color textTertiary = Color(0xFF636366);

static const Color primary = Color(0xFF0A84FF);
static const Color accentTeal = Color(0xFF64D2FF);
static const Color positive = Color(0xFF30D158);
static const Color negative = Color(0xFFFF6961);

static const Color chartLine = Color(0xFF0A84FF);
static const Color chartAreaFill = Color(0x1A0A84FF);
static const Color chartGrid = Color(0xFF3A3A3C);
static const Color chartAxis = Color(0xFF636366);

static const Color statusInfo = Color(0xFF64D2FF);
static const Color statusWarning = Color(0xFFFFD60A);
static const Color statusError = Color(0xFFFF6961);
static const Color statusSuccess = Color(0xFF30D158);
```

## Typography Highlights

- Net worth hero: `displayLarge` — Inter, 48px, w600, letterSpacing -1.5
- Use `GoogleFonts.inter(...)` for consistency across Windows + Android

## Spacing

Base: 4px  
- xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48

Desktop columns approx:
- Left: 240–280px
- Center: flex (min ~520px)
- Right: 240–320px

## M1 Prototype Seed Data (use exactly these values for mocks)

```json
{
  "net_worth": "245678.90",
  "delta": "1245.67",
  "delta_percent": 0.51,
  "accounts": [
    {"id": "a1", "name": "Chase Checking", "kind": "Checking", "balance": "12450.33"},
    {"id": "a2", "name": "Vanguard Brokerage", "kind": "Brokerage", "balance": "142300.45"},
    {"id": "a3", "name": "Amex Gold", "kind": "CreditCard", "balance": "-2341.88"},
    {"id": "a4", "name": "Fidelity 401k", "kind": "Retirement401k", "balance": "93270.00"}
  ],
  "allocations": [
    {"category": "Cash & Equivalents", "percent": 18.4, "value": "45234.12"},
    {"category": "Equities", "percent": 47.2, "value": "116000.00"},
    {"category": "Fixed Income", "percent": 22.1, "value": "54300.00"},
    {"category": "Retirement", "percent": 12.3, "value": "30144.78"}
  ]
}
```

Full details + all component signatures + PR Plan are in the main design document and the portable prompt.

Copy the content above when you want other models to stay consistent with the current visual direction.
