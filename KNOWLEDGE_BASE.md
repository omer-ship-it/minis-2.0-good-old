# Knowledge Base — /charge endpoint, rollback infrastructure, operational lessons

Comprehensive technical reference from the late-night design + build session of May 1–2, 2026. Contains the architecture decisions, the WHY behind each one, the lessons learned from the `/start-safe` failure, and the operational patterns to maintain.

If you're reading this in a few weeks/months and trying to remember the design — start here.

---

## 1. Incident context (what triggered all this)

### The 6 incidents on Friday May 1, 2026

Throughout the day, customers experienced multiple payment-related issues at the Israel shop (shop 12, "בית העם"):

- **Liza, ₪64** — charged twice. Z-Credit charged her card, iPad showed failure, retry charged again.
- **Liza, ₪14** — same pattern, double-charge.
- **Order 163** — payment failed on multiple retries (₪20 attempts), kitchen bone never printed.
- **Phantom ₪233** — customer charged different amount than DB recorded.
- **Split-pay immediate decline** — split payment showed "declined" before reaching Z-Credit.
- **Charge-without-record** — customer saw "paid" confirmation but no charge appeared at Z-Credit.

### Root cause: `/start-safe` endpoint

All six incidents traced to the `/payments/zcredit/start-safe` endpoint, which had been deployed earlier that week as a "safer" replacement for `/start`. It contained two specific bugs:

1. **Logical-order replay short-circuit matched by ticket alone** (no amount filter). When split payments came through with the same ticket but different amounts, the server returned a stale "approved" response with the wrong amount → phantom ₪233.

2. **Stale "declined" responses cached and replayed** without re-querying Z-Credit. Split-payment retries hit the cache and got immediate "declined" without ever attempting to charge.

### Action taken (Friday night)

Rolled back the iOS app to commit 57398de (April 20 snapshot). This bypasses `/start-safe` entirely — the rolled-back iPad calls `/start` directly. Cherry-picked these fixes into the snapshot before shipping:

- Customer name resolver (`resolvedNameForSubmit` with `posSavedName` fallback)
- Welcome view dismiss race fix (`didShowWelcome = true` BEFORE `checkoutIntentRaw`)
- Bones display fixes (cache-bust + 30-min time window)
- Swift compiler crash fix (`@_optimize(none)` on `ForceRTL.SemanticHost.Controller.deinit` + `-Osize`)
- QR code removal from confirmation view

Snapshot uploaded to TestFlight late Friday night. Production stable on `/start` from this build.

---

## 2. The architectural problem `/charge` solves

### Lost-response double-charge

The `/start` endpoint has a fundamental architectural gap that has caused ~1-2 incidents per week historically:

```
1. iPad → POST /start
2. Server → Z-Credit
3. Z-Credit charges card ✓
4. Z-Credit → Server (response received)
5. Server → iPad (response in transit)
6. ❌ Network drops between server and iPad
7. iPad shows "payment failed" (timeout)
8. Cashier asks customer to retry
9. iPad → POST /start (second attempt)
10. Z-Credit charges card AGAIN ✓
11. Customer charged twice
```

The server has no row in the DB until the iPad confirms — so steps 6-11 produce two distinct charges with no link between them. Reconciliation requires manual investigation.

### Phantom-success (lost-response in reverse)

Same architectural gap, opposite outcome:

```
1. iPad → POST /start
2. Server → Z-Credit
3. Z-Credit DECLINES card
4. Z-Credit → Server (decline response)
5. ❌ Server marks order paid in DB anyway (bug, or race)
6. Server → iPad ("approved")
7. iPad shows success, customer leaves with order
8. No actual charge happened, store loses revenue
```

### What `/charge` does differently

1. **Insert pending row BEFORE charging** — the order exists in our DB the moment we attempt the charge.
2. **Use `Status` column as source of truth** — `0 = pending`, `1 = paid`. Pre-check on retry.
3. **Z-Credit's `UseAdvancedDuplicatesCheck`** — gateway-level dedup using `TransactionUniqueID = orderId`.
4. **`-88001`/`-88002` recovery branch** — if Z-Credit reports a duplicate, the previous charge succeeded; mark paid without recharging.

