# /charge endpoint — complete deployment package

Everything needed to deploy the new `/charge` endpoint with server-controlled rollback flag. Each step shows exactly what to change.

---

## Order of deployment

1. **Server SQL** — seed the flag (already done if you ran the UPDATE earlier)
2. **Server code** — `ShopJsonPublisher.cs` pass-through + `Program.cs` endpoints
3. **Server static** — `charge-toggle.html` (already in `wwwroot/admin/`)
4. **iOS** — already wired in `OrderFlowView.swift` + `FastlaneModel.swift` (default OFF, no behavior change until flag flips)
5. **Verify** — bookmark the rollback page, test toggle, then canary on one iPad

---

## STEP 1 — SQL (one-time, idempotent)

Run once against production DB to seed the flag at `false`. Already done if you ran this earlier today.

```sql
UPDATE dbo.MiniApps
SET Customization =
    JSON_MODIFY(
        JSON_MODIFY(Customization, '$.settings.payments', JSON_QUERY('{}')),
        '$.settings.payments.useChargeV2',
        CAST(0 AS BIT)
    )
WHERE Id = 12;
```

Verify:

```sql
SELECT Id, JSON_VALUE(Customization, '$.settings.payments.useChargeV2') AS flag
FROM dbo.MiniApps WHERE Id = 12;
-- expect: 12 | false
```

---

## STEP 2a — `ShopJsonPublisher.cs` change

Open `MinisLiveAPI/Services/ShopJsonPublisher.cs`.

Find the block around line 163 that handles `defaultLocationId`:

```csharp
if (settings["defaultLocationId"] is not null)
    clean["defaultLocationId"] = settings["defaultLocationId"]!.DeepClone();
```

Add immediately after:

```csharp
// ✅ payments config (server-driven feature flags)
if (settings["payments"] is JsonObject paymentsObj && paymentsObj.Count > 0)
    clean["payments"] = paymentsObj.DeepClone();
```

That's the only change in this file. 3 lines added.

---

## STEP 2b — Toggle endpoint in `Program.cs`

Paste near the other `/api/miniapps/{id:int}/...` endpoints (around line 297, after the highlights endpoint):

```csharp
// =============================================================================
// /api/miniapps/{id}/payments/charge-v2/{status}
// One-click toggle for the useChargeV2 flag. Updates DB + republishes JSON.
// status accepts: on/off, true/false, 1/0
// =============================================================================
app.MapGet("/api/miniapps/{id:int}/payments/charge-v2/{status}", async (
    int id,
    string status,
    IDbConnectionFactory dbf,
    Minis.Services.IShopJsonPublisher publisher,
    ILogger<Program> log) =>
{
    if (id <= 0)
        return Results.BadRequest(new { ok = false, error = "id must be > 0" });

    bool enabled;
    var s = (status ?? "").Trim().ToLowerInvariant();
    if (s == "on" || s == "true" || s == "1")        enabled = true;
    else if (s == "off" || s == "false" || s == "0") enabled = false;
    else return Results.BadRequest(new { ok = false, error = "status must be on/off (or true/false, 1/0)" });

    try
    {
        dynamic? before = null;
        dynamic? after = null;

        using (var conn = dbf.Create())
        {
            conn.Open();

            before = await conn.QueryFirstOrDefaultAsync(@"
SELECT Id,
       JSON_VALUE(Customization, '$.settings.payments.useChargeV2') AS UseChargeV2
FROM dbo.MiniApps
WHERE Id = @id", new { id });

            if (before == null)
                return Results.NotFound(new { ok = false, message = "MiniApp not found", id });

            await conn.ExecuteAsync(@"
UPDATE dbo.MiniApps
SET Customization =
    JSON_MODIFY(
        JSON_MODIFY(Customization, '$.settings.payments', JSON_QUERY('{}')),
        '$.settings.payments.useChargeV2',
        CAST(@enabledBit AS BIT)
    )
WHERE Id = @id;",
                new { id, enabledBit = enabled ? 1 : 0 });

            after = await conn.QueryFirstOrDefaultAsync(@"
SELECT Id,
       JSON_VALUE(Customization, '$.settings.payments.useChargeV2') AS UseChargeV2
FROM dbo.MiniApps
WHERE Id = @id", new { id });
        }

        await publisher.GenerateAndPublishShopJsonAsync(id);

        log.LogWarning(
            "PAYMENTS FLAG: miniAppId={MiniAppId} useChargeV2 set to {Enabled} (was {Before}). Republished JSON.",
            id, enabled, (object?)before?.UseChargeV2);

        return Results.Ok(new
        {
            ok = true,
            miniAppId = id,
            enabled,
            before,
            after,
            published = true,
            note = enabled
                ? "/charge ENABLED — iPads pick up within ~60s."
                : "/charge DISABLED — iPads revert to /start within ~60s."
        });
    }
    catch (Exception ex)
    {
        log.LogError(ex, "Payments flag toggle failed for miniAppId={MiniAppId}", id);
        return Results.Problem(
            title: "Payments flag toggle failed",
            detail: ex.ToString(),
            statusCode: 500
        );
    }
});
```

