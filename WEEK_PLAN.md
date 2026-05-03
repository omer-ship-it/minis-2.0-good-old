# 8-Day Plan — May 2 to May 10, 2026

Window: Omer is on-site at the Israel shop for these 8 days. After May 10 he travels to UK for another launch. Plan must leave the system in autopilot-safe state by departure.

---

## Architecture for the week

**Two app builds on each iPad:**

1. **Snapshot v2** (production) — current rollback snapshot + cherry-picked /charge wiring (pendingChargeOrderId, JSON probe, payLegacyStart routing). Bundle ID: `minis.co.uk` (overwrites today's snapshot install). Behavior controlled by server switch:
   - Switch OFF → calls /start (identical to today's snapshot)
   - Switch ON → calls /charge (with lost-response protections)

2. **Canary build** — separate test app with `useChargeV2=true` HARDCODED. Bundle ID: `minis.co.uk.canary` (coexists with v2 on canary iPad only). Always uses /charge regardless of server switch. Independent test rig.

**Three layers of safety:**

- iPad app picker (per-device, instant) — switch to OLD/snapshot v2 with switch OFF
- Server flag (global, ~60s) — affects all snapshot v2 iPads simultaneously
- Reconciler (catches what the other two miss, alerts overnight)

---

## Day-by-day

### Sat May 2 — Stabilize old system + cherry-pick

- [ ] Fix inventory bug (12 rugelach repro: 12 → 9 sold → shows 10)
- [ ] Verify Android payment end-to-end on real device
- [ ] Verify tenth coffee free on iPhone
- [ ] Cherry-pick /charge wiring from live tree into rollback snapshot:
  - `OrderFlowView.swift`: pendingChargeOrderId @State, useChargeV2 @AppStorage, 3 pay() call sites with orderId capture, isSplitPayment param at split site, clear on .approved
  - `FastlaneModel.swift`: ZCreditResult.orderId field, finishFromResponse JSON parsing, payLegacyStart endpoint switching with !isSplitPayment + transactionType==01 guards, PaymentsConfigProbe + apply step

### Sun May 3 — Deploy server + canary live

**Morning:**
- [ ] AdvancedDup decline-counts test (5 min, decides true vs false flag)
- [ ] Quick audits: Source filters, CustomerId joins, PaymentMethod='unpaid' filter, /orders/submit intent="update" verified
- [ ] Paste /charge endpoint into Program.cs
- [ ] Paste toggle endpoint (`/api/miniapps/{id}/payments/charge-v2/{status}`) into Program.cs
- [ ] Apply ShopJsonPublisher.cs pass-through (3 lines for `payments` block)
- [ ] Verify rollback.html accessible at minis.studio/rollback.html

**Afternoon:**
- [ ] Build snapshot v2 (with /charge wiring) — TestFlight beta only, NOT pushed
- [ ] Build canary (hardcoded /charge) — push to one iPad with new bundle ID
- [ ] Run real card transactions through canary, watch logs for `commit_final_fast` / `charge_recovered_duplicate` paths

### Mon May 4 — Reconciler

- [ ] Build daily Z-Credit reconciliation script (3 AM cron, scans Status=0 rows past 24h, queries Z-Credit, alerts on mismatches)
- [ ] Deploy reconciler
- [ ] Watch canary metrics throughout the day

### Tue May 5 — Push v2 to fleet (flag still OFF)

- [ ] If canary clean for 48h → push snapshot v2 to all iPads (overwrites today's snapshot)
- [ ] Server switch stays OFF — v2 behaves identically to v1 (calls /start)
- [ ] Watch for any v2-specific issues today (caught BEFORE flipping the switch)

### Wed May 6 — Flip switch ON

- [ ] If snapshot v2 clean for 24h with switch OFF → flip switch to ON via rollback.html
- [ ] All iPads with snapshot v2 start using /charge within ~60 seconds
- [ ] Canary still hardcoded ON (independent confirmation channel)
- [ ] Watch reconciler results from Mon and Tue nights

### Thu May 7 — Watch + pre-Friday calm

- [ ] No changes
- [ ] Monitor logs, reconciler results
- [ ] If anything weird → flip switch OFF (60s recovery)

### Fri May 8 — First Friday with /charge live across fleet

- [ ] **NO CHANGES**
- [ ] Active log monitoring during rush hours
- [ ] Switch in pocket — if any payment weirdness reported by staff → flip OFF, debug Sat
- [ ] If Friday clean → real confidence

### Sat May 9 — Brief local staff

- [ ] If Friday clean → leave switch ON
- [ ] Brief local staff (or whoever's on-site after departure) on:
  - Two apps installed on canary iPad, one app elsewhere
  - rollback.html bookmark on their phone
  - When to use it (any payment issue reported by staff or customer)
  - Direct contact for anything beyond the switch

### Sun May 10 — Travel day

- [ ] Final state verification before leaving:
  - Snapshot v2 on all iPads, switch ON (= using /charge)
  - Canary build still on canary iPad
  - Reconciler running, alerts pointed at phone
  - rollback.html bookmarked on phone + local staff phone

---

## Departure-state safety checklist

- [ ] All iPads on snapshot v2 with /charge active
- [ ] Reconciler running nightly, alerts to phone
- [ ] rollback.html bookmarked
- [ ] Local contact briefed
- [ ] Canary still active as independent monitoring channel
- [ ] No outstanding deploys mid-flight

---

## Things explicitly DEFERRED to next trip

- **3.0 launch** — too much to add in this window. Validate next time you're on-site.
- **Broader expansion to non-shop-12** — currency hardcoded to ILS, needs work for non-Israel shops.
- **Apple Pay /applepay path** — not changed in this window; existing behavior preserved.
- **/start row-insertion** for split-payment lost-response — next iteration after /charge proves stable.

---

## Emergency runbook (for after departure)

**Symptom:** Customer charged but order shows unpaid, or vice versa.
**Action:** Open `https://minis.studio/rollback.html` on phone → toggle to "Rolled back" → confirm. Within 60s all iPads on /start. Canary keeps running on /charge for diagnostic data.

**Symptom:** Specific iPad acts weird with /charge.
**Action:** Local staff opens that iPad's "old" version of the app (if dual install) OR you flip global switch.

**Symptom:** Reconciler alert at 3 AM Israel time.
**Action:** Check the alert, find the orphan row, decide: refund the customer, or flip switch and debug. Don't panic-flip without checking the alert details first.