Result: lost-response retries become safe. Customer charged at most once per orderId, regardless of network failures between iPad and server.

---

## 3. `/charge` endpoint design (final form)

### File: `MinisLiveAPI/charge-endpoint.cs`

Complete draft, ~880 lines. Mostly helpers copied from `/start` so behavior matches. The actually-new logic is ~80 lines.

### Flow

```
INPUT:
  POST /payments/zcredit/charge
  body: { amount, currency, transactionType, miniAppId, pinpadId, [orderId] }

STEP 1: Validate input (miniAppId > 0, amount > 0)

STEP 2: Resolve credentials (terminal, password, pinpadId)
  - Mini-12 special case: ResolveMiniAppIdForCredentials returns 0,
    forcing default credentials (preserves legacy behavior)

STEP 3: HYBRID — orderId provided or not?

  If iPad sent orderId (RETRY case):
    SELECT Status FROM dbo.Orders
    WHERE Id = @orderId AND MiniAppId = @miniAppId
    
    Status = 1 → return "charge_already_paid", no Z-Credit call
    Status = 0 → reuse this row, fall through to charge below
    null      → fall through to INSERT
  
  If iPad sent no orderId (FRESH case):
    INSERT pending row (Status=0, CustomerId=0, PaymentMethod='charging',
      Total=req.Amount, Source='cashpoint-charge')
    Get orderId from SCOPE_IDENTITY()

STEP 4: Define MarkPaidAsync helper
  UPDATE dbo.Orders
  SET Status=1, PaymentMethod='card', UpdatedAt=NOW(),
      Metadata = JSON with referenceNumber, authNumber, cardSuffix, cardBrand, transactionId
  WHERE Id = @orderId AND Status = 0

STEP 5: Charge via Z-Credit
  TransactionUniqueID = orderId.ToString()
  UseAdvancedDuplicatesCheck = true

  Response branches:
    A.  retCode=0, isApproved=true, !hasError
        → MarkPaid → return "commit_final_fast" (success)
    
    A2. retCode=-88001 OR -88002 (DUPLICATE DETECTED — lost-response recovery)
        → MarkPaid (with whatever metadata the dup response provides)
        → return "charge_recovered_duplicate" (success)
    
    B.  retCode is non-transient error
        → return "commit_declined" (row stays Status=0)
    
    C.  retCode is transient (-80 or -50101)
        → call GetTransactionStatusByReferenceId for one quick status check
        → if approved, MarkPaid + return "status_approved_fast"
        → if declined, return "status_declined_fast"
        → else return "pending_fast"
    
    D.  No reference at all
        → return "no_reference"
```

### Key design decisions and the WHY

