# Sunday May 3 — Morning Audits

Run before lunch. Total time: ~90 min. After that → canary build.

---

## 1. AdvancedDup decline-counts test (5 min) ⚡

**Why:** Decides whether `UseAdvancedDuplicatesCheck = true` in the /charge → Z-Credit call. With it ON, Z-Credit dedupes by card hash + amount + time window. We need to know if a legitimate retry (declined card → user re-swipes same card) gets blocked as a duplicate.

**How:** From the canary iPad, run two transactions back-to-back with a card you know will decline (test card or expired). Watch the second response.

**Expected:**
- If second returns `-88001/-88002` → Z-Credit dedupe is too aggressive → set `UseAdvancedDuplicatesCheck = false` in /charge body
- If second returns the same decline as the first → flag stays `true`, dedupe works as designed

---

## 2. SQL audits (20 min) — all queries against shop 12

### a) /orders/submit intent="update" behavior
Confirms that when iPad sends `intent="update"`, a row is UPDATED in place (not duplicated).

```sql
SELECT TOP 20 Id, Source, PaymentMethod, Status, CreatedAt, UpdatedAt,
       DATEDIFF(SECOND, CreatedAt, UpdatedAt) AS update_lag_sec
FROM dbo.Orders
WHERE MiniAppId = 12 AND CreatedAt > DATEADD(day, -7, SYSUTCDATETIME())
ORDER BY Id DESC;
```

**Look for:** at least some rows with `update_lag_sec > 5` (proves UPDATE happened post-insert, not just initial INSERT). If all rows have `update_lag_sec = 0`, the update path isn't being exercised.

### b) CustomerId orphans
Confirms Orders.CustomerId points to real dbo.Customers rows.

```sql
SELECT COUNT(*) AS orphan_count
FROM dbo.Orders o
LEFT JOIN dbo.Customers c ON c.Id = o.CustomerId
WHERE o.MiniAppId = 12 AND c.Id IS NULL;
```

**Expected:** 0. If > 0, either CustomerId=0 sneaked in somewhere (FK probably soft) or rows reference deleted customers.

### c) Source value distribution
Verify what Source values exist and that the new `cashpoint-charge` source is appearing once canary runs.

```sql
SELECT Source, COUNT(*) AS cnt
FROM dbo.Orders
WHERE MiniAppId = 12 AND CreatedAt > DATEADD(day, -7, SYSUTCDATETIME())
GROUP BY Source
ORDER BY cnt DESC;
```

**Expected sources:** `cashpoint`, `app`, `web`, plus `cashpoint-charge` (after canary) and `cashpoint-charge-test` (today's cleanup tag). Anything else = suspicious.

### d) PaymentMethod='unpaid' filter
Confirms in-flight /charge rows (PaymentMethod='charging') do NOT show in admin's "unpaid orders" view.

```sql
SELECT TOP 20 Id, Source, PaymentMethod, Status, Total, CreatedAt
FROM dbo.Orders
WHERE MiniAppId = 12 AND PaymentMethod = 'unpaid'
ORDER BY Id DESC;
```

**Expected:** NO rows with Source = 'cashpoint-charge'. /charge writes 'charging' specifically so admin views aren't polluted.

### e) Orders.MiniAppId FK check (carryover from today's cross-shop test)
We INSERTed row 53844 with MiniAppId=99 successfully — meaning either shop 99 exists or there's no FK. Worth knowing.

```sql
SELECT name, type_desc, OBJECT_NAME(referenced_object_id) AS references_table
FROM sys.foreign_keys
WHERE parent_object_id = OBJECT_ID('dbo.Orders');

-- And check if shop 99 exists:
SELECT Id, Name FROM dbo.MiniApps WHERE Id = 99;
```

**Action if no FK:** add one before next deploy (or add `EXISTS(SELECT 1 FROM MiniApps WHERE Id=@MiniAppId)` check at top of /charge).

---

## 3. Test row cleanup (1 min)

Tag the orphan rows from yesterday's curl tests so the Monday reconciler ignores them:

```sql
UPDATE dbo.Orders
SET Source = 'cashpoint-charge-test', PaymentMethod = 'test'
WHERE Id IN (53844, 53845, 53846, 53847, 53848, 53849, 53850);
```

---

## 4. Code audits (15 min)

### a) Apply ShopJsonPublisher.cs pass-through
3 lines after line 164. See CHARGE_DEPLOYMENT.md Step 2a:

```csharp
if (settings["payments"] is JsonObject paymentsObj && paymentsObj.Count > 0)
    clean["payments"] = paymentsObj.DeepClone();
```

**Verify after deploy:** `https://minis.studio/json/12.json` shows `"payments":{"useChargeV2":false}` inside the settings block.

### b) Rollback page accessibility check
Open `https://minis.studio/admin/charge-toggle.html` on phone. Switch should load (currently OFF since flag is false). Toggle ON, refresh, JSON shows `true`. Toggle OFF, refresh, JSON shows `false`. Bookmark on phone.

### c) MarkPaid alerting (5 lines)
Add log alert when /charge sets Status=1, so reconciler has a reference point. Tiny task, high value for Monday's reconciler.

---

## 5. iPad audits (10 min)

### a) Tenth coffee free on iPhone
Carryover from yesterday — verify the 10th coffee triggers the free reward modal as expected. Bring an iPhone, walk through the loyalty flow.

### b) Android payment end-to-end on real device
Carryover from yesterday — verify Android can complete a card payment through the existing /start flow (canary doesn't change this). Use a test Android device + real card.

---

## 6. Once PinPad is back online

### Test 1 — Fresh real charge
```bash
SID=$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')
curl -i -X POST "https://minis.studio/payments/zcredit/charge" \
  -H "Content-Type: application/json" \
  -d "{\"miniAppId\":12,\"orderId\":\"\",\"amount\":1.00,\"transactionType\":\"01\",\"sessionId\":\"$SID\"}"
```
**Expected:** 200, `path = "commit_final_fast"` or `"status_approved_fast"`, real Z-Credit reference.

### Test 5 — Lost-response recovery
1. Start a /charge as in Test 1.
2. Mid-flow (after PinPad approves, before HTTP response): yank iPad's wifi.
3. Reconnect wifi.
4. Re-run the SAME /charge with the orderId from step 1.

**Expected:** 200, `path = "charge_recovered_duplicate"` (Z-Credit returns -88001/-88002, server detects, returns success without re-charging).

---

## 7. Inventory bug debugging (separate chat)

Repro: 12 rugelach in stock → 9 sold → admin shows 10. Off by N investigation. Cross-stack — opens fresh chat for context isolation.

---

## Then afternoon → canary

- Build snapshot v2 (TestFlight beta only, NOT pushed)
- Build canary with `useChargeV2 = true` HARDCODED, bundle `minis.co.uk.canary`
- Push canary to ONE iPad
- First real card transactions through canary
- Watch logs for `commit_final_fast` / `charge_recovered_duplicate` paths

---

## Cancel-criteria for the canary push

If any of the following, **do not push the canary today** — fix first:

- AdvancedDup test reveals dedupe blocks legitimate retries
- /orders/submit intent="update" actually duplicates rows
- CustomerId orphans found > 0
- ShopJsonPublisher pass-through doesn't make `payments` block visible in /json/12.json
- Rollback page doesn't toggle the flag end-to-end
- Android or iPhone tenth-coffee verifies fail

Each of these would mean a known bug is sitting in the system that the canary would mask or amplify.