---

## STEP 2c — `/payments/zcredit/charge` endpoint in `Program.cs`

Paste right after the `/payments/zcredit/start` endpoint ends (around line 7569, before `/payments/zcredit/start-safe` begins).

The complete endpoint is in `MinisLiveAPI/charge-endpoint.cs` — paste the entire `app.MapPost("/payments/zcredit/charge", ...)` block (everything between the doc comment and the closing `});`).

---

## STEP 3 — Static page

Already saved at `MinisLiveAPI/wwwroot/admin/charge-toggle.html`. No changes needed if `app.UseStaticFiles()` is in `Program.cs` (it should be by default).

After deploy, visit:
```
https://minis.studio/admin/charge-toggle.html
```

Bookmark this URL on your phone — it's your one-tap rollback.

---

## STEP 4 — iOS (already in code, default OFF, no behavior change)

These changes already shipped in:

- `OrderFlowView.swift`:
  - Added `@State private var pendingChargeOrderId: Int? = nil`
  - Added `@AppStorage("payments.useChargeV2") private var useChargeV2: Bool = false`
  - All 3 pay() call sites pass `orderId: pendingChargeOrderId` and capture `result.orderId`
  - Split call site (line 4302) passes `isSplitPayment: true` to force /start
  - `pendingChargeOrderId = nil` on `.approved` so split halves don't reuse the row

- `FastlaneModel.swift`:
  - `ZCreditResult` struct gained `orderId: Int?` field
  - `finishFromResponse` extracts `serverOrderId` from JSON response
  - `pay()` accepts `isSplitPayment: Bool = false` param
  - `payLegacyStart` reads `UserDefaults.standard.bool(forKey: "payments.useChargeV2")` AND checks `transactionType == "01"` AND `!isSplitPayment` before routing to `/charge`
  - Approved/declined path classification updated to recognize `commit_final_fast`, `status_approved_fast`, `charge_already_paid`, `charge_recovered_duplicate` (approved) and `charge_wrong_status`, `charge_precheck_db_error`, `charge_insert_failed` (declined)
  - Added probe (`PaymentsConfigProbe`) that reads `mini.settings.payments.useChargeV2` from the published JSON on every fetch and writes to UserDefaults — server-driven flag propagation

These need a TestFlight build to ship. Default value is OFF, so they're harmless until you flip the flag.

---

## STEP 5 — Verify after deploy

1. Visit `https://minis.studio/json/12.json` directly. Confirm you see `"payments":{"useChargeV2":false}` inside the `settings` block. If not, the publisher pass-through (Step 2a) didn't deploy.

2. Visit `https://minis.studio/admin/charge-toggle.html`. Page should load with the switch OFF (since flag is false). Toggle should respond.

3. Tap the switch ON. Confirm the dialog. Refresh the page — switch should now be ON. Visit `/json/12.json` again — flag should be `true`.

4. Tap the switch OFF (rollback). Confirm. Refresh — switch OFF. JSON shows `false`.

5. From a canary iPad (TestFlight build with the new iOS code): trigger a card payment. Server logs should show `🔵 ZCredit /payments/zcredit/charge cURL:` instead of `/start` when flag is ON.

---

## Emergency rollback

Anytime, from any phone:

1. Open `https://minis.studio/admin/charge-toggle.html`
2. Tap the switch OFF
3. Confirm
4. iPads on shop 12 revert to `/start` within ~60 seconds

That's the panic button.

---

## Sunday-only items still pending

These don't block deployment but should follow within the same week:

- AdvancedDup decline-counts test (5 min)
- MarkPaid alerting (5 lines)
- Quick audits: `/orders/submit` intent="update" behavior, CustomerId joins, Source filters, PaymentMethod='unpaid' filter
- Daily Z-Credit reconciliation script
- Decision: hardcode `cardStartMode = .legacyStart` in canary build to force every charge through /charge during canary

See `ISSUES_BACKLOG.md` for the full list.