| Decision | Why |
|---|---|
| No idempotency-key tables | start-safe's bug was internal replay logic. Z-Credit's own dup detection is the source of truth — we mirror, don't invent. |
| Status pre-check by orderId only (no Total filter) | iPad's `OrderFlowView` is a `.fullScreenCover`; basket can't change while open. `pendingChargeOrderId` lives in `@State`, dies on dismiss. iPad lifecycle enforces "one orderId per attempt". |
| `MiniAppId` filter in pre-check | Prevents cross-shop attack — iPad can't charge another shop's order by sending a wrong orderId. |
| `CustomerId = 0` in INSERT | Schema requires CustomerId NOT NULL. We use 0 as anonymous placeholder; `/orders/submit` later updates with the real customer. |
| `PaymentMethod = 'charging'` (not 'unpaid') | Existing admin "unpaid orders" screens filter by `PaymentMethod='unpaid'`. Using a new value keeps in-flight/orphan /charge rows out of those views. After Z-Credit success, `MarkPaidAsync` flips to 'card'. |
| `Source = 'cashpoint-charge'` | Lets reports distinguish /charge rows from /start rows if needed. Filter audit is on the Sunday checklist. |
| `UseAdvancedDuplicatesCheck = true` (default) | Matches /start's behavior. Trade-off: card-swap on retry could defeat dup detection (retry with different card → not blocked). Sunday test: AdvancedDup=false might be safer if Z-Credit doesn't count declined attempts in its dedup window. |
| Splits bypass /charge entirely | Each /charge call creates a row + sets Status=1 per success. That conflicts with split-payment's "Status=1 only when fully paid" semantic. Splits stay on /start until /start gets row-insertion in a future iteration. Enforced by `isSplitPayment: true` parameter. |
| Refunds (transactionType=53) bypass /charge | Refund semantically opposite of charge. Stays on /start. Enforced by `transactionType == "01"` check. |
| `UPDATE ... WHERE Id = @Id AND Status = 0` | Idempotent — if MarkPaid runs twice (shouldn't but), only one wins. No double-update of metadata. |

### Pre-mortem rounds and what each round caught

We did SIX rounds of weakness analysis on this endpoint. Each round caught real bugs:

| Round | Caught |
|---|---|
| 1 | Missing CustomerId, Total mismatch on retry, MiniAppId not checked, lost-Z-Credit-response not handled, missing invoice generation |
| 2 | Cart-change → orphan rows, sparse metadata on -88001 path, MarkPaid silent failure |
| 3 | Card-swap defeating UseAdvancedDuplicatesCheck=true (the AdvancedDup test still pending) |
| 4 | `pendingChargeOrderId` carrying across customers (split-payment under-charge bug), unifiedSubmit preferred over legacy |
| 5 | Refunds routing to /charge (creates wrong-semantic row), debug ping creating junk rows |
| 6 | Server crash mid-flow (statistically negligible per math, downgraded), PaymentMethod='unpaid' polluting admin screens |

### Final residual risks (accepted trade-offs)

- **Card-swap on retry** with AdvancedDup=true → reconciler catches, rare.
- **Server process crash mid-write** → ~1 in 400 years per math, negligible.
- **iPad timeout while Z-Credit response in-flight** → reconciler catches.
- **Phone-authorization (`IsTelApprovalNeeded`) flow** → not handled, falls into decline path. Same gap as /start.
- **Currency hardcoded to ILS** → fine for shop 12, must fix before non-Israel rollout.
- **Sparse metadata on -88001 recovery** → reconciler can backfill via GetTransactionsReport.

---

## 4. iOS wiring

### Files modified

- `MINIS_02/OrderFlowView.swift`
- `MINIS_02/FastlaneModel.swift`

### `ZCreditResult` struct (FastlaneModel.swift)

Added `orderId: Int?` field. `finishFromResponse` parses `json["orderId"]` (handles int, NSNumber, string forms). All four `ZCreditResult(...)` constructors pass it through.

### `pay()` function (FastlaneModel.swift)

Added two parameters:
- `isSplitPayment: Bool = false` — when true, force /start regardless of flag
- (Existing) `transactionType: String = "01"` — only "01" routes to /charge

### `payLegacyStart` endpoint switching

```swift
let useChargeV2 = !isSplitPayment
    && transactionType == "01"
    && UserDefaults.standard.bool(forKey: "payments.useChargeV2")

let endpointPath = useChargeV2 
    ? "/payments/zcredit/charge" 
    : "/payments/zcredit/start"
```

Three guards (split, transaction type, flag) ensure only the safe scope routes to /charge.

### `OrderFlowView.swift` additions

```swift
@State private var pendingChargeOrderId: Int? = nil
@AppStorage("payments.useChargeV2") private var useChargeV2: Bool = false
```

`pendingChargeOrderId` is captured from `result.orderId` after each pay() call, passed back on retries. Cleared to nil on `.approved` so split-payment halves don't reuse the same row.

The `useChargeV2` AppStorage flag is written by the JSON probe (see Section 6), not directly by the user.

### Approved-path classification updates

Added new path strings to `isApprovedPath`:
- `commit_final_fast`
- `status_approved_fast`
- `charge_already_paid`
- `charge_recovered_duplicate`

Added to `isDeclinedPath`:
- `charge_wrong_status`
- `charge_precheck_db_error`
- `charge_insert_failed`

### `PaymentsConfigProbe` (FastlaneModel.swift)

Decodes `mini.settings.payments.useChargeV2` (preferred) or `mini.useChargeV2` (shortcut) from the published shop JSON. Called inside `parseAndApply(data:)` after the existing `MiniOpenProbe`. Writes the value to UserDefaults under `"payments.useChargeV2"`.

---

## 5. Server-driven flag architecture

The flag flow:

```
1. Admin (via rollback.html or curl):
   GET /api/miniapps/12/payments/charge-v2/{on|off}

2. Endpoint (Program.cs):
   - UPDATE dbo.MiniApps SET Customization = JSON_MODIFY(...)
   - publisher.GenerateAndPublishShopJsonAsync(12)

3. ShopJsonPublisher.cs:
   - Reads dbo.MiniApps.Customization
   - Pass-through for settings.payments block (3 lines added)
   - Writes /json/12.json to wwwroot

4. iPad fetches /json/12.json (every minute or on user action):
   - PaymentsConfigProbe reads mini.settings.payments.useChargeV2
   - Writes to UserDefaults["payments.useChargeV2"]

5. iPad's payLegacyStart reads UserDefaults flag on next pay():
   - Routes to /charge or /start accordingly
```

Total propagation time: ~60 seconds typical (next iPad JSON fetch).

### SQL schema location

`dbo.MiniApps.Customization` (NVARCHAR or similar JSON column). Path: `$.settings.payments.useChargeV2`. Stored as BIT (true/false in JSON).

To seed a new shop:

```sql
UPDATE dbo.MiniApps
SET Customization = JSON_MODIFY(
    JSON_MODIFY(Customization, '$.settings.payments', JSON_QUERY('{}')),
    '$.settings.payments.useChargeV2',
    CAST(0 AS BIT)
)
WHERE Id = 12;
```

The two-step JSON_MODIFY is required because lax-mode auto-create doesn't always create deeply-nested intermediate objects in one shot.

---

## 6. Rollback infrastructure

### Admin endpoint: `/api/miniapps/{id}/payments/charge-v2/{status}`

Single GET endpoint that handles toggling. `{status}` accepts `on`, `off`, `true`, `false`, `1`, `0`. Updates DB + republishes JSON in one transaction. Returns before/after values plus a status note.

Example:

```bash
curl https://minis.studio/api/miniapps/12/payments/charge-v2/off
```

Response:

```json
{
  "ok": true,
  "miniAppId": 12,
  "enabled": false,
  "before": {"Id":12, "UseChargeV2":"true"},
  "after":  {"Id":12, "UseChargeV2":"false"},
  "published": true,
  "note": "/charge DISABLED — iPads revert to /start within ~60s."
}
```

### Admin HTML page: `/admin/rollback.html` (or wherever served)

Self-contained single-file HTML + vanilla JS. iOS-style toggle. Mobile-friendly. Hardcoded to shop 12.

Behavior:
- Page load → fetches `https://minis.studio/json/12.json` → reads `useChargeV2` → sets toggle position
- Tap toggle → confirm dialog → `GET /api/miniapps/12/payments/charge-v2/{on|off}` → 1.5s wait → re-fetch JSON to verify

Title/subtitle change based on state:
- `useChargeV2 = false`: "Rolled back" / "On the old safe system"
- `useChargeV2 = true`: "Upgraded" / "On the new gen system"

Switch color matches state:
- ON (next gen) → green
- OFF (rollback) → gray

### Three layers of safety

1. **Per-iPad** (instant, offline-tolerant): if dual-app installed, staff opens OLD app build instead of NEW. No network or admin access needed.
2. **Global** (60-second propagation): tap rollback.html switch from any phone. Affects all iPads on the new app build.
3. **Reconciler** (overnight, alerts): nightly script catches anything that slipped through.

---

## 7. Operational patterns

### Canary discipline

`start-safe` was deployed to ALL iPads on day one. /charge ships with these constraints:

- AppStorage flag default OFF — even after deploying the iOS code, behavior is unchanged until flag flips.
- Server flag default OFF for all shops — even after enabling per-shop, requires explicit on.
- Canary one iPad first, watch 24-48h before flipping switch globally.

### Friday freeze rule

After this week's incident, established: **NO production changes ship on Friday**. start-safe shipped without thinking about peak day. /charge expansion explicitly avoids Friday.

### Dual-app strategy

Both old and new app builds installed on each iPad. Staff defaults to NEW; falls back to OLD instantly if any payment looks weird. Bundle IDs must differ for both to coexist on the same device.

### Server flag separation from iOS canary

Production iPads: flag-controlled (server JSON-driven).
Canary iPad: hardcoded to /charge (no flag check, separate test rig).

This way, even when admin flips switch OFF for fleet rollback, canary keeps testing /charge — gives independent diagnostic data.

---

## 8. Lessons from the start-safe failure

These are the architectural principles we followed for /charge specifically because of what start-safe got wrong.

### 1. Prefer external source of truth over internal state

start-safe asked "have I seen this ticket before in my own state?" Internal cache lookups are notoriously fragile — bugs in the cache logic don't surface until edge cases.

/charge asks "does Z-Credit's gateway show a duplicate for this uniqueId?" Z-Credit is the source of truth. We mirror, never invent.

### 2. Smaller scope = smaller blast radius

start-safe handled everything: regular charges, splits, refunds, edge cases. The phantom-amount bug lived in the split-payment code path.

/charge restricts to: single-payment, transactionType=01, non-split. About 60-70% of transactions, but the simpler 60-70%. Splits and refunds stay on the proven /start.

### 3. Operational rollback must be faster than code rollback

start-safe took hours to roll back — required code edits, builds, deploys.

/charge can be rolled back in 60 seconds via the admin switch. No code touch. No deploy.

### 4. Canary is necessary but not sufficient

start-safe also had a canary period — a few days, then a week. Looked clean at low volume. Black Friday volume surfaced bugs that canary missed.

Conclusion: scale-dependent bugs require either synthetic load testing OR genuinely long canary windows OR a reconciler that catches what canary misses.

### 5. Don't deploy near peak

start-safe was deployed mid-week without peak-day awareness. Bugs hit at peak, took down everything.

/charge plan explicitly avoids Friday rollouts. Friday is freeze day.

### 6. Recovery discipline matters more than the design

This was the hardest lesson. The /charge code itself isn't fundamentally smarter than /start-safe. What's different is the operational discipline: canary, kill switch, reconciler, freeze days, dual apps. start-safe could have been fine with these. /charge could fail without them.

---

## 9. Key files

| File | Purpose |
|---|---|
| `Minis-02/MINIS_02/OrderFlowView.swift` | iPad UI for the order/payment flow. /charge wiring lives here. |
| `Minis-02/MINIS_02/FastlaneModel.swift` | iPad payment handler, JSON probe. Endpoint switching logic. |
| `MinisLiveAPI/Program.cs` | Server endpoints, ~25K lines. /charge endpoint pasted around line 7569. Toggle endpoint around line 297. |
| `MinisLiveAPI/Services/ShopJsonPublisher.cs` | Generates /json/{id}.json. Pass-through for `payments` block added around line 165. |
| `MinisLiveAPI/charge-endpoint.cs` | Standalone draft of /charge endpoint, ~880 lines. Pasted into Program.cs. |
| `MinisLiveAPI/payments-flag-endpoint.cs` | Standalone draft of toggle endpoint. Pasted into Program.cs. |
| `MinisLiveAPI/wwwroot/admin/charge-toggle.html` | Admin rollback switch (also deployed at /rollback.html). |
| `Minis-02/CHARGE_DEPLOYMENT.md` | Step-by-step deployment guide. |
| `Minis-02/WEEK_PLAN.md` | 8-day plan May 2-10, 2026. |
| `Minis-02/ISSUES_BACKLOG.md` | Living issue tracker. |
| `Minis-02/SCHEDULE.md` | Saturday-specific task list. |
| `Minis-02/issues-week-2026-05-01.docx` | Hebrew weekly summary for non-technical stakeholders. |
| `Desktop/Minis-02-rollback-snapshot/` | The April 20 commit + cherry-picked fixes. Production app source. |

---

## 10. Key URLs

| URL | Purpose |
|---|---|
| `https://minis.studio/json/12.json` | Published shop config (read by iPad every fetch) |
| `https://minis.studio/api/miniapps/12/payments/charge-v2/on` | Toggle /charge ON for shop 12 |
| `https://minis.studio/api/miniapps/12/payments/charge-v2/off` | Toggle /charge OFF for shop 12 (rollback) |
| `https://minis.studio/admin/charge-toggle.html` (or /rollback.html) | Admin UI rollback switch |
| `https://minis.studio/payments/zcredit/start` | Legacy charge endpoint (current production) |
| `https://minis.studio/payments/zcredit/charge` | New charge endpoint (canary) |
| `https://pci.zcredit.co.il/ZCreditWS/api/Transaction/CommitFullTransaction` | Z-Credit gateway commit endpoint |
| `https://pci.zcredit.co.il/ZCreditWS/api/Transaction/GetTransactionStatusByTransactionUniqueIdForQuery` | Z-Credit query by unique ID (note: needs explicit `TransactionUniqueIdForQuery` param at commit time, otherwise returns "Transaction was not found") |
| `https://zcreditws.docs.apiary.io/` | Z-Credit API docs |

---

## 11. Z-Credit API reference notes

### Field naming gotchas discovered the hard way

- **CommitFullTransaction** sets `TransactionUniqueID` (no "ForQuery" suffix)
- **GetTransactionStatusByTransactionUniqueIdForQuery** queries by `TransactionUniqueIdForQuery` (different field name!)
- Empirically tested: querying by uniqueID after a /start commit returns "Transaction was not found" because /start only sets `TransactionUniqueID`, not `TransactionUniqueIdForQuery`. To enable query-based recovery, both fields must be set during commit.
- /charge's recovery uses `-88001`/`-88002` duplicate-detected response codes instead of post-hoc query, sidesteps this issue entirely.

### Important error codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `-80` | Transient ("keep waiting") — retry |
| `-50101` | Device busy — terminal in use by another transaction |
| `-88001` | Regular duplicate detected (matches TransactionUniqueID) |
| `-88002` | Advanced duplicate detected (matches TransactionUniqueID + card hash) |

### `UseAdvancedDuplicatesCheck` flag

When `true`: Z-Credit appends a hash of the card number to the TransactionUniqueID for dedup matching. Effect: same uniqueID + same card = blocked, but same uniqueID + different card = NOT blocked.

When `false`: Z-Credit dedup matches uniqueID alone. Same uniqueID = blocked regardless of card.

**Open question (test pending Sunday):** does Z-Credit's dedup count DECLINED attempts? If yes, AdvancedDup=false would falsely block legitimate decline-then-retry-with-different-card. If no, AdvancedDup=false is strictly better.

---

## 12. Open issues / future work

### Sunday May 3 — must-do before canary

- AdvancedDup decline-counts test (5 min)
- MarkPaid silent-failure alerting (5 lines)
- Audit `/orders/submit` intent="update" behavior (verified earlier — UPDATEs existing row)
- Audit `JOIN.*Customers ON Orders.CustomerId` queries (might drop CustomerId=0 rows)
- Audit `WHERE Source = 'cashpoint'` exact-match queries (might miss 'cashpoint-charge' rows)
- Audit `WHERE PaymentMethod = 'unpaid'` (must exclude 'charging' for in-flight rows to be invisible)

### This week — non-blocking but valuable

- Daily Z-Credit reconciliation script (3 AM cron)
- Server-side state-transition logging keyed by orderId

### Next iteration (after /charge stable for 2+ weeks)

- Apply row-insertion pattern to /start so split payments get same lost-response coverage
- Backfill sparse metadata on `-88001` recovery via `GetTransactionsReport` query
- Currency support beyond ILS (for non-Israel shops)
- Phone authorization (`IsTelApprovalNeeded`) handler

### Future / aspirational

- Z-Credit iOS SDK migration (terminal-direct via Bluetooth/WiFi, removes server-mediated charge path entirely)
- 3.0 launch on canary with /charge inherited
- Synthetic load testing before any future broad rollout

---

## 13. Emergency runbook

### Symptom: customer charged but order shows unpaid (or vice versa)

1. Open `https://minis.studio/admin/charge-toggle.html` (or `/rollback.html`) on phone
2. Tap toggle to "Rolled back"
3. Confirm dialog
4. Within 60 seconds, all iPads on snapshot v2 revert to /start
5. Canary iPad still on /charge for diagnostic continuity
6. Investigate the specific incident via reconciler logs the next morning

### Symptom: specific iPad behaving weirdly

1. If dual-app install present, local staff opens the OLD app build on that iPad
2. Old app always uses /start regardless of any flag
3. No network or admin access needed
4. Report to Omer for follow-up

### Symptom: reconciler alert at 3 AM

1. Open the alert email/Slack message
2. Note: `orderId`, Z-Credit reference, amount, time
3. Decision tree:
   - **Customer charged, our DB Status=0**: refund the customer via Z-Credit dashboard, OR mark our row paid manually if the discrepancy is benign
   - **Pattern of multiple alerts**: flip rollback switch, debug Saturday morning
   - **Single weird alert**: investigate but don't necessarily roll back
4. Don't panic-flip the rollback switch without checking the alert details — sometimes alerts are reconciler false positives

### Symptom: Z-Credit gateway down

1. /charge will return `commit_http_error` or `commit_http_non_200`
2. iPad shows error to customer, no money charged
3. Out of our control
4. Check Z-Credit status page

### Symptom: server-wide outage

1. iPads can't reach minis.studio at all
2. Both /start and /charge fail
3. Customers can't pay until server is back
4. Out of /charge scope — same problem with /start

---

## 14. Glossary

- **/start** — legacy payment endpoint. Calls Z-Credit, returns response. No DB row created here. ~1-2 lost-response incidents/week.
- **/start-safe** — failed iteration deployed earlier this week. Removed from app via rollback.
- **/charge** — new endpoint. Creates DB row before charging, uses Z-Credit dup detection for retry safety.
- **Snapshot** — the April 20 commit (57398de) + cherry-picked fixes, uploaded to TestFlight Friday May 1 night. Production app today.
- **Snapshot v2** — snapshot + cherry-picked /charge wiring. To be built Saturday May 2.
- **Canary build** — separate app with hardcoded `useChargeV2=true`. Independent test rig.
- **Rollback switch** — the admin HTML page at /rollback.html. Single tap kills /charge for the fleet.
- **Reconciler** — nightly script comparing DB Status=0 rows against Z-Credit transaction list, alerts on mismatches.
- **Lost-response** — class of bugs where iPad and server disagree about whether a charge happened. The architectural problem /charge solves.
- **AdvancedDup** — `UseAdvancedDuplicatesCheck=true/false` parameter for Z-Credit dedup.
- **Apple Pay endpoint** (`/checkout/zcredit/applepay`) — separate flow for App Clip Apple Pay payments. Not affected by /charge work.

---

_Last updated: May 2, 2026, 03:00 Asia/Jerusalem. Written during the build session, when context was fresh. Update as design evolves or after the canary period if anything changes._
