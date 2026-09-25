# Grok product usage breakdown proof

These images are the production `UsageMenuCardView`, rendered offscreen at
310 pt from a **live** multi-product Grok snapshot. The card model was built
with `UsageMenuCardView.Model.make` and `hidePersonalInfo: true`.

- **Source:** the `usage` object printed by this branch's
  `CodexBarCLI usage --provider grok --source oauth --format json`
  (2026-09-25 04:54 UTC). The run read only `~/.grok/auth.json`, with an
  isolated `CFFIXED_USER_HOME` and `CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1`.
- **Redaction:** the account email and organization were removed from that
  JSON before rendering.
- **What the snapshot contains:** one primary window (Weekly, 6% used) and a
  `Usage breakdown` section with `Grok Chat 4%` and `Grok Build 2%`. Those rows
  come from the live credits payload
  `creditUsagePercent 6 = GrokChat 4 + GrokBuild 2`.
- **Before and after:** `after.png` and `after-dark.png` render the snapshot
  as-is. `before.png` renders the same snapshot with `details` cleared. That is
  what released 0.65.0 shows for this payload, because its decoder drops
  `productUsage`. This change touches no view code.

No app was launched, no window was shown, and nothing was captured from the
screen. The render harness was a temporary test and was not committed. It
decodes the JSON with an ISO 8601 `JSONDecoder`, builds the card model, then
renders through `NSHostingView` + `cacheDisplay` into a 2× bitmap.
