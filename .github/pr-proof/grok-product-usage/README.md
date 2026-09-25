# Grok product usage breakdown proof

The production `UsageMenuCardView` is rendered offscreen at 310 pt from a
**live** Grok snapshot, with the model built by `UsageMenuCardView.Model.make`
and `hidePersonalInfo: true`.

- **Source data:** the `usage` object printed by this branch's
  `CodexBarCLI usage --provider grok --source oauth --format json`
  (2026-09-23 15:56 UTC). It read only `~/.grok/auth.json`, with an isolated
  `CFFIXED_USER_HOME` and `CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1`.
- **Redaction:** the account email and organization were removed from that
  JSON before rendering. The decoded snapshot has one primary window
  (Weekly, 1% used) and the new `Usage breakdown` section (`Grok Build 1%`).
- **Before and after:** `after.png` and `after-dark.png` render that snapshot
  as-is. `before.png` renders the same snapshot with `details` cleared, which
  is what main produces for this payload because its decoder drops
  `productUsage`. This change does not touch any view code.

No app was launched, no window was shown, and nothing was captured from the
screen. The render harness was a temporary test that was not committed:
decode the JSON with an ISO 8601 `JSONDecoder`, build the card model, then
`NSHostingView` + `cacheDisplay` into a 2× bitmap.
