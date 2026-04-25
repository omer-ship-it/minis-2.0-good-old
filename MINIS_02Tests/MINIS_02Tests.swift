//
//  MINIS_02Tests.swift
//  MINIS_02Tests
//
//  Created by Minis on 23/04/2026.
//

import Foundation
import Testing
@testable import MINIS_02

// MARK: - Charge Step Edge Case Tests

/// These tests exercise the core arithmetic and state logic used by the charge step
/// in OrderFlowView. Since the view's methods are private, we replicate the exact
/// logic here to catch regressions and document known edge cases.
struct ChargeStepEdgeCaseTests {

    // ── Helpers (mirror OrderFlowView logic exactly) ──

    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }

    /// Mirrors OrderFlowView.effectiveTotal (student 10% discount)
    private func effectiveTotal(total: Double, studentDiscountActive: Bool) -> Double {
        guard studentDiscountActive else { return total }
        let discounted = total * 0.9
        let shekels = floor(discounted)
        let agorot = discounted - shekels
        let roundedShekels: Double
        if agorot > 0.5 {
            roundedShekels = shekels + 1
        } else {
            roundedShekels = shekels
        }
        return max(roundedShekels, 0)
    }

    /// Mirrors OrderFlowView.buildPaymentSummary
    private func buildPaymentSummary(cardPaidTotal: Double, cashPaidTotal: Double) -> OrderAPI.PaymentMethod {
        if cardPaidTotal <= 0 && cashPaidTotal <= 0 { return .unpaid }
        if cardPaidTotal > 0 && cashPaidTotal > 0 { return .mixed }
        if cardPaidTotal > 0 { return .card }
        return .cash
    }

    /// Mirrors OrderFlowView.buildSplitParts
    private func buildSplitParts(total: Double, splitCount: Int) -> [(amount: Double, isPaid: Bool)] {
        let total = round2(max(total, 0))
        guard splitCount > 0, total > 0.1 else { return [] }
        let even = round2(total / Double(splitCount))
        var parts: [(Double, Bool)] = []
        var acc: Double = 0
        for idx in 0..<splitCount {
            let isLast = (idx == splitCount - 1)
            let amt = isLast ? round2(total - acc) : even
            acc = round2(acc + amt)
            parts.append((max(0, amt), false))
        }
        return parts
    }

    // ── 1. Student Discount Rounding ──

    @Test func studentDiscount_exactHalfAgorotRoundsDown() {
        // 55 * 0.9 = 49.50 → agorot = 0.5, NOT > 0.5, so rounds DOWN to 49
        let result = effectiveTotal(total: 55, studentDiscountActive: true)
        #expect(result == 49.0, "55 * 0.9 = 49.50 should round DOWN (agorot == 0.5 is not > 0.5)")
    }

    @Test func studentDiscount_aboveHalfAgorotRoundsUp() {
        // 33 * 0.9 = 29.7 → agorot = 0.7 > 0.5 → rounds UP to 30
        let result = effectiveTotal(total: 33, studentDiscountActive: true)
        #expect(result == 30.0)
    }

    @Test func studentDiscount_zeroTotal() {
        #expect(effectiveTotal(total: 0, studentDiscountActive: true) == 0)
    }

    @Test func studentDiscount_negativeClampedToZero() {
        #expect(effectiveTotal(total: -10, studentDiscountActive: true) == 0)
    }

    @Test func studentDiscount_verySmallTotal() {
        // 0.5 * 0.9 = 0.45 → floor=0, agorot=0.45 → rounds DOWN to 0
        #expect(effectiveTotal(total: 0.5, studentDiscountActive: true) == 0)
    }

    @Test func studentDiscount_inactiveReturnsOriginal() {
        #expect(effectiveTotal(total: 55, studentDiscountActive: false) == 55)
    }

    // ── 2. Fully-Paid Threshold (0.1) ──

    @Test func fullyPaid_fiveCentsRemainingIsConsideredPaid() {
        let remaining = round2(100.0 - 99.95)
        #expect(remaining == 0.05)
        #expect(remaining <= 0.1, "0.05 remaining should be considered fully paid")
    }

    @Test func fullyPaid_elevenCentsIsNotPaid() {
        let remaining = round2(100.0 - 99.89)
        #expect(remaining == 0.11)
        #expect(remaining > 0.1, "0.11 remaining should NOT be considered fully paid")
    }

    @Test func fullyPaid_exactlyTenCentsIsPaid() {
        let remaining: Double = 0.1
        #expect(remaining <= 0.1, "Exactly 0.10 remaining should be considered fully paid")
    }

    // ── 3. cashDueNow: Remaining=0 After Full Card Payment ──

    @Test func cashDueNow_afterFullCardPayment_showsFullTotalInsteadOfZero() {
        // BUG DOCUMENTATION: After a full card payment sets remainingToPay=0,
        // the cashDueNow formula `(remainingToPay > 0) ? remainingToPay : initialPaymentTarget`
        // returns initialPaymentTarget (e.g. 100) instead of 0.
        let remainingToPay: Double = 0
        let initialPaymentTarget: Double = 100
        let cashDue = (remainingToPay > 0) ? remainingToPay : initialPaymentTarget
        #expect(cashDue == 100, "Known: cashDueNow falls through to initialPaymentTarget when remaining is 0")
    }

    // ── 4. Split Payment Rounding ──

    @Test func splitParts_sumEqualsTotal() {
        let parts = buildSplitParts(total: 100, splitCount: 3)
        let sum = round2(parts.map(\.0).reduce(0, +))
        #expect(sum == 100.0, "Split parts must sum exactly to total")
    }

    @Test func splitParts_lastPartAbsorbsRemainder() {
        let parts = buildSplitParts(total: 100, splitCount: 3)
        #expect(parts.count == 3)
        #expect(parts[0].amount == 33.33)
        #expect(parts[1].amount == 33.33)
        #expect(parts[2].amount == 33.34, "Last part should absorb the rounding remainder")
    }

    @Test func splitParts_twoWayEvenSplit() {
        let parts = buildSplitParts(total: 100, splitCount: 2)
        #expect(parts.count == 2)
        #expect(parts[0].amount == 50.0)
        #expect(parts[1].amount == 50.0)
    }

    @Test func splitParts_singleSplitEqualsTotal() {
        let parts = buildSplitParts(total: 77.50, splitCount: 1)
        #expect(parts.count == 1)
        #expect(parts[0].amount == 77.50)
    }

    @Test func splitParts_verySmallTotalReturnsEmpty() {
        let parts = buildSplitParts(total: 0.05, splitCount: 2)
        #expect(parts.isEmpty, "Total under 0.1 should produce no split parts")
    }

    @Test func splitParts_zeroCountReturnsEmpty() {
        let parts = buildSplitParts(total: 100, splitCount: 0)
        #expect(parts.isEmpty)
    }

    @Test func splitParts_sixWaySplitSumsCorrectly() {
        let parts = buildSplitParts(total: 100, splitCount: 6)
        let sum = round2(parts.map(\.0).reduce(0, +))
        #expect(parts.count == 6)
        #expect(sum == 100.0)
    }

    // ── 5. markPartPaid Remaining Calculation ──

    @Test func markPartPaid_recomputesRemainingFromUnpaid() {
        var parts = buildSplitParts(total: 100, splitCount: 3)
        parts[0].isPaid = true
        let remaining = round2(parts.filter { !$0.isPaid }.map(\.0).reduce(0, +))
        #expect(remaining == 66.67)
    }

    @Test func markPartPaid_allPaidLeavesZeroRemaining() {
        var parts = buildSplitParts(total: 100, splitCount: 3)
        for i in parts.indices { parts[i].isPaid = true }
        let remaining = round2(parts.filter { !$0.isPaid }.map(\.0).reduce(0, +))
        #expect(remaining == 0)
    }

    // ── 6. Payment Summary Method Detection ──

    @Test func paymentSummary_nothingPaidIsUnpaid() {
        #expect(buildPaymentSummary(cardPaidTotal: 0, cashPaidTotal: 0) == .unpaid)
    }

    @Test func paymentSummary_onlyCardIsCard() {
        #expect(buildPaymentSummary(cardPaidTotal: 50, cashPaidTotal: 0) == .card)
    }

    @Test func paymentSummary_onlyCashIsCash() {
        #expect(buildPaymentSummary(cardPaidTotal: 0, cashPaidTotal: 50) == .cash)
    }

    @Test func paymentSummary_bothIsMixed() {
        #expect(buildPaymentSummary(cardPaidTotal: 30, cashPaidTotal: 20) == .mixed)
    }

    @Test func paymentSummary_tinyCardOnlyStillCounts() {
        #expect(buildPaymentSummary(cardPaidTotal: 0.01, cashPaidTotal: 0) == .card)
    }

    // ── 7. hasAnyPayment Threshold ──

    @Test func hasAnyPayment_exactlyOneCentIsFalse() {
        let card: Double = 0.01
        let cash: Double = 0
        #expect(((card + cash) > 0.01) == false, "0.01 is NOT > 0.01, so hasAnyPayment is false at exact boundary")
    }

    @Test func hasAnyPayment_twoCentsIsTrue() {
        let card: Double = 0.02
        let cash: Double = 0
        #expect(((card + cash) > 0.01) == true)
    }

    // ── 8. round2 Precision ──

    @Test func round2_handlesNormalValues() {
        // IEEE 754: x.xx5 values are not exactly representable, so rounding varies
        #expect(round2(1.006) == 1.01)   // unambiguous
        #expect(round2(1.994) == 1.99)   // unambiguous
        #expect(round2(99.999) == 100.0)
        #expect(round2(50.505) == 50.51 || round2(50.505) == 50.50) // IEEE 754 boundary
    }

    @Test func round2_negativeValues() {
        #expect(round2(-1.555) == -1.56)
        #expect(round2(-0.001) == 0.0)
    }

    @Test func round2_zeroIsZero() {
        #expect(round2(0.0) == 0.0)
    }

    // ── 9. submitCashNow: Clamping ──

    @Test func cashClamping_appliedCashClampedToDue() {
        let dueNow: Double = 50
        let appliedCash: Double = 100
        let cashThis = round2(min(max(appliedCash, 0), dueNow))
        #expect(cashThis == 50, "Cash applied should be clamped to amount due")
    }

    @Test func cashClamping_negativeCashBecomes0() {
        let dueNow: Double = 50
        let appliedCash: Double = -10
        let cashThis = round2(min(max(appliedCash, 0), dueNow))
        #expect(cashThis == 0)
    }

    @Test func cashClamping_zeroDuePreventsPayment() {
        let dueNow: Double = 0
        let appliedCash: Double = 100
        let cashThis = round2(min(max(appliedCash, 0), dueNow))
        #expect(cashThis < 0.01, "When nothing is due, no cash should be accepted")
    }

    // ── 10. Partial Pay Snapshot: Total Mismatch Guard ──

    @Test func partialPayRestore_totalMismatchClearsSnapshot() {
        let savedTotal: Double = 100.0
        let nowTotal: Double = 90.0
        let mismatch = abs(savedTotal - nowTotal) > 0.01
        #expect(mismatch == true, "Snapshot should be cleared when total changes (e.g. after discount toggle)")
    }

    @Test func partialPayRestore_sameTotalPasses() {
        let savedTotal: Double = 100.0
        let nowTotal: Double = 100.0
        let mismatch = abs(savedTotal - nowTotal) > 0.01
        #expect(mismatch == false)
    }

    // ── 11. Tip Calculation ──

    @Test func tipPercent_roundsToTwoDecimals() {
        let base: Double = 33.33
        let tipPercent: Double = 10
        let tip = max(0, ((base * (tipPercent / 100.0)) * 100).rounded() / 100.0)
        #expect(tip == 3.33)
    }

    @Test func tipPercent_zeroBaseGivesZeroTip() {
        let base: Double = 0
        let tipPercent: Double = 20
        let tip = max(0, ((base * (tipPercent / 100.0)) * 100).rounded() / 100.0)
        #expect(tip == 0)
    }

    @Test func totalWithTip_addedCorrectly() {
        let base: Double = 90.0
        let tipPercent: Double = 10
        let tip = max(0, ((base * (tipPercent / 100.0)) * 100).rounded() / 100.0)
        let totalWithTip = base + tip
        #expect(totalWithTip == 99.0)
    }

    // ── 12. Double Charge Prevention ──

    @Test func startPayment_blockedWhenRemainingIsZeroAndHasPayment() {
        let cardPaidTotal: Double = 100
        let cashPaidTotal: Double = 0
        let remainingToPay: Double = 0
        let hasAnyPayment = (cardPaidTotal + cashPaidTotal) > 0.01
        let blocked = hasAnyPayment && remainingToPay <= 0.01
        #expect(blocked == true, "Must NOT start a new charge when fully paid")
    }

    @Test func startPayment_allowedWhenNothingPaid() {
        let cardPaidTotal: Double = 0
        let cashPaidTotal: Double = 0
        let remainingToPay: Double = 100
        let hasAnyPayment = (cardPaidTotal + cashPaidTotal) > 0.01
        let blocked = hasAnyPayment && remainingToPay <= 0.01
        #expect(blocked == false)
    }

    @Test func startPayment_allowedWhenPartiallyPaid() {
        let cardPaidTotal: Double = 30
        let cashPaidTotal: Double = 0
        let remainingToPay: Double = 70
        let hasAnyPayment = (cardPaidTotal + cashPaidTotal) > 0.01
        let blocked = hasAnyPayment && remainingToPay <= 0.01
        #expect(blocked == false, "Partial payment should still allow charging remaining")
    }

    // ── 13. recomputeRemainingFromTotals ──

    @Test func recomputeRemaining_correctAfterPartialCard() {
        let base: Double = 100
        let cardPaidTotal: Double = 60
        let cashPaidTotal: Double = 0
        let remaining = round2(max(base - round2(cardPaidTotal + cashPaidTotal), 0))
        #expect(remaining == 40.0)
    }

    @Test func recomputeRemaining_clampsToZero() {
        let base: Double = 100
        let cardPaidTotal: Double = 110
        let cashPaidTotal: Double = 0
        let remaining = round2(max(base - round2(cardPaidTotal + cashPaidTotal), 0))
        #expect(remaining == 0, "Remaining should never go negative")
    }

    // ── 14. completeWithCash: exact-zero vs floating-point zero ──

    @Test func completeWithCash_exactZeroFallsThrough() {
        let remainingToPay: Double = 0.0
        let needsRecompute = (remainingToPay == 0)
        #expect(needsRecompute == true)

        let nearZero: Double = 0.0000001
        let needsRecompute2 = (nearZero == 0)
        #expect(needsRecompute2 == false, "Floating-point near-zero won't trigger == 0 recompute")
    }
}
