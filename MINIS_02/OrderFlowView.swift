import SwiftUI
import UniformTypeIdentifiers
import Kingfisher
import Combine

struct OrderFlowView: View {
    let onSendToKitchen: () -> Void      // injected from CashPointView
    @State private var showManualCardEntry = false
    @State private var lastZCreditReference: String? = nil
    @State private var didConfirmNameThisSession: Bool = false
    @State private var didSubmitThisFlow: Bool = false
    @State private var isSubmittingNow: Bool = false
    @State private var didFinishThisFlow: Bool = false
    @State private var lastCashPaidAt: Date? = nil
    @State private var lastCashDueAtPay: Double = 0
    @State private var lastCashReceivedAtPay: Double = 0
    @State private var didInit = false
    @State private var confirmationAutoResetTask: Task<Void, Never>? = nil
    @State private var splitCardTapLocked = false
    @State private var splitBaseTotal: Double? = nil
    @State private var payAttemptToken: String = ""
    @AppStorage("miniAppId") private var storedMiniAppId: Int = 0   // only if you already store it
    @State private var nameKbMode: NameKbMode = .he                 // runtime toggle
    @State private var partialPayToken: String = ""
    @State private var payAttemptId: String = ""
    @State private var paySessionId: String? = nil
    @State private var payRef: String? = nil
    @State private var payTxId: String? = nil
    
    @AppStorage("pos.ticketNumber") private var posTicketNumber: Int = 0
    @MainActor
    private func ensureTicketNow(reason: String) {
        if posTicketNumber <= 0 {
            // ✅ minimal, safe: derive a local "session ticket" so logs always attach
            // (does NOT affect server order id / real ticketing)
            posTicketNumber = Int(Date().timeIntervalSince1970) % 1_000_000  // 6-digit
            print("🟧[PaymentLog] ticket generated locally: \(posTicketNumber) (\(reason))")
        }
    }
    private var ticketNow: Int {
        // must be > 0 to log
        max(posTicketNumber, 0)
    }
    @MainActor
    private func beginPayAttempt(_ tag: String) {
        payAttemptId = UUID().uuidString
        paySessionId = nil
        payRef = nil
        payTxId = nil
        ensureTicketNow(reason: tag)
        if ticketNow > 0 {
            pLog(.uiTap, ticket: ticketNow, amount: round2(currentTargetAmount), reason: tag)
        }
    }
    private func pLog(
        _ type: PaymentEventType,
        ticket: Int,
        amount: Double,
        status: String? = nil,
        path: String? = nil,
        ms: Int? = nil,
        reason: String? = nil
    ) {
        if payAttemptId.isEmpty { payAttemptId = UUID().uuidString }

        PaymentJournal.shared.log(.init(
            ts: Date().timeIntervalSince1970,
            ticket: ticket,
            miniAppId: MenuTheme.miniId,
            amount: amount,
            attemptId: payAttemptId,
            sessionId: paySessionId,
            referenceNumber: payRef,
            transactionId: payTxId,
            status: status,
            path: path,
            ms: ms,
            reason: reason,
            type: type
        ))
    }
    @AppStorage("nameKbMode13") private var nameKbMode13Raw: String = "he" // persist per shop
    private enum NameKbMode: String { case he, ar }
    private var hasSavedName: Bool {
        !posSavedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasProgress: Bool {
        round2(remainingToPay) < round2(initialPaymentTarget) - 0.01
    }
    private func dbg(_ msg: String) {
        print("🟦[PartialPay] \(msg)")
    }

    private func dbgDumpStore(prefix: String = "") {
        let ud = UserDefaults.standard
        let card = ud.double(forKey: PartialPayStore.card)
        let cash = ud.double(forKey: PartialPayStore.cash)
        let rem  = ud.double(forKey: PartialPayStore.remaining)
        let tot  = ud.double(forKey: PartialPayStore.total)
        let ts   = ud.double(forKey: PartialPayStore.ts)
        let token = ud.string(forKey: PartialPayStore.token) ?? ""
        let mini = ud.integer(forKey: PartialPayStore.mini)

        dbg("\(prefix)store: card=\(card) cash=\(cash) rem=\(rem) total=\(tot) ts=\(ts) age=\(ts > 0 ? Int(Date().timeIntervalSince1970 - ts) : -1)s mini=\(mini) token=\(token.prefix(8))…")
    }

    private enum PartialPayStore {
        static let card = "pos.partialPay.card"
        static let cash = "pos.partialPay.cash"
        static let remaining = "pos.partialPay.remaining"
        static let total = "pos.partialPay.total"

        // ✅ fingerprint
        static let ts = "pos.partialPay.ts"         // TimeInterval since 1970
        static let token = "pos.partialPay.token"   // random per flow
        static let mini = "pos.partialPay.miniId"   // optional but cheap
    }


    @MainActor
    private func persistPartialPaySnapshot() {
        if partialPayToken.isEmpty {
            partialPayToken = UUID().uuidString
        }

        let now = Date().timeIntervalSince1970

        UserDefaults.standard.set(cardPaidTotal, forKey: PartialPayStore.card)
        UserDefaults.standard.set(cashPaidTotal, forKey: PartialPayStore.cash)
        UserDefaults.standard.set(remainingToPay, forKey: PartialPayStore.remaining)
        UserDefaults.standard.set(round2(initialPaymentTarget), forKey: PartialPayStore.total)

        UserDefaults.standard.set(now, forKey: PartialPayStore.ts)
        UserDefaults.standard.set(partialPayToken, forKey: PartialPayStore.token)
        UserDefaults.standard.set(MenuTheme.miniId, forKey: PartialPayStore.mini)

      
        dbg("PERSIST ✅ token=\(partialPayToken.prefix(8))… now=\(Int(now)) totalNow=\(round2(initialPaymentTarget)) hasAnyPayment=\(hasAnyPayment) remaining=\(remainingToPay)")
        dbgDumpStore(prefix: "after persist: ")
        
    }

  
   
    @MainActor
    private func restorePartialPaySnapshotIfAny() {
        #if DEBUG
        dbg("RESTORE attempt… totalNow=\(round2(initialPaymentTarget)) miniNow=\(MenuTheme.miniId)")
        dbgDumpStore(prefix: "before restore: ")
        #endif

        let ud = UserDefaults.standard

        let card       = ud.double(forKey: PartialPayStore.card)
        let cash       = ud.double(forKey: PartialPayStore.cash)
        let rem        = ud.double(forKey: PartialPayStore.remaining)
        let savedTotal = ud.double(forKey: PartialPayStore.total)

        let savedTs    = ud.double(forKey: PartialPayStore.ts)
        let savedToken = ud.string(forKey: PartialPayStore.token) ?? ""
        let savedMini  = ud.integer(forKey: PartialPayStore.mini)

        guard (card + cash) > 0.01 else {
            #if DEBUG
            dbg("RESTORE skip: nothing meaningful saved (card+cash=\(card+cash))")
            #endif
            return
        }

        // 1) total guard
        let nowTotal = round2(initialPaymentTarget)
        if savedTotal > 0.01, abs(savedTotal - nowTotal) > 0.01 {
            #if DEBUG
            dbg("RESTORE CLEAR: total mismatch saved=\(savedTotal) now=\(nowTotal)")
            #endif
            clearPartialPaySnapshot()
            return
        }

        // 2) freshness guard (5 minutes)
        let maxAge: TimeInterval = 15 * 60
        let nowTs = Date().timeIntervalSince1970
        let age = nowTs - savedTs
        if savedTs <= 0 || age < 0 || age > maxAge {
            #if DEBUG
            dbg("RESTORE CLEAR: age invalid savedTs=\(savedTs) age=\(Int(age))s max=\(Int(maxAge))s")
            #endif
            clearPartialPaySnapshot()
            return
        }

        // 3) mini guard
        if savedMini != 0 && savedMini != MenuTheme.miniId {
            #if DEBUG
            dbg("RESTORE CLEAR: mini mismatch savedMini=\(savedMini) nowMini=\(MenuTheme.miniId)")
            #endif
            clearPartialPaySnapshot()
            return
        }

        if !savedToken.isEmpty {
            partialPayToken = savedToken
        }

        cardPaidTotal = card
        cashPaidTotal = cash

        if rem > 0.1 {
            remainingToPay = rem
        } else {
            recomputeRemainingFromTotals()
        }

      
        dbg("RESTORE ✅ token=\(partialPayToken.prefix(8))… restored card=\(cardPaidTotal) cash=\(cashPaidTotal) remaining=\(remainingToPay)")
       
    }

    @MainActor
    private func clearPartialPaySnapshot() {
        #if DEBUG
        dbg("CLEAR 🧹 (before)")
        dbgDumpStore(prefix: "")
        #endif

        UserDefaults.standard.removeObject(forKey: PartialPayStore.card)
        UserDefaults.standard.removeObject(forKey: PartialPayStore.cash)
        UserDefaults.standard.removeObject(forKey: PartialPayStore.remaining)
        UserDefaults.standard.removeObject(forKey: PartialPayStore.total)

        UserDefaults.standard.removeObject(forKey: PartialPayStore.ts)
        UserDefaults.standard.removeObject(forKey: PartialPayStore.token)
        UserDefaults.standard.removeObject(forKey: PartialPayStore.mini)

        partialPayToken = ""

       
        dbg("CLEAR ✅ (after)")
        dbgDumpStore(prefix: "")
      
    }
    
    
    @MainActor
    private func pushFlowAndLandOn(_ last: Route) {
        // Build the logical sequence
        var seq: [Route] = []

        if isMini13 {
            seq.append(.name)              // no service for mini13
        } else {
            seq.append(.service)
            seq.append(.name)
        }

        if mustAskPhone {
            seq.append(.phone)
        }

        seq.append(.charge)

        // If you ever want to land somewhere else:
        // (e.g. last == .phone), just truncate up to that point.
        if let idx = seq.firstIndex(of: last) {
            seq = Array(seq.prefix(idx + 1))
        }

        // Reset stack
        path = NavigationPath()
        root = seq.first ?? .charge

        // Push the rest with animations disabled
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            for r in seq.dropFirst() {
                path.append(r)
            }
        }
    }
    private var hasSavedPhone: Bool {
        let d = posSavedPhone.filter(\.isNumber)
        return d.count == 10 && d.first == "0"
    }
    
   
    @MainActor
    private func hydrateDraftFromStorageIfNeeded() {
        if cashPointMode {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = posSavedName
            }
            if phoneDigits.filter(\.isNumber).isEmpty {
                phoneDigits = posSavedPhone
            }
        } else {
            name = ""
            phoneDigits = ""
        }
    }
    private var isMini13: Bool { MenuTheme.miniId == 13 }
    @AppStorage("cashPointMode") private var cashPointMode: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var restartWork: DispatchWorkItem? = nil
    @State private var showLockedPricingAlert = false
    func kioskFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if cashPointMode {
            // ✅ CashPoint (staff / POS) → system font
            return .system(size: size, weight: weight)
        } else {
            // ✅ Kiosk / customer → brand font
            return .primariesDemi(size)
        }
    }
    
    private var chipBackground: Color {
        Color(.secondarySystemBackground)
    }

    private var chipActiveBackground: Color {
        // MUCH stronger contrast but still adaptive
        colorScheme == .dark
            ? Color.primary.opacity(0.35)
            : Color.primary.opacity(0.15)
    }

    private var chipForeground: Color {
        colorScheme == .dark ? .white : .primary
    }

    private func chipStroke(_ active: Bool) -> Color {
        active
            ? Color.primary.opacity(colorScheme == .dark ? 0.6 : 0.35)
            : Color.primary.opacity(0.12)
    }
    
    private var cleanName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameValid: Bool {
        cleanName.count >= 2
    }
    private var mustAskPhone: Bool {
        // kiosk/customer always requires phone
        !cashPointMode || requiresPhoneStep
    }
    private func saveDraftContact() {
        posSavedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let d = phoneDigits.filter(\.isNumber)
        posSavedPhone = d
    }
    
    private var hasAnyPayment: Bool {
        (cardPaidTotal + cashPaidTotal) > 0.01
    }

    /// If true → we must NOT change totals (discount/tip) and must NOT restart terminal
    private var pricingLocked: Bool {
        hasAnyPayment 
    }
    
    private func clearDraftContact() {
        posSavedName = ""
        posSavedPhone = ""
        name = ""
        phoneDigits = ""
        didConfirmNameThisSession = false
    }
    private var primaryButtonBackground: Color {
        if cashPointMode {
            // POS: strong neutral, works in both modes
            return Color.primary
        } else {
            // Kiosk brand color (already adaptive)
            return MenuTheme.buttonBackground
        }
    }

    private var primaryButtonForeground: Color {
        // Always readable
        return Color(UIColor.systemBackground)
    }

    private var secondaryButtonBackground: Color {
        Color(UIColor.secondarySystemBackground)
    }

    private var secondaryButtonForeground: Color {
        Color.primary
    }

    private var disabledButtonBackground: Color {
        Color.primary.opacity(0.25)
    }

    private var disabledButtonForeground: Color {
        Color.primary.opacity(0.6)
    }
    enum Route: Hashable {
        case service
        case name
        case phone
        case charge
        case confirmation
    }

    @State private var path = NavigationPath()
    @State private var root: Route = .service
    
    private func push(_ r: Route) {
        if isMini13 && r == .service { return }

        path.append(r)
    }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    private func goToNextAfterService_push() {
        if !hasSavedName {
            push(.name)
        } else if mustAskPhone && !hasConfirmedPhoneForThisFlow{
            push(.phone)
        } else {
            push(.charge)
        }
    }

    private func goToChargeFromName_push() {
        push(mustAskPhone ? .phone : .charge)
    }

    private func goToChargeFromPhone_push() {
        push(.charge)
    }
   
    
    @MainActor
    private func commitPartialSnapshot() {
        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameParam  = cleanName.isEmpty ? nil : cleanName
        let summary    = buildPaymentSummary()

        let discountOff = studentDiscountActive ? max(0, total - effectiveTotal) : 0
        let tipOff      = max(0, tipAmount)

        // ✅ also persist so printing never loses it mid-flow
        if let n = nameParam { posSavedName = n }
        if let p = phoneParam { posSavedPhone = p.filter(\.isNumber) }
        
        persistPartialPaySnapshot()
        onPartialUpdate(phoneParam, nameParam, summary, discountOff, tipOff)
    }
    
    private var cashDueNow: Double {
        // 1) Manual "Pay on the bill" amount
        if let manual = manualCashTargetAmount {
            return round2(max(manual, 0))
        }

        // 2) Split part
        if isSplitMode,
           let idx = activeSplitIndex,
           splitParts.indices.contains(idx) {
            return round2(max(Double(splitParts[idx].amount), 0))
        }

        // 3) Normal cash (full order or remaining after previous payments) — INCLUDING TIP
        let due = (remainingToPay > 0) ? remainingToPay : initialPaymentTarget
        return round2(max(due, 0))
    }
    @MainActor
    private func submitPayLaterNow() {
        ensureTicketNow(reason: "LATER")
        if ticketNow > 0 {
            pLog(.uiTap, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "LATER")
            pLog(.reconcileTap, ticket: ticketNow, amount: round2(currentTargetAmount), status: "unpaid", reason: "SUBMIT")
        }
        guard !didSubmitThisFlow && !isSubmittingNow else { return }
        isSubmittingNow = true
        clearPartialPaySnapshot()
        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameParam  = cleanName.isEmpty ? nil : cleanName

        // ✅ persist BEFORE submit
        if let n = nameParam { posSavedName = n }
        if let p = phoneParam { posSavedPhone = p.filter(\.isNumber) }

        let summary = OrderAPI.PaymentSummary(method: .unpaid, cashAmount: 0, cardAmount: 0)

        let discountOff = studentDiscountActive ? max(0, total - effectiveTotal) : 0
        let tipOff      = max(0, tipAmount)
        if ticketNow > 0 {
            pLog(.uiBlocked,
                 ticket: ticketNow,
                 amount: round2(currentTargetAmount),
                 reason: "CANCEL_TERM")
        }
        print("🟡 PAY LATER tapped → submitting unpaid order")
        onCompleted(phoneParam, nameParam, summary, discountOff, tipOff)

        didSubmitThisFlow = true

        DispatchQueue.main.async {
            self.isSubmittingNow = false
            if !cashPointMode {
                self.goToConfirmationAfterSuccess()
            } else {
                self.onFinish()
            }
        }
    }

    @discardableResult
    @MainActor
    private func submitCashNow(appliedCash: Double) -> Bool {
        guard !isSubmittingNow else { return false }

        // ✅ Base = what we intended to collect for the whole order (incl tip)
        let baseTotal = round2(initialPaymentTarget)

        // ✅ Ensure remaining is initialized at least once
        if remainingToPay <= 0.1 {
            recomputeRemainingFromTotals()
        }

        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameParam  = cleanName.isEmpty ? nil : cleanName

        // ✅ Decide "due now" based on mode (single source of truth)
        let dueNow: Double = {
            // 1) Pay-on-the-bill cash amount
            if let manual = manualCashTargetAmount {
                return round2(max(manual, 0))
            }

            // 2) Split-part cash amount
            if isSplitMode,
               let idx = activeSplitIndex,
               splitParts.indices.contains(idx) {
                return round2(max(Double(splitParts[idx].amount), 0))
            }

            // 3) Normal cash: outstanding
            return round2(max(remainingToPay, 0))
        }()

        // ✅ Clamp applied cash to dueNow (so we never "pay" more than we need)
        let cashThis = round2(min(max(appliedCash, 0), dueNow))
        guard cashThis >= 0.01 else { return false }

        isSubmittingNow = true
        defer { isSubmittingNow = false }

        // ✅ Update local totals (optimistic)
        cashPaidTotal = round2(cashPaidTotal + cashThis)

        var acceptedCash = false

        // ✅ Apply to remaining + mark paid rows when relevant
        if let manual = manualCashTargetAmount {
            // Pay-on-the-bill (manual)
            let manualDue = round2(max(manual, 0))
            let applied   = round2(min(cashThis, manualDue))

            remainingToPay = round2(max(remainingToPay - applied, 0))
            acceptedCash   = applied >= 0.01

            // ✅ persist partial state for mid-flow dismiss
            if acceptedCash {
                persistPartialPaySnapshot()
            }

            // clear manual mode after applying
            manualCashTargetAmount = nil
            activeSplitIndex = nil

        } else if isSplitMode,
                  let idx = activeSplitIndex,
                  splitParts.indices.contains(idx) {

            // Split-row cash: must cover the part to mark it paid
            let partDue    = round2(Double(splitParts[idx].amount))
            let coversPart = cashThis >= partDue - 0.1

            if coversPart {
                // ✅ mark the split row as paid (markPartPaid recomputes remainingToPay)
                markPartPaid(idx)
                acceptedCash = true

                // ✅ persist partial state for mid-flow dismiss
                persistPartialPaySnapshot()

                activeSplitIndex = nil
                manualCashTargetAmount = nil
            } else {
                // ❌ not enough to pay this split part -> don't proceed
                // Roll back cashPaidTotal change:
                cashPaidTotal = round2(max(cashPaidTotal - cashThis, 0))
                acceptedCash = false
                return false
            }

        } else {
            // Normal cash
            remainingToPay = round2(max(remainingToPay - cashThis, 0))
            acceptedCash = true

            // ✅ persist partial state for mid-flow dismiss
            persistPartialPaySnapshot()
        }

        // ✅ IMPORTANT: stamp lastCashPaidAt ONLY if we actually accepted cash
        if acceptedCash {
            lastCashPaidAt = Date()
        }

        let summary = buildPaymentSummary()
        let discountOff = studentDiscountActive ? max(0, total - effectiveTotal) : 0
        let tipOff      = max(0, tipAmount)

        let fullyPaid = remainingToPay <= 0.1

        if fullyPaid {
            clearPartialPaySnapshot() // ✅ add

            onCompleted(phoneParam, nameParam, summary, discountOff, tipOff)
            return true
        } else {
            // ✅ PARTIAL submit (no close / no reset)
            onPartialUpdate(phoneParam, nameParam, summary, discountOff, tipOff)

            // ✅ Return to charge screen (so waiter can take remaining by card)
            DispatchQueue.main.async {
                payingWithCash = false
                cashPaid = false
                cashInput = ""
                justUsedBills = false
                billSum = 0

                isPaying = false
                payError = nil

                // allow manual re-try of card; DO NOT auto-start
                paymentStarted = false
            }
            return false
        }
    }

    private var hasConfirmedPhone: Bool {
        let d = posSavedPhone.filter(\.isNumber)
        return d.count == 10 && d.first == "0"
    }

    
    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }
    
   
    
   
    @State private var hasSentToKitchenFromCash: Bool = false
    private func sendOrderToKitchenFromCash() {
    
        onSendToKitchen()                 
       
    }
    
   
    
  

    @State private var lastResultWasUnknown: Bool = false
    struct AppConfig {
        static var isDemoMode: Bool = false   // demo: card always succeeds
    }
    @State private var cashPaid: Bool = false
    @State private var studentDiscountActive: Bool = false

    // 💁‍♂️ Tip state
    @State private var tipPercent: Double? = nil      // e.g. 10, 12, 15, 20
    @State private var tipFixedAmount: Double? = nil  // ₪ amount override
    @State private var showTipSheet: Bool = false

    @State private var hasApprovedCardPayment: Bool = false
    @State private var cardPaidTotal: Double = 0
    @State private var cashPaidTotal: Double = 0
    
    
    private let bill20URL  = "https://www.leftovercurrency.com/app/uploads/2018/06/20-israeli-new-sheqalim-banknote-rachel-bluwstein-obverse-1-433x235.jpg"
    private let bill50URL  = "https://www.leftovercurrency.com/app/uploads/2017/04/50-israeli-new-shekels-banknote-shaul-tchernichovsky-obverse-1-433x221.jpg"
    private let bill100URL = "https://www.leftovercurrency.com/app/uploads/2018/06/100-israeli-new-sheqalim-banknote-leah-goldberg-reverse-1-433x212.jpg"
    private let bill200URL = "https://www.leftovercurrency.com/app/uploads/2017/04/200-israeli-new-shekels-banknote-nathan-alterman-obverse-433x206.jpg"

    private func playCashSuccessOnly() {
        showSuccess = true
        successScale = 0.6
        successOpacity = 0

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.1)) {
            successScale = 1.0
            successOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                successOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showSuccess = false
            }
        }
    }
    
    private var serviceStep: some View {
        VStack {
            Spacer()

            VStack(spacing: 24) {

                // Title
                Text(isRtl ? "איך תרצה להזמין?" : "How would you like to dine?")
                    .font(kioskFont(26, weight: .bold))
                    .multilineTextAlignment(.center)

                // Subtitle
                Text(isRtl ? "בחר אם ההזמנה לשבת או לקחת" :
                             "Choose whether the order is dine-in or takeaway")
                .font(kioskFont(15, weight: .regular))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // --- TWO BUTTONS IN ONE ROW ---
                HStack(spacing: 16) {

                    Button {
                        diningMode = .dineIn
                        onServiceChosen()
                        goToNextAfterService_push()
                    } label: {
                        Text(isRtl ? "לשבת" : "Dine in")
                            .font(kioskFont(18, weight: .bold))
                            
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                Color.primary
                            )
                        
                            .foregroundColor(Color(UIColor.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        
                    }
                   

                    Button {
                        diningMode = .takeAway
                        onServiceChosen()
                        goToNextAfterService_push()
                    } label: {
                        Text(isRtl ? "לקחת" : "Take away")
                            .font(kioskFont(18, weight: .bold))
                            
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                Color.primary
                            )
                            .foregroundColor(Color(UIColor.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                .frame(maxWidth: 460)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }
    
    // Effective total for this payment step (10% off when active)
    private var effectiveTotal: Double {
        // No student discount → use original total
        guard studentDiscountActive else { return total }

        // 10% discount
        let discounted = total * 0.9

        // Split into shekels + agorot
        let shekels = floor(discounted)
        let agorot = discounted - shekels

        // If more than 50 agorot → round up, else down
        let roundedShekels: Double
        if agorot > 0.5 {
            roundedShekels = shekels + 1
        } else {
            roundedShekels = shekels
        }

        return max(roundedShekels, 0)
    }
    
    private var baseToCharge: Double {
        effectiveTotal
    }
    
    // How much we want to collect in total (used when no partial payments yet)
    private var initialPaymentTarget: Double {
        totalWithTip
    }

    // Computed tip amount (either % of base or fixed amount)
    private var tipAmount: Double {
        if let p = tipPercent {
            let v = baseToCharge * (p / 100.0)
            return max(0, (v * 100).rounded() / 100.0) // round to 2 decimals
        }
        if let fixed = tipFixedAmount {
            return max(0, fixed)
        }
        return 0
    }

    // Final total INCLUDING tip (this is what we actually charge)
    private var totalWithTip: Double {
        baseToCharge + tipAmount
    }
    // SPLIT MODEL
    struct SplitPart: Identifiable, Equatable {
        let id: Int          // index
        var amount: Double     // integer currency units
        var isPaid: Bool
    }

    let total: Double
    let isRtl: Bool
    @Binding var diningMode: DiningMode
    let requiresPhoneStep: Bool
    let onCancel: () -> Void
    let onCompleted: (String?, String?, OrderAPI.PaymentSummary, Double, Double) -> Void
    let onPartialUpdate: (String?, String?, OrderAPI.PaymentSummary, Double, Double) -> Void
    let onFinish: () -> Void
    let allowPayLater: Bool
    let skipServiceStep: Bool
    let onServiceChosen: () -> Void
    let startAtCharge: Bool
    
    
    private var isOrderFullyPaid: Bool {
        remainingToPay <= 0.1
    }
    private func buildPaymentSummary() -> OrderAPI.PaymentSummary {
        let card = cardPaidTotal
        let cash = cashPaidTotal

        let method: OrderAPI.PaymentMethod
        if card <= 0 && cash <= 0 {
            method = .unpaid
        } else if card > 0 && cash > 0 {
            method = .mixed
        } else if card > 0 {
            method = .card
        } else {
            method = .cash
        }

        return OrderAPI.PaymentSummary(
            method: method,
            cashAmount: cash,
            cardAmount: card
        )
    }

    // MARK: - State

    @AppStorage("posSavedName") private var posSavedName: String = ""
    @AppStorage("posSavedPhone") private var posSavedPhone: String = ""

    @State private var name: String = ""
    @State private var phoneDigits: String = ""
    
    @State private var isPaying = false
    @State private var payError: String?
    @State private var paymentStarted = false
    @Environment(\.currency) private var currency

    // Cash state
    @State private var payingWithCash: Bool = false
    @State private var cashInput: String = ""
    @State private var hadCardPayment: Bool = false
      @State private var hadCashPayment: Bool = false
    @State private var justUsedBills: Bool = false
    @State private var billSum: Int = 0
    // Split state
    @State private var isSplitMode: Bool = false
    @State private var splitCount: Int = 2
    @State private var splitParts: [SplitPart] = []
    @State private var remainingToPay: Double = 0
    @State private var activeSplitIndex: Int? = nil

    // Split amount pad
    @State private var showSplitAmountPad: Bool = false
    @State private var splitAmountPadIndex: Int? = nil
    @State private var splitAmountInput: String = ""

    // Split sheet (list of rows)
    @State private var showSplitSheet: Bool = false

    // Pay-on-the-bill pad
    @State private var showOnBillPad: Bool = false
    @State private var onBillInput: String = ""

    // Success animation
    @State private var showSuccess: Bool = false
    @State private var successScale: CGFloat = 0.6
    @State private var successOpacity: Double = 0

    // Manual cash target for "Pay on the bill"
    @State private var manualCashTargetAmount: Double? = nil

    // MARK: - Derived

    private var formattedPhone: String {
        formatIL(phoneDigits)
    }

    private var canFinishNow: Bool {
        // payment complete (card/cash/split/manual) -> remaining is 0
        remainingToPay <= 0.1 && (cardPaidTotal + cashPaidTotal) > 0.1
    }
    
    init(
        onSendToKitchen: @escaping () -> Void,
        total: Double,
        isRtl: Bool,
        diningMode: Binding<DiningMode>,
        requiresPhoneStep: Bool,
        onCancel: @escaping () -> Void,
        onCompleted: @escaping (String?, String?, OrderAPI.PaymentSummary, Double, Double) -> Void,
        onFinish: @escaping () -> Void,
        allowPayLater: Bool,
        skipServiceStep: Bool,
        onServiceChosen: @escaping () -> Void,
        startAtCharge: Bool,
        onPartialUpdate: @escaping (String?, String?, OrderAPI.PaymentSummary, Double, Double) -> Void = { _,_,_,_,_ in }
    ) {
        self.onSendToKitchen = onSendToKitchen
        self.total = total
        self.isRtl = isRtl
        self._diningMode = diningMode
        self.requiresPhoneStep = requiresPhoneStep
        self.onCancel = onCancel
        self.onCompleted = onCompleted
        self.onFinish = onFinish
        self.allowPayLater = allowPayLater
        self.skipServiceStep = skipServiceStep
        self.onServiceChosen = onServiceChosen
        self.startAtCharge = startAtCharge
        self.onPartialUpdate = onPartialUpdate
    }
    @ViewBuilder
    private func billImageButton(amount: Int, imageURL: String) -> some View {
        Button {
            tapBill(amount)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.systemGray5))

                KFImage(URL(string: imageURL))
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .cornerRadius(14)
            }
            .frame(width: 180, height: 90)
        }
        .buttonStyle(.plain)
    }

    private var billButtonsRow: some View {
        HStack(spacing: 10) {
            billImageButton(amount: 20,  imageURL: bill20URL)
            billImageButton(amount: 50,  imageURL: bill50URL)
            billImageButton(amount: 100, imageURL: bill100URL)
            billImageButton(amount: 200, imageURL: bill200URL)
        }
        .padding(.horizontal, 10)   // 👈 small left-right breathing room
            .padding(.vertical, 4)
    }

    
    private func setNameKbMode(_ m: NameKbMode) {
        nameKbMode = m
        if isMini13 { nameKbMode13Raw = m.rawValue }
    }
    
    private var arabicRowsWide: [[String]] {
        [
            ["ض","ص","ث","ق","ف","غ","ع","ه","خ","ح","ج","د","⌫"],
            ["ش","س","ي","ب","ل","ا","ت","ن","م","ك","ط"],
            ["ئ","ء","ؤ","ر","لا","ى","ة","و","ز","ظ","'"],
            ["مسافة"] // keep your existing space label so your width logic stays identical
        ]
    }
    private func tapBill(_ value: Int) {
        // Take only digits from current text
        let digitsOnly = cashInput.filter(\.isNumber)
        let current = Int(digitsOnly) ?? 0

        let newValue = current + value
        cashInput = String(newValue)

        // Mark that the value now comes from bills
        justUsedBills = true
    }
    
    private var cashAmount: Double {
        let trimmed = cashInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return Double(trimmed) ?? 0
    }
    

    private var currentTargetAmount: Double {
        if let manual = manualCashTargetAmount { return manual }

        if isSplitMode,
           let idx = activeSplitIndex,
           splitParts.indices.contains(idx) {
            return Double(splitParts[idx].amount)
        }

        // ✅ normal flow: charge what's actually left (includes tip)
        return (remainingToPay > 0) ? remainingToPay : initialPaymentTarget
    }

    private var changeAmount: Double {
        if cashPaid {
            return max(round2(lastCashReceivedAtPay - lastCashDueAtPay), 0)
        }
        return max(round2(cashAmount - cashDueNow), 0)
    }

    // MARK: - Body
    
    var body: some View {
        NavigationStack(path: $path) {

            // ✅ ROOT SCREEN (dynamic)
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                // ✅ root content only (NO custom header)
                rootView

                // ✅ success overlay stays global
                if showSuccess {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(.primary).frame(width: 110, height: 110)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 52, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .scaleEffect(successScale)
                            .opacity(successOpacity)

                            Text(isRtl ? "ההזמנה אושרה" : "Order approved")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
            .navigationBarTitleDisplayMode(.inline)

            // ✅ Static X button in the native nav bar (uses default back chevron)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        saveDraftContact()
                        cancelAll() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(10)
                            
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // ✅ PUSHED DESTINATIONS
            .navigationDestination(for: Route.self) { r in
                Group {
                    switch r {
                    case .service:
                        serviceStep
                    case .name:
                        nameStep
                    case .phone:
                        phoneStep
                    case .charge:
                        chargeStep
                            .onAppear { handleChargeEntered() }
                            .safeAreaInset(edge: .bottom) {
                                if cashPointMode && 1==2 {
                                    HStack {
                                        Spacer()
                                        CashPointView.SwipeToSendOrderView(
                                            isRtl: isRtl,
                                            hasSent: hasSentToKitchenFromCash,
                                            onSend: { sendOrderToKitchenFromCash() }
                                        )
                                        Spacer()
                                    }
                                    .padding(.bottom, 70)
                                }
                            }
                            .alert(isRtl ? "כבר בוצע חיוב" : "Payment already taken",
                                   isPresented: $showLockedPricingAlert) {
                                Button(isRtl ? "הבנתי" : "OK", role: .cancel) { }
                            } message: {
                                Text(isRtl
                                     ? "לא ניתן להחיל הנחה לאחר חיוב. יש לבצע זיכוי/ביטול עסקה ואז לחייב מחדש."
                                     : "You can’t apply a discount after charging. Do a refund/void, then charge again.")
                            }
                          //
                    case .confirmation: confirmationStep
                    }
                    
                }
              
                // ✅ ensure X also appears on pushed screens
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            saveDraftContact()
                            cancelAll() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(10)
                               
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
            }
            .onChange(of: remainingToPay) { v in
                dbg("remainingToPay -> \(round2(v)) (paid=\(round2(cardPaidTotal + cashPaidTotal)) totalNow=\(round2(initialPaymentTarget)))")
            }
            .onChange(of: cardPaidTotal) { v in
                dbg("cardPaidTotal -> \(round2(v)) (remaining=\(round2(remainingToPay)))")
            }
            .onChange(of: cashPaidTotal) { v in
                dbg("cashPaidTotal -> \(round2(v)) (remaining=\(round2(remainingToPay)))")
            }
            .onDisappear {
                let shouldPersist = cashPointMode && remainingToPay > 0.1 && (hasAnyPayment || hasProgress)
                print("🟦[PartialPay] onDisappear: cashPointMode=\(cashPointMode) hasAnyPayment=\(hasAnyPayment) hasProgress=\(hasProgress) remaining=\(round2(remainingToPay)) shouldPersist=\(shouldPersist)")
                if shouldPersist {
                    persistPartialPaySnapshot()
                }
            }
            .onAppear {
                dbg("onAppear: didInit=\(didInit) cashPointMode=\(cashPointMode) remaining=\(round2(remainingToPay)) paid=\(round2(cardPaidTotal + cashPaidTotal)) totalNow=\(round2(initialPaymentTarget))")

                // ✅ Always attempt restore in POS mode (even if view instance is reused)
                if cashPointMode {
                    restorePartialPaySnapshotIfAny()
                    dbg("onAppear AFTER restore: remaining=\(round2(remainingToPay)) paid=\(round2(cardPaidTotal + cashPaidTotal)) totalNow=\(round2(initialPaymentTarget))")
                }

                // ✅ Keep the “init once” logic only for stack-building / navigation setup
                guard !didInit else { return }
                didInit = true

                if partialPayToken.isEmpty { partialPayToken = UUID().uuidString }
                if isMini13 { nameKbMode = NameKbMode(rawValue: nameKbMode13Raw) ?? .he }

                if cashPointMode {
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = posSavedName
                    }
                    phoneDigits = posSavedPhone
                } else {
                    name = ""
                    phoneDigits = ""
                }
                if remainingToPay == 0 { recomputeRemainingFromTotals() }

                let land: Route = {
                    if startAtCharge { return .charge }
                    if !hasSavedName { return isMini13 ? .name : .service }
                    if mustAskPhone && !hasConfirmedPhoneForThisFlow { return .phone }
                    return .charge
                }()

                Task { @MainActor in
                    hydrateDraftFromStorageIfNeeded()
                    pushFlowAndLandOn(land)
                }
            }

            // keep your sheets/covers exactly the same:
            .fullScreenCover(isPresented: $payingWithCash) { cashFullScreen }
            .sheet(isPresented: $showSplitSheet) { splitSheetView }
            .onChange(of: showSplitSheet) { v in
                print("🟣 showSplitSheet -> \(v)")
            }
            .onChange(of: showSplitAmountPad) { v in
                print("🟣 showSplitAmountPad -> \(v), idx=\(String(describing: splitAmountPadIndex))")
            }
            .onChange(of: showOnBillPad) { v in
                print("🟣 showOnBillPad -> \(v)")
            }
            .onChange(of: payingWithCash) { v in
                print("🟣 payingWithCash -> \(v)")
            }
            .onChange(of: showTipSheet) { v in
                print("🟣 showTipSheet -> \(v)")
            }
            .onChange(of: isSplitMode) { v in
                print("🟣 isSplitMode -> \(v), parts=\(splitParts.count)")
            }
            .onChange(of: showTipSheet) { presented in
                // When the tip sheet closes, tipPercent / tipFixedAmount has already been updated.
                guard presented == false else { return }
                restartPaymentAfterTipChangeIfNeeded()
            }
            .fullScreenCover(isPresented: $showTipSheet) {
                TipSheetView(
                    isRtl: isRtl,
                    currency: currency,
                    baseAmount: baseToCharge,
                    tipPercent: $tipPercent,
                    tipFixedAmount: $tipFixedAmount,
                    isPresented: $showTipSheet
                )
            }
            .sheet(isPresented: $showSplitAmountPad) {
                if let idx = splitAmountPadIndex,
                   splitParts.indices.contains(idx) {
                    SplitAmountPadView(
                        isRtl: isRtl,
                        currency: currency,
                        title: isRtl ? "סכום לתשלום \(idx + 1)" : "Amount for payment \(idx + 1)",
                        input: $splitAmountInput,
                        onDone: { value in
                            applySplitAmount(newValue: value, index: idx)
                            showSplitAmountPad = false
                        },
                        onCancel: {
                            showSplitAmountPad = false
                        }
                    )
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                } else {
                    // safety: never show a blank sheet
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(isRtl ? "טוען…" : "Loading…")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .onAppear {
                        // close if state is inconsistent
                        DispatchQueue.main.async {
                            showSplitAmountPad = false
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showOnBillPad) {
                OnBillPadView(
                    isRtl: isRtl,
                    currency: currency,
                    currentRemaining: (remainingToPay > 0 ? remainingToPay : initialPaymentTarget),
                    input: $onBillInput,

                    onCard: { amount in
                        let base = (remainingToPay > 0 ? remainingToPay : initialPaymentTarget)
                        let clamped = min(max(amount, 0), base)
                        guard clamped >= 0.01 else { return }

                        // ✅ prevent double-tap spam
                        guard !isPaying else { return }

                        payError = nil

                        // ✅ If we just took cash, let terminal settle a bit
                        let settleDelay: TimeInterval = {
                            guard let t = lastCashPaidAt else { return 0 }
                            let dt = Date().timeIntervalSince(t)
                            return (dt < 2.0) ? 0.9 : 0
                        }()

                        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                            payOnBillWithCard(amount: clamped) { approved in
                                if approved {
                                    showOnBillPad = false
                                } else {
                                    Haptics.error()
                                }
                            }
                        }
                    },

                    onCash: { amount in
                        let base = (remainingToPay > 0 ? remainingToPay : initialPaymentTarget)
                        let clamped = min(max(amount, 0), base)
                        guard clamped > 0 else { return }

                        manualCashTargetAmount = clamped
                        isSplitMode = false
                        activeSplitIndex = nil

                        cashInput = ""
                        payError = nil
                        isPaying = false
                        paymentStarted = false

                        showOnBillPad = false
                        payingWithCash = true
                    },

                    onCancel: {
                        // prevent closing mid-transaction
                        guard !isPaying else { return }
                        showOnBillPad = false
                    },

                    isPaying: $isPaying,
                    ringLabel: isRtl ? "" : "Waiting for terminal…"
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
        }
        
    }

    
    
    // MARK: - Inline split panel (like the demo)

    private var splitPanel: some View {
            VStack(spacing: 16) {
                // Header: split count + cancel
                HStack {
                    Text(isRtl ? "מספר חלקים" : "Number of parts")
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()

                    Button {
                        increaseSplitCount(-1)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .disabled(splitCount <= 2)

                    Text("\(splitCount)")
                        .font(.system(size: 18, weight: .bold))
                        .frame(minWidth: 32)

                    Button {
                        increaseSplitCount(1)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .disabled(splitCount >= 6)

                    Button {
                        isSplitMode = false
                           splitParts.removeAll()
                           activeSplitIndex = nil
                           splitBaseTotal = nil
                           recomputeRemainingFromTotals()
                    } label: {
                        Text(isRtl ? "בטל" : "Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }

                // Split rows
                VStack(spacing: 10) {
                    ForEach(splitParts.indices, id: \.self) { idx in
                        let part = splitParts[idx]
                        let amount = Double(part.amount)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(isRtl ? "תשלום \(idx + 1)" : "Payment \(idx + 1)")
                                    .font(.system(size: 16, weight: .medium))

                                // In the demo this just reused the on-bill pad; we keep that
                                Button {
                                    onBillInput = String(Int(amount.rounded()))
                                    showOnBillPad = true
                                } label: {
                                    Text(String(format: "\(currency)%.2f", amount))
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            if part.isPaid {
                                Text(isRtl ? "שולם" : "Paid")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                            } else {
                                // Credit card for this split row
                                Button {
                                    // ✅ prevent double tap / overlapping start
                                    guard !isPaying, !splitCardTapLocked else { return }
                                    splitCardTapLocked = true

                                    // ✅ do NOT cancel right before pay (causes instant failure)
                                    payError = nil
                                    activeSplitIndex = idx

                                    // ✅ small settle delay helps terminal state transitions
                                    let settleDelay: TimeInterval = {
                                        guard let t = lastCashPaidAt else { return 0.15 }
                                        return (Date().timeIntervalSince(t) < 2.0) ? 0.9 : 0.15
                                    }()

                                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                                        startCardForSplitPart(index: idx)
                                    }
                                } label: {
                                    Text(isRtl ? "אשראי" : "Credit card")
                                        .font(.system(size: 16, weight: .semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }

                                // Cash for this split row
                                Button {
                                    if !AppConfig.isDemoMode {
                                        ZCreditPaymentHandler.shared.cancelCurrent()
                                    }
                                    activeSplitIndex = idx
                                    manualCashTargetAmount = nil
                                    cashInput = ""
                                    payError = nil
                                    payingWithCash = true
                                } label: {
                                    Text(isRtl ? "מזומן" : "Cash")
                                        .font(.system(size: 16, weight: .semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .opacity(part.isPaid ? 0.6 : 1.0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 500)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }

    // Toggle split on/off, equal-splitting like in the demo
    private func toggleSplitMode() {
        // 🔹 Always cancel any in-flight ZCredit transaction first
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        if isSplitMode {
            // Turn OFF split – keep outstanding amount as-is
            isSplitMode = false
            splitParts.removeAll()
            activeSplitIndex = nil
            splitBaseTotal = nil
            // DO NOT force remainingToPay = 0 (let recompute handle it)
            recomputeRemainingFromTotals()
            // don't touch remainingToPay – it keeps whatever is still outstanding
        } else {
            // Turn ON split – base on outstanding, or full total if first time
            isSplitMode = true
            recomputeRemainingFromTotals()
            splitBaseTotal = remainingToPay > 0 ? remainingToPay : initialPaymentTarget
            splitCount = 2
            splitParts = buildSplitParts()
        }
    }

    private func increaseSplitCount(_ delta: Int) {
        let newCount = splitCount + delta
        guard newCount >= 2, newCount <= 6 else { return }
        splitCount = newCount
       
        splitParts = buildSplitParts()
        // ❌ do NOT touch remainingToPay here
    }
    
    @ViewBuilder
    private var rootView: some View {
        switch root {
        case .service: serviceStep
        case .name: nameStep
        case .phone: phoneStep
        case .charge: chargeStep
        case .confirmation: confirmationStep   // ✅
        }
    }


    
    private func handleChargeEntered() {
        // ✅ Auto-start ONLY for the clean "full card" flow
        guard !paymentStarted else { return }
        guard !isPaying else { return }
        guard !payingWithCash else { return }
        guard !isSplitMode else { return }
        guard manualCashTargetAmount == nil else { return }
        guard activeSplitIndex == nil else { return }
        guard !showOnBillPad else { return }
        guard !showSplitSheet else { return }
        guard !showSplitAmountPad else { return }
        guard (cardPaidTotal + cashPaidTotal) < 0.01 else { return }

        paymentStarted = true
        payError = nil

        beginPayAttempt("AUTO")


        DispatchQueue.main.async {
            ensureTicketNow(reason: "handleChargeEntered auto-start")
               if ticketNow > 0 {
                   pLog(.uiTap, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "AUTO start (handleChargeEntered)")
               }
            startPayment()
        }
    }
    
    /// Called after the tip sheet closes to restart ZCredit with the new total (including tip)
    private func restartPaymentAfterTipChangeIfNeeded() {

        // ✅ If any money was already taken → refuse (refund/void is required)
        guard !hasAnyPayment else {
            showLockedPricingAlert = true
            Haptics.error()
            return
        }

        // ✅ Cancel any scheduled restart to avoid double-starts
        restartWork?.cancel()
        restartWork = nil

        // 1) Cancel any in-flight ZCredit transaction
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        // 2) Reset payment UI state
        isPaying = false
        payError = nil

        // 3) Only auto-restart if this is a simple full-card flow
        guard !payingWithCash,
              !isSplitMode,
              manualCashTargetAmount == nil,
              activeSplitIndex == nil
        else {
            // In other flows just update remaining, and let cashier trigger payment manually
            recomputeRemainingFromTotals()
            return
        }

        // 4) Reset remainingToPay to the new total WITH tip
        recomputeRemainingFromTotals()

        // 5) Restart ZCredit once (debounced)
        paymentStarted = true

        let work = DispatchWorkItem {
            self.startPayment()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
    
    private struct TerminalActivityRing: View {
        let isActive: Bool
        let label: String

        @State private var spin: Double = 0
        @State private var breathe: Bool = false

        var body: some View {
            VStack(spacing: 12) {

                ZStack {

                    // 🟤 Base ring
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 6)

                    // ✨ Active arc
                    Circle()
                        .trim(from: 0.18, to: 0.42)
                        .stroke(
                            Color.primary.opacity(0.9),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(spin))
                        .animation(
                            isActive
                            ? .linear(duration: 1.8).repeatForever(autoreverses: false)
                            : .default,
                            value: spin
                        )
                }
                .frame(width: 88, height: 88)
                .scaleEffect(breathe ? 1.04 : 0.96)
                .animation(
                    isActive
                    ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                    : .default,
                    value: breathe
                )

                // 🧘 Calm label
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                guard isActive else { return }
                spin = 360
                breathe = true
            }
            .onChange(of: isActive) { active in
                if active {
                    spin = 360
                    breathe = true
                } else {
                    spin = 0
                    breathe = false
                }
            }
        }
    }
    // MARK: - Step: Charge (card OR cash)
    private func toggleStudentDiscount() {

        // ✅ If any money was already taken → refuse (refund flow is required)
        guard !hasAnyPayment else {
            showLockedPricingAlert = true
            Haptics.error()
            return
        }

        // Cancel any scheduled restart to avoid double-starts
        restartWork?.cancel()
        restartWork = nil

        studentDiscountActive.toggle()

        // 1) Cancel any in-flight ZCredit transaction
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        // 2) Reset payment UI state
        isPaying = false
        payError = nil

        // ✅ In the clean full-card flow, update remaining and restart once
        if !isSplitMode, manualCashTargetAmount == nil, activeSplitIndex == nil {
            recomputeRemainingFromTotals()
        }

        // Only auto-restart for clean full-card flow
        guard !payingWithCash,
              !isSplitMode,
              manualCashTargetAmount == nil,
              activeSplitIndex == nil
        else { return }

        // 3) Mark started so nothing else auto-starts during the wait
        paymentStarted = true

        // 4) ✅ Wait 3 seconds after cancel, then start again
        // 4) ✅ Wait 3 seconds after cancel, then start again
        let work = DispatchWorkItem {
            // If something changed during the wait, don’t start
            guard !isPaying,
                  !payingWithCash,
                  !isSplitMode,
                  manualCashTargetAmount == nil,
                  activeSplitIndex == nil
            else { return }

            startPayment()
        }

        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
    
    private func retryZCreditNow() {
        // same behavior as "תשלום באשראי"
        startCardForRemainingNow()
    }
    
    private func startCardForRemainingNow() {
        if ticketNow > 0 {
            beginPayAttempt("RETRY")
               
            }

        cancelPendingRestart()
        // ✅ If we’re already paying, don’t start another.
        guard !isPaying else { return }

        // ✅ Do NOT cancel here — only cancel if there is an active transaction.
        // (Calling cancelCurrent right before pay often causes instant failure.)
        // if !AppConfig.isDemoMode { ZCreditPaymentHandler.shared.cancelCurrent() }

        payError = nil
        lastResultWasUnknown = false

        // Clear blockers
        payingWithCash = false
        cashPaid = false
        cashInput = ""
        justUsedBills = false
        billSum = 0

        manualCashTargetAmount = nil
        isSplitMode = false
        activeSplitIndex = nil

        // Ensure remaining is initialized
        let baseTotal = round2(initialPaymentTarget)
        if remainingToPay <= 0.1 {
            remainingToPay = baseTotal
        }

        // mark started so onChange(step) won’t auto-trigger
        paymentStarted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.startPayment()
        }

    }
    
    private var isCashEnough: Bool {
        let received = round2(cashAmount)
        let due      = round2(cashDueNow)
        return received >= due && due >= 0.01
    }
    
    private var chargeStep: some View {
        let terminalActive = isPaying && !payingWithCash

        // ✅ Amount logic (single source of truth for display)
        let baseWithTip: Double = totalWithTip
        let alreadyPaid: Double = cardPaidTotal + cashPaidTotal
        let displayAmount: Double = max(baseWithTip - alreadyPaid, 0)

        let studentDiscountValue: Double = max(total - effectiveTotal, 0)

        // iPhone 8 / small phones
        let isSmallPhone: Bool = {
            guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
            return UIScreen.main.bounds.height <= 667   // iPhone 8 / SE2 / SE3 height class
        }()

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let errorSlotH: CGFloat = 28

        return GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {

                VStack(spacing: 24) {

                    // Title
                    Text(isRtl ? "הסכום לתשלום" : "Amount to charge")
                        .font(kioskFont(20, weight: .medium))
                        .foregroundColor(.secondary)

                    // 🔢 Big amount + discount/tip lines
                    VStack(spacing: 4) {
                        Text(String(format: "%.2f", displayAmount))
                            .font(kioskFont(50, weight: .heavy))

                        if studentDiscountActive, studentDiscountValue > 0 {
                            Text(
                                isRtl
                                ? String(format: "הנחת סטודנט 10%%  -\(currency)%.2f", studentDiscountValue)
                                : String(format: "Student 10%% discount  -\(currency)%.2f", studentDiscountValue)
                            )
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        }

                        if tipAmount > 0 {
                            Text(
                                String(
                                    format: isRtl ? "טיפ: \(currency)%.2f" : "Tip: \(currency)%.2f",
                                    tipAmount
                                )
                            )
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        }
                    }

                    // ✅ CashPoint controls (Tip / Split / Partial / Student)
                    if cashPointMode {
                        Group {
                            if isPhone {
                                VStack(spacing: 10) {

                                    HStack(spacing: 10) {
                                        // Split
                                        Button { toggleSplitMode() } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 19, weight: .semibold))
                                                Text(isRtl ? "פיצול שווה" : "Split")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .frame(maxWidth: .infinity)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(Capsule())
                                        }
                                        .disabled(total <= 0)

                                        // Pay on the bill
                                        Button {
                                            if !AppConfig.isDemoMode { ZCreditPaymentHandler.shared.cancelCurrent() }
                                            isSplitMode = false
                                            splitParts.removeAll()
                                            activeSplitIndex = nil
                                            splitBaseTotal = nil
                                            onBillInput = ""
                                            payError = nil
                                            isPaying = false
                                            showOnBillPad = true
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "rectangle.split.2x1.fill")
                                                Text(isRtl ? "תשלום חלקי" : "Pay on the bill")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .frame(maxWidth: .infinity)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(Capsule())
                                        }
                                        .disabled(total <= 0)
                                    }

                                    HStack(spacing: 10) {
                                        // Student 10% discount
                                        Button { toggleStudentDiscount() } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "graduationcap.fill")
                                                    .font(.system(size: 16, weight: .semibold))
                                                Text(isRtl ? "הנחת סטודנט 10%" : "Student 10%")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity)
                                            .background(studentDiscountActive
                                                        ? Color.black.opacity(0.15)
                                                        : Color(.secondarySystemBackground))
                                            .foregroundColor(studentDiscountActive ? .black : .primary)
                                            .clipShape(Capsule())
                                        }
                                        .disabled(total <= 0 || isSplitMode || pricingLocked)

                                        // Tip
                                        Button {
                                            guard !isSplitMode else { return }
                                            showTipSheet = true
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "figure.surfing")
                                                    .font(.system(size: 17, weight: .semibold))
                                                Text(isRtl ? "טיפ" : "Tip")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity)
                                            .background(Color(.secondarySystemBackground))
                                            .foregroundColor(.primary)
                                            .clipShape(Capsule())
                                        }
                                        .disabled(total <= 0 || isSplitMode || pricingLocked)
                                    }
                                }

                            } else {
                                // iPad / big screens
                                HStack(spacing: 12) {

                                    Button { toggleSplitMode() } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 19, weight: .semibold))
                                            Text(isRtl ? "פיצול שווה" : "Split")
                                                .font(.system(size: 18, weight: .semibold))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                    }
                                    .disabled(total <= 0)

                                    Button {
                                        if !AppConfig.isDemoMode { ZCreditPaymentHandler.shared.cancelCurrent() }
                                        isSplitMode = false
                                        splitParts.removeAll()
                                        activeSplitIndex = nil
                                        splitBaseTotal = nil
                                        onBillInput = ""
                                        payError = nil
                                        isPaying = false
                                        showOnBillPad = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "rectangle.split.2x1.fill")
                                            Text(isRtl ? "תשלום חלקי" : "Pay on the bill")
                                                .font(.system(size: 18, weight: .semibold))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                    }
                                    .disabled(total <= 0)

                                    Button { toggleStudentDiscount() } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "graduationcap.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                            Text(isRtl ? "הנחת סטודנט 10%" : "Student 10%")
                                                .font(.system(size: 18, weight: .semibold))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(studentDiscountActive ? chipActiveBackground : chipBackground)
                                        .foregroundColor(chipForeground)
                                        .clipShape(Capsule())
                                    }
                                    .disabled(total <= 0 || isSplitMode || pricingLocked)

                                    Button {
                                        guard !isSplitMode else { return }
                                        showTipSheet = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "figure.surfing")
                                                .font(.system(size: 17, weight: .semibold))
                                            Text(isRtl ? "טיפ" : "Tip")
                                                .font(.system(size: 18, weight: .semibold))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.secondarySystemBackground))
                                        .foregroundColor(.primary)
                                        .clipShape(Capsule())
                                    }
                                    .disabled(total <= 0 || isSplitMode || pricingLocked)
                                }
                            }
                        }
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                    }

                    // Inline split panel
                    if isSplitMode {
                        splitPanel
                    }

                    // Main prompt
                    Text(isRtl ? "הכנס או הצמד כרטיס" : "Insert or tap card")
                        .font(kioskFont(24, weight: .bold))
                        .padding(.top, 8)

                    // Terminal indicator slot
                    Group {
                        if terminalActive {
                            TerminalActivityRing(
                                isActive: true,
                                label: isRtl ? "" : "Waiting for terminal…"
                            )
                            .padding(.top, 40)
                        } else {
                            Spacer().frame(height: 44)
                        }
                    }
                    .frame(height: 72)

                    // Error slot
                    Group {
                        if let payError, !payError.isEmpty {
                            VStack(spacing: 15) {
                                Text(isRtl ? "התשלום נכשל" : "Payment failed")
                                    .font(kioskFont(20, weight: .semibold))
                                    .multilineTextAlignment(.center)

                                if !cashPointMode {
                                    Button { retryZCreditNow() } label: {
                                        Text(isRtl ? "נסה שוב" : "Try again")
                                            .font(kioskFont(18, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 220, height: 48)
                                            .background(isPaying ? Color.gray.opacity(0.4) : MenuTheme.buttonBackground)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                    .disabled(isPaying)
                                }
                            }
                            .padding(.horizontal, 40)
                        } else {
                            Spacer().frame(height: 22)
                        }
                    }
                    .frame(height: cashPointMode ? errorSlotH : 90)
                    .frame(maxWidth: .infinity)

                    // Card / Cash / Pay later (POS)
                    if cashPointMode {
                        VStack(spacing: 12) {

                            if shouldShowCardButton {
                                Button {
                                   
                                    startCardForRemainingNow()
                                } label: {
                                    Text(isRtl ? "תשלום באשראי" : "Pay by card")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 240, height: 50)
                                        .background(terminalActive ? Color.gray.opacity(0.4) : Color.gray.opacity(0.4))
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                }
                                .disabled(terminalActive || (hasApprovedCardPayment && isOrderFullyPaid))
                            }

                            Button {
                                ensureTicketNow(reason: "CASH")
                                pLog(.uiTap, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "CASH")
                                pLog(.uiBlocked, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "CANCEL_TERM") // optional
                               
                                payingWithCash = true
                                payError = nil
                                isPaying = false
                                paymentStarted = false
                                cashInput = ""
                                manualCashTargetAmount = nil
                                if !AppConfig.isDemoMode { ZCreditPaymentHandler.shared.cancelCurrent() }
                            } label: {
                                Text(isRtl ? "תשלום במזומן" : "Pay with cash")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(width: 220, height: 48)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            }

                            if allowPayLater {
                                Button { submitPayLaterNow() } label: {
                                    Text(isRtl ? "תשלום מאוחר יותר" : "Pay later")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 220, height: 44)
                                }
                                .disabled(didSubmitThisFlow || isSubmittingNow)
                                .padding(.bottom, isSmallPhone ? 14 : 0) // ✅ extra breathing room on iPhone 8ֿ
                                .padding(.top, isSmallPhone ? 0 : 70)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, isSmallPhone ? 18 : 80)     // ✅ push up on iPhone 8
                .padding(.bottom, isSmallPhone ? 26 : 24)  // ✅ ensures Pay later can scroll into view
                .frame(minHeight: geo.size.height - 20, alignment: .center) // ✅ center on big screens
            }
        }
    }

    // MARK: - Split sheet (rows)

    private var splitSheetView: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(isRtl ? "פיצול הזמנה" : "Split payment")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 8)

                Text(String(format: "\(currency)%.2f", total))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)

                Divider().padding(.top, 4)

                VStack(spacing: 16) {
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                isSplitMode = false
                                splitParts.removeAll()
                                activeSplitIndex = nil
                                splitBaseTotal = nil
                                recomputeRemainingFromTotals()
                            }
                            showSplitSheet = false
                        } label: {
                            Text(isRtl ? "ביטול פיצול" : "Cancel split")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }

                        Spacer()
                    }

                    VStack(spacing: 12) {
                        ForEach(splitParts.indices, id: \.self) { idx in
                            let part = splitParts[idx]
                            let amount = Double(part.amount)

                            HStack {
                                // Amount + tap to change
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isRtl ? "תשלום \(idx + 1)" : "Payment \(idx + 1)")
                                        .font(.system(size: 16, weight: .medium))

                                    Button {
                                        splitAmountPadIndex = idx
                                        splitAmountInput = String(part.amount)
                                        showSplitAmountPad = true
                                    } label: {
                                        Text(String(format: "\(currency)%.2f", amount))
                                            .font(.system(size: 26, weight: .bold))
                                            .foregroundColor(.primary)
                                            .frame(minWidth: 120, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer()

                                if part.isPaid {
                                    Text(isRtl ? "שולם" : "Paid")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                } else {
                                    // Card
                                    Button {
                                        if !AppConfig.isDemoMode {
                                            ZCreditPaymentHandler.shared.cancelCurrent()
                                        }
                                        activeSplitIndex = idx
                                        payError = nil

                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                            startCardForSplitPart(index: idx)
                                        }
                                    } label: {
                                        Text(isRtl ? "אשראי" : "Card")
                                            .font(.system(size: 16, weight: .semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                  
                                    // Cash
                                    Button {
                                        if !AppConfig.isDemoMode {
                                            ZCreditPaymentHandler.shared.cancelCurrent()
                                        }
                                        activeSplitIndex = idx
                                        cashInput = ""
                                        payError = nil
                                        manualCashTargetAmount = nil
                                        payingWithCash = true
                                    } label: {
                                        Text(isRtl ? "מזומן" : "Cash")
                                            .font(.system(size: 16, weight: .semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .opacity(part.isPaid ? 0.6 : 1.0)
                        }
                    }

                    // Add another equal split
                    Button {
                        splitCount += 1
                        splitParts = buildSplitParts()
                       
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text(isRtl ? "הוסף חלק" : "Add split")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)

                Spacer()

                VStack(spacing: 12) {
                    // 1️⃣ Pay-on-the-bill cash (manual amount)
                    if let manual = manualCashTargetAmount {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", manual))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                    // 2️⃣ Split mode
                    else if isSplitMode {
                        VStack(spacing: 4) {
                            Text(isRtl ? "יתרה לתשלום" : "Remaining to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", max(remainingToPay, 0)))
                                .font(.system(size: 24, weight: .heavy))
                        }

                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום בתשלום זה" : "Amount for this payment")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    // 3️⃣ Normal full-order cash
                    else {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRtl ? "סגור" : "Close") {
                        showSplitSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Split helpers

    private func buildSplitParts() -> [SplitPart] {
        // ✅ Prefer locked base when split was started (prevents drift)
        let baseTotal = splitBaseTotal ?? ((remainingToPay > 0.1) ? remainingToPay : initialPaymentTarget)
        let total = round2(max(baseTotal, 0))

        guard splitCount > 0, total > 0.1 else { return [] }

        let even = round2(total / Double(splitCount))

        var parts: [SplitPart] = []
        parts.reserveCapacity(splitCount)

        var acc: Double = 0

        for idx in 0..<splitCount {
            let isLast = (idx == splitCount - 1)
            let amt = isLast ? round2(total - acc) : even
            acc = round2(acc + amt)
            parts.append(.init(id: idx, amount: max(0, amt), isPaid: false))
        }

        // ✅ exact sum safety
        let diff = round2(total - parts.map(\.amount).reduce(0, +))
        if abs(diff) >= 0.01, let last = parts.indices.last {
            parts[last].amount = round2(max(0, parts[last].amount + diff))
        }

        return parts
    }

    private func ensureSplitParts() {
        if splitParts.isEmpty {
            splitParts = buildSplitParts()
            recomputeRemainingFromTotals()
        }
    }
    
    private func markPartPaid(_ index: Int) {
        guard splitParts.indices.contains(index) else { return }
        guard !splitParts[index].isPaid else { return }

        splitParts[index].isPaid = true

        remainingToPay = round2(
            splitParts.filter { !$0.isPaid }
                      .map { $0.amount }
                      .reduce(0, +)
        )
    }
    
    
    private struct TipSheetView: View {
        let isRtl: Bool
        let currency: String
        let baseAmount: Double      // baseToCharge
        @Binding var tipPercent: Double?
        @Binding var tipFixedAmount: Double?
        @Binding var isPresented: Bool
        @Environment(\.colorScheme) private var colorScheme
        @State private var modeIsPercent: Bool = true
        @State private var input: String = ""

        // 💰 Computed tip amount from input
        private var currentTipAmount: Double {
            if modeIsPercent {
                let p = Double(input.filter(\.isNumber)) ?? (tipPercent ?? 0)
                let v = baseAmount * (p / 100.0)
                return max(0, (v * 100).rounded() / 100.0)
            } else {
                let raw = input.replacingOccurrences(of: ",", with: ".")
                return max(0, Double(raw) ?? (tipFixedAmount ?? 0))
            }
        }

        // 👁‍🗨 Text shown in the big “input box” above the keypad
        private var displayInputText: String {
            if modeIsPercent {
                let digits = input.filter(\.isNumber)
                if !digits.isEmpty {
                    return "\(digits)%"
                }
                if let p = tipPercent, p > 0 {
                    return "\(Int(p.rounded()))%"
                }
                return "0%"
            } else {
                if !input.isEmpty {
                    let raw = input.replacingOccurrences(of: ",", with: ".")
                    let val = Double(raw) ?? 0
                    return String(format: "\(currency)%.0f", val)
                }
                if let a = tipFixedAmount, a > 0 {
                    return String(format: "\(currency)%.0f", a)
                }
                return String(format: "\(currency)%.0f", 0)
            }
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    VStack(spacing: 0) {
                        // 🔺 Top close button like cash view
                        HStack {
                            if isRtl { Spacer() }

                            Button {
                                isPresented = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .bold))
                                    .padding(10)
                                    .background(Color(.systemGray5))
                                    .clipShape(Circle())
                            }

                            if !isRtl { Spacer() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        Spacer()

                        let maxWidth: CGFloat = 260

                        // 🔹 Center block – same spirit as cashFullScreen
                        VStack(spacing: 18) {
                            // Title
                            Text(isRtl ? "טיפ" : "Add a tip")
                                .font(.system(size: 24, weight: .bold))
                                .multilineTextAlignment(.center)

                            // Base amount line
                            Text(
                                String(
                                    format: isRtl
                                        ? "סכום ללא טיפ: \(currency)%.2f"
                                        : "Base amount: \(currency)%.2f",
                                    baseAmount
                                )
                            )
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                            // Quick % buttons (same width as keypad)
                            HStack(spacing: 8) {
                                ForEach([10, 12, 15, 20], id: \.self) { p in
                                    Button {
                                        modeIsPercent = true
                                        input = "\(p)"
                                    } label: {
                                        Text("\(p)%")
                                            .font(.system(size: 16, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                modeIsPercent && input == "\(p)"
                                                ? Color.black
                                                : Color(.secondarySystemBackground)
                                            )
                                            .foregroundColor(
                                                modeIsPercent && input == "\(p)" ? .white : .primary
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: maxWidth)

                            // Percent / Amount picker
                            Picker("", selection: $modeIsPercent) {
                                Text(isRtl ? "אחוז" : "Percent").tag(true)
                                Text(isRtl ? "סכום" : "Amount").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: maxWidth)

                            // Current tip label + box
                            VStack(spacing: 6) {
                                Text(isRtl ? "טיפ נוכחי" : "Current tip")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)

                                // Text "box" like the cash amount field
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.secondarySystemBackground))

                                    Text(displayInputText)
                                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                .frame(width: maxWidth, height: 52)

                                // And numeric calculated tip amount under it
                                Text(
                                    String(
                                        format: isRtl
                                            ? "שווי טיפ: \(currency)%.2f"
                                            : "Tip value: \(currency)%.2f",
                                        currentTipAmount
                                    )
                                )
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            }

                            // Keypad
                            tipKeypad
                                .frame(width: maxWidth)

                            // Apply button – same width as keypad
                            Button {
                                if modeIsPercent {
                                    let p = Double(input.filter(\.isNumber)) ?? 0
                                    tipPercent = p > 0 ? p : nil
                                    tipFixedAmount = nil
                                } else {
                                    let raw = input.replacingOccurrences(of: ",", with: ".")
                                    let a = Double(raw) ?? 0
                                    tipFixedAmount = a > 0 ? a : nil
                                    tipPercent = nil
                                }
                                isPresented = false
                            } label: {
                                Text(isRtl ? "הוסף טיפ" : "Apply tip")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(colorScheme == .dark ? .black : .white)
                                    .frame(width: 260)
                                    .frame(height: 50)
                                    .background(colorScheme == .dark ? .white : .black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .disabled(currentTipAmount <= 0)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                        Spacer()
                    }
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .onAppear {
                if let p = tipPercent, modeIsPercent {
                    input = p == 0 ? "" : String(Int(p.rounded()))
                } else if let a = tipFixedAmount, !modeIsPercent {
                    input = String(Int(a.rounded()))
                }
            }
        }

        // simple 0–9 / C / backspace keypad – same style as before
        private var tipKeypad: some View {
            // Rows arranged in the *opposite* horizontal direction
            // (3-2-1 / 6-5-4 / 9-8-7 / ⌫-0-C)
            let rows: [[String]] = [
                ["3", "2", "1"],
                ["6", "5", "4"],
                ["9", "8", "7"],
                ["⌫", "0", "C"]
            ]

            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

            return LazyVGrid(columns: cols, spacing: 10) {
                ForEach(rows, id: \.self) { row in
                    ForEach(row, id: \.self) { key in
                        Button {
                            tapKey(key)
                        } label: {
                            Text(key)
                                .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                                .frame(width: 80, height: 64)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }
        private func tapKey(_ key: String) {
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                guard key.allSatisfy(\.isNumber) else { return }
                if input.count < 4 { // up to 9999
                    input.append(contentsOf: key)
                }
            }
        }
    }

    /// Two-row style amount application (for now).
    private func applySplitAmount(newValue: String, index: Int) {
        // ✅ total (includes tip) — keep 2dp
        let total = round2(max(splitBaseTotal ?? initialPaymentTarget, 0))

        // ✅ digits only -> whole currency units (e.g. "37" -> 37.0)
        let filtered = newValue.filter(\.isNumber)
        let enteredInt = Int(filtered) ?? 0
        var entered = round2(Double(enteredInt))

        // ✅ clamp to [0, total]
        entered = min(max(entered, 0), total)

        guard splitParts.indices.contains(index) else { return }

        // ✅ ensure we have at least 2 parts (since this editor is "two-row style")
        if splitParts.count < 2 {
            splitParts = [
                SplitPart(id: 0, amount: round2(total / 2), isPaid: false),
                SplitPart(id: 1, amount: round2(total - round2(total / 2)), isPaid: false)
            ]
        }

        // ✅ keep paid rows untouched (don’t let edits break history)
        // If either of the first two rows is already paid, refuse edits silently
        // (you can show a haptic/alert if you want)
        if splitParts[0].isPaid || splitParts[1].isPaid {
            Haptics.error()
            return
        }

        if index == 0 {
            // user edits first -> second is remainder
            let first = entered
            let second = round2(max(total - first, 0))

            splitParts[0].amount = first
            splitParts[1].amount = second

        } else {
            // user edits second -> first is remainder
            let second = entered
            let first = round2(max(total - second, 0))

            splitParts[1].amount = second
            splitParts[0].amount = first
        }

        // ✅ recompute remaining based on unpaid parts (exact)
        remainingToPay = round2(
            splitParts
                .filter { !$0.isPaid }
                .map(\.amount)
                .reduce(0, +)
        )

        // ✅ if we’re currently targeting a split row, keep it consistent
        if let idx = activeSplitIndex, splitParts.indices.contains(idx) {
            // no-op, but this is a good place to add UI refresh logic if needed
        }
    }
    // MARK: - Pay on bill helpers

    private func payOnBillWithCard(
        amount: Double,
        onCompletion: ((_ approved: Bool) -> Void)? = nil
    ) {
        // ✅ kill any pending delayed restart
        cancelPendingRestart()

        let amt = round2(amount)
        guard amt >= 0.01 else { return }

        // ✅ prevent double starts
        guard !isPaying else { return }

        // ✅ ring is owned HERE (not by the caller)
        isPaying = true
        payError = nil
        lastResultWasUnknown = false

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.isPaying = false

                self.cardPaidTotal = self.round2(self.cardPaidTotal + amt)
                self.remainingToPay = self.round2(max(self.remainingToPay - amt, 0))
                self.hasApprovedCardPayment = (self.remainingToPay <= 0.1)

                onCompletion?(true)

                if self.remainingToPay <= 0.1 {
                    self.playSuccessAndCompleteOrder()
                } else {
                    self.commitPartialSnapshot()
                }
            }
            return
        }
        let t0 = Date()
        if ticketNow > 0 {
            pLog(.apiStartBegin,
                 ticket: ticketNow,
                 amount: amt,
                 reason: "payOnBillWithCard pay() begin")
        }
        ZCreditPaymentHandler.shared.pay(amount: amt, orderId: nil) { result in
            DispatchQueue.main.async {
                self.isPaying = false

                switch result.status {
                case .approved:
                    self.lastResultWasUnknown = false

                    self.cardPaidTotal = self.round2(self.cardPaidTotal + amt)
                    self.remainingToPay = self.round2(max(self.remainingToPay - amt, 0))
                    self.hasApprovedCardPayment = (self.remainingToPay <= 0.1)

                    onCompletion?(true)

                    if self.remainingToPay <= 0.1 {
                        self.playSuccessAndCompleteOrder()
                    } else {
                        self.commitPartialSnapshot()
                    }

                case .declined:
                    self.payError = self.isRtl
                        ? "התשלום נדחה. נסה שוב או בחר אמצעי תשלום אחר."
                        : "Payment was declined. Try again or choose another method."
                    onCompletion?(false)

                case .unknown:
                    self.payError = self.isRtl
                        ? "מצב העסקה לא ברור. בדוק את הטרמינל או בחר אמצעי תשלום אחר."
                        : "Payment status is unclear. Check the terminal or choose another method."
                    self.lastResultWasUnknown = true
                    onCompletion?(false)
                }
            }
        }
    }
    // MARK: - Success

    @MainActor
    private func playSuccessAndCompleteOrder() {
        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameClean  = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameParam  = nameClean.isEmpty ? nil : nameClean
        let summary    = buildPaymentSummary()

        // ✅ IMPORTANT: persist BEFORE submit so any printing that relies on AppStorage has the name
        if let n = nameParam { posSavedName = n }
        if let p = phoneParam { posSavedPhone = p.filter(\.isNumber) }

        // ✅ Do NOT clear AppStorage here (it can race printing). Only clear local UI inputs.
        name = ""
        phoneDigits = ""

        showSuccess = true
        successScale = 0.6
        successOpacity = 0

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.1)) {
            successScale = 1.0
            successOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                successOpacity = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showSuccess = false

                let discountOff: Double = studentDiscountActive
                    ? max(0, total - effectiveTotal)
                    : 0

                let tipOff = max(0, tipAmount)

                print("✅ SUCCESS → submitting. method=\(summary.method.rawValue) totalWithTip=\(totalWithTip)")
                clearPartialPaySnapshot()
                // 1) ✅ submit up to parent (parent can print / save metadata)
                onCompleted(phoneParam, nameParam, summary, discountOff, tipOff)

                // 2) ✅ Kiosk/customer: push to confirmation instead of dismiss
                if !cashPointMode {
                    goToConfirmationAfterSuccess()
                    return
                }

                // 3) ✅ POS/cashpoint: keep old behavior (dismiss after card/mixed)
                if summary.method != .cash && !didFinishThisFlow {
                    didFinishThisFlow = true
                    didInit = false

                    // ✅ Now it's safe to clear drafts (including AppStorage) because printing/submission already happened
                    clearDraftContact()
                    if ticketNow > 0 {
                        pLog(.flowFinish, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "onFinish()")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        
                        onFinish()
                    }
                }
            }
        }
    }

    // MARK: - Navigation / Cancel

    private func backStep() {
        // if we're deep in the nav stack, pop
        if !path.isEmpty {
            pop()
            return
        }

        // mini 13: no service step to go back to
        if isMini13 { return }

        // normal apps: return to service
        if root != .service {
            root = .service
        }
    }

    private func cancelAll() {
        ensureTicketNow(reason: "X")
           if ticketNow > 0 {
               pLog(.uiBlocked, ticket: ticketNow, amount: round2(currentTargetAmount), reason: "X")
           }
        if cashPointMode && hasAnyPayment && remainingToPay > 0.1 {
            persistPartialPaySnapshot()
        }
        didInit = false
        cancelPendingRestart()   // ✅ add

        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false
        cashInput = ""
        manualCashTargetAmount = nil

        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

     
        onCancel()
    }

    // MARK: - Phone & name steps (unchanged)

    // ... keep your existing `phoneStep`, `nameStep`, keypad helpers here ...

    // MARK: - Card / cash helpers

    private func cancelPayment() {
      
        cancelPendingRestart()   // ✅ add

        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false
        cashInput = ""
        manualCashTargetAmount = nil

        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        onCancel()
    }

    private func startPayment() {

        // ✅ Don’t start another generic charge if already paying
        guard !isPaying else { return }

        // ✅ Don’t auto-start while in cash / split / manual / specific split row flows
        guard !payingWithCash,
              !isSplitMode,
              manualCashTargetAmount == nil,
              activeSplitIndex == nil
        else { return }

        // ✅ HARD BLOCK: if any payment already happened and nothing is left, never start a new charge
        // (prevents 56 → discount → 50 double charge)
        if hasAnyPayment && remainingToPay <= 0.01 {
            return
        }

        isPaying = true
        payError = nil

        // ✅ single source of truth for the “base total” we want to collect (includes tip)
        let baseTotal = round2(initialPaymentTarget)

        // ✅ charge the true outstanding amount (never negative, never tiny)
        let outstanding = round2(remainingToPay > 0 ? remainingToPay : baseTotal)
        let amountToCharge = round2(max(0, outstanding))

        // guard against 0 / floating leftovers / accidental tiny charges
        guard amountToCharge >= 0.01 else {
            isPaying = false
            return
        }

        // ✅ helper to apply “approved” consistently (demo + real)
        @MainActor
        func applyApproved(amount: Double) {
            
            lastResultWasUnknown = false

            cardPaidTotal = round2(cardPaidTotal + amount)

            let newRemaining: Double
            if remainingToPay > 0 {
                newRemaining = remainingToPay - amount
            } else {
                newRemaining = baseTotal - amount
            }
            remainingToPay = round2(max(newRemaining, 0))

            hasApprovedCardPayment = (remainingToPay <= 0.1)

            if remainingToPay <= 0.1 {
                if ticketNow > 0 {
                    pLog(.orderComplete, ticket: ticketNow, amount: amount, status: "approved", reason: "rem=\(round2(remainingToPay))")
                }
                playSuccessAndCompleteOrder()
            } else {
                // ✅ partial card payment approved → submit snapshot (no reset)
                commitPartialSnapshot()
            }
        }

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    self.isPaying = false
                    applyApproved(amount: amountToCharge)
                }
            }
            return
        }
        let t0 = Date()
        if ticketNow > 0 {
            pLog(.apiStartBegin,
                 ticket: ticketNow,
                 amount: amountToCharge,
                 reason: "startPayment pay() begin")
        }
        ZCreditPaymentHandler.shared.pay(amount: amountToCharge, orderId: nil) { result in
            Task { @MainActor in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                      if self.ticketNow > 0 {
                          self.pLog(.apiStartDone,
                                    ticket: self.ticketNow,
                                    amount: amountToCharge,
                                    status: "\(result.status)",
                                    ms: ms,
                                    reason: result.message)
                      }

                self.isPaying = false

                switch result.status {
                case .approved:
                    if self.ticketNow > 0 {
                           self.pLog(.resultApproved, ticket: self.ticketNow, amount: amountToCharge, status: "approved")
                       }
                    applyApproved(amount: amountToCharge)

                case .declined:
                    if self.ticketNow > 0 {
                            self.pLog(.resultDeclined, ticket: self.ticketNow, amount: amountToCharge, status: "declined", reason: result.message)
                        }
                    let fallback = self.isRtl
                        ? "התשלום נדחה. נסה שוב או בחר אמצעי תשלום אחר."
                        : "Payment declined. Please try again or choose another method."
                    self.payError = result.message.isEmpty ? fallback : result.message

                case .unknown:
                    if self.ticketNow > 0 {
                           self.pLog(.resultUnknown, ticket: self.ticketNow, amount: amountToCharge, status: "unknown", reason: result.message)
                       }
                    let fallback = self.isRtl
                        ? "מצב העסקה לא ברור — בדוק במסוף. אם מופיע Approved, סמן תשלום ידנית או השתמש ב'תשלום מאוחר יותר'."
                        : "Payment status is unclear — check the terminal. If it shows Approved, mark it manually or use Pay later."
                    self.payError = result.message.isEmpty ? fallback : result.message
                    self.lastResultWasUnknown = true
                }
            }
        }
    }
    private func cancelPendingRestart() {
        restartWork?.cancel()
        restartWork = nil
    }

    private func completeWithoutPayment() {
           if !AppConfig.isDemoMode {
               ZCreditPaymentHandler.shared.cancelCurrent()
           }
           isPaying = false
           payError = nil
           paymentStarted = false
           payingWithCash = false
           cashInput = ""
           manualCashTargetAmount = nil

           // no money taken
           cardPaidTotal = 0
           cashPaidTotal = 0

           playSuccessAndCompleteOrder()
       }
    
    
    private struct TerminalProgressRing: View {
        var label: String = ""

        @State private var spin: Double = 0
        @State private var pulse: CGFloat = 1.0

        var body: some View {
            ZStack {
                // soft dim behind ring only (doesn't affect layout)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .blur(radius: 0.2)

                VStack(spacing: 14) {
                    ZStack {
                        // outer faint track
                        Circle()
                            .stroke(Color.black.opacity(0.08), lineWidth: 10)
                            .frame(width: 120, height: 120)

                        // spinning arc
                        Circle()
                            .trim(from: 0.08, to: 0.72)
                            .stroke(Color.black, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(spin))

                        // inner pulse
                        Circle()
                            .fill(Color.black.opacity(0.10))
                            .frame(width: 70, height: 70)
                            .scaleEffect(pulse)

                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.black)
                    }

                
                    Text("אל תסגור את המסך")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black.opacity(0.55))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
            .frame(width: 260, height: 240)
            .scaleEffect(0.98)
            .onAppear {
                // smooth endless spin
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spin = 360
                }
                // gentle pulse
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = 1.08
                }
            }
        }
    }
    @MainActor
    private func completeWithCash() {
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        // Common UI reset (but DO NOT dismiss screens here)
        isPaying = false
        payError = nil
        paymentStarted = false

        // 💰 How much cash did we just take in THIS action?
        let thisCash: Double

        if let manual = manualCashTargetAmount {
            // Manual "Pay on the bill" amount
            thisCash = manual

        } else if isSplitMode,
                  let idx = activeSplitIndex,
                  splitParts.indices.contains(idx) {
            // Cash for a specific split row
            thisCash = Double(splitParts[idx].amount)

        } else {
            // Normal cash: cashier types cash received, but we apply at most what is due
            let target = round2(remainingToPay > 0 ? remainingToPay : initialPaymentTarget)
            let entered = cashAmount
            thisCash = (entered > 0) ? min(entered, target) : target
        }

        cashPaidTotal = round2(cashPaidTotal + thisCash)


        // 1️⃣ Manual partial cash
        if let manual = manualCashTargetAmount {
            remainingToPay = round2(max(remainingToPay - thisCash, 0))
            manualCashTargetAmount = nil
            activeSplitIndex = nil

            if remainingToPay <= 0 {
                playSuccessAndCompleteOrder()
            }
            return
        }

        // 2️⃣ Split-mode cash (one split part)
        if isSplitMode, let idx = activeSplitIndex {
            markPartPaid(idx)
            activeSplitIndex = nil
            manualCashTargetAmount = nil

            if remainingToPay <= 0 {
                playSuccessAndCompleteOrder()
            }
            return
        }

        // 3️⃣ Simple non-split cash (may be partial)
        if remainingToPay == 0 {
            recomputeRemainingFromTotals()
        }

        remainingToPay = max(remainingToPay - thisCash, 0)

        if remainingToPay <= 0 {
            playSuccessAndCompleteOrder()
        }
    }

    // MARK: - Cash full-screen

    private var cashFullScreen: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    if isRtl { Spacer() }

                    Button {
                            // allow closing ONLY before "Paid"
                            guard !cashPaid else { return }

                            payingWithCash = false
                            cashInput = ""
                            payError = nil
                            manualCashTargetAmount = nil
                            billSum = 0
                            cashPaid = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .padding(10)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(cashPaid ? 0 : 1)          // ✅ hide after Paid
                        .disabled(cashPaid)                 // ✅ block taps after Paid
                        .allowsHitTesting(!cashPaid)

                    if !isRtl { Spacer() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                // TOP: amount / remaining info
                VStack(spacing: 12) {
                    // 1️⃣ Manual "Pay on the bill" cash – ALWAYS show the selected amount
                    if let manual = manualCashTargetAmount {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", manual))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                    // 2️⃣ Split mode
                    else if isSplitMode {
                        VStack(spacing: 4) {
                            Text(isRtl ? "יתרה לתשלום" : "Remaining to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", max(remainingToPay, 0)))
                                .font(.system(size: 24, weight: .heavy))
                        }

                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום בתשלום זה" : "Amount for this payment")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    // 3️⃣ Normal full-order cash
                    else {
                        let amountToPay = remainingToPay > 0 ? remainingToPay : initialPaymentTarget

                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", amountToPay))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                }

                if !cashPaid {
                    // 🔹 Row of bill images (20 / 50 / 100 / 200)
                    billButtonsRow
                        .padding(.top, 4)

                    // 🧮 BEFORE "שולם" – show input + keypad, NO change yet
                    Text(isRtl ? "כמה מזומן התקבל?" : "Cash received")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 4)

                    cashAmountDisplay
                    cashKeypad
                        .environment(\.layoutDirection, .leftToRight)

                    // 🔹 NEW: swipe-to-send order bar
                   

                } else {
                    // 💸 AFTER "שולם" – hide keypad, show big change only
                    VStack(spacing: 12) {
                        Text(isRtl ? "עודף ללקוח" : "Change to return")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.secondary)

                        Text(String(format: "\(currency)%.2f", changeAmount))
                            .font(.system(size: 54, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                    }
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale))
                }

                // BUTTON AREA
                if !cashPaid {
                    // 🔹 Exact-amount button
                    Button {
                        // ✅ open drawer
                        if cashPointMode {
                            PrinterManager.shared.openCashDrawer()
                        }

                        // ✅ exact cash received = due
                        let dueNow = round2(cashDueNow)
                        let received = dueNow
                        let applied = dueNow

                        // ✅ freeze for change display correctness (even if you won't show it)
                        lastCashDueAtPay = dueNow
                        lastCashReceivedAtPay = received

                        // optional: little success pulse
                        playCashSuccessOnly()

                        // ✅ run the REAL cash submit path (this triggers onCompleted internally when fully paid)
                        let fullyPaid = submitCashNow(appliedCash: applied)

                        if fullyPaid {
                            // you can skip showing the "change" UI entirely and just exit like "סיים"
                            cashPaid = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                // ✅ close cash full screen cover
                                payingWithCash = false

                                // ✅ same as "סיים"
                                clearDraftContact()
                                didInit = false
                                onFinish()
                            }
                        } else {
                            // partial (shouldn't happen for exact) — fall back to your existing behavior
                            cashPaid = false
                            cashInput = ""
                            justUsedBills = false
                            billSum = 0

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                payingWithCash = false
                            }
                        }
                    } label: {
                        Text(isRtl ? "שולם בדיוק" : "Exact amount")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 300)
                    .padding(.top, 8)
                   
                    // 🔘 "Paid" button
                    Button {
                        PrinterManager.shared.openCashDrawer()

                        let dueNow   = round2(cashDueNow)
                        let received = round2(cashAmount)
                        let applied  = min(received, dueNow)

                        // ✅ freeze for correct change display
                        lastCashDueAtPay = dueNow
                        lastCashReceivedAtPay = received

                        playCashSuccessOnly()

                        let fullyPaid = submitCashNow(appliedCash: applied)

                        if fullyPaid {
                            cashPaid = true   // ✅ now changeAmount uses frozen values
                        } else {
                            // partial cash → go back to charge
                            cashPaid = false
                            cashInput = ""
                            justUsedBills = false
                            billSum = 0

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                payingWithCash = false
                            }
                        }
                    } label: {
                        Text(isRtl ? "שולם" : "Paid")
                            .font(.system(size: 18, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                isCashEnough
                                ? Color.primary
                                : Color.gray.opacity(0.4)
                            )
                            .foregroundColor(
                                isCashEnough
                                ? Color(UIColor.systemBackground)
                                : Color(UIColor.systemBackground).opacity(0.9)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!isCashEnough || isSubmittingNow)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 300)
                    .padding(.top, 8)
                 

                } else {
                    // ✅ AFTER PAID – show two buttons: Print invoice + Finish
                    HStack(spacing: 12) {
                      

                        Button {
                            clearDraftContact()
                            didInit = false

                            onFinish()
                        } label: {
                            Text(isRtl ? "סיים" : "Finish")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(colorScheme == .dark ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(colorScheme == .dark ? .white : .black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 420)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                }

                Spacer()
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    // MARK: - Pay on the bill pad (no iPhone keyboard)

    private struct OnBillPadView: View {
        let isRtl: Bool
        let currency: String
        let currentRemaining: Double
        @Binding var input: String
        let onCard: (Double) -> Void
        let onCash: (Double) -> Void
        let onCancel: () -> Void
        @Binding var isPaying: Bool
        let ringLabel: String
        @Environment(\.colorScheme) private var colorScheme
        
        private var amount: Double {
            let raw = input.filter(\.isNumber)
            let value = Double(raw) ?? 0
            return min(max(value, 0), currentRemaining)
        }

        private let padWidth: CGFloat = 260

        // ✅ Spinner anti-glitch
        @State private var showOverlay = false
        @State private var overlayShownAt: Date? = nil
        @State private var delayedShowWork: DispatchWorkItem? = nil

        var body: some View {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                // TOP BAR
                VStack {
                    HStack {
                        if isRtl { Spacer() }

                        Button {
                            guard !isPaying else { return }
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .padding(10)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(isPaying ? 0.55 : 1)

                        if !isRtl { Spacer() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 35)

                    Spacer()
                }
                .ignoresSafeArea()

                // CENTERED CONTENT
                VStack(spacing: 15) {
                    Text(isRtl ? "תשלום לפי סכום" : "Pay on the bill")
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text(
                        String(
                            format: isRtl
                            ? "יתרה לתשלום: \(currency)%.2f"
                            : "Remaining to pay: \(currency)%.2f",
                            currentRemaining
                        )
                    )
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)

                    // Amount box
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))

                        Text(amount == 0 ? "0" : String(Int(amount)))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .frame(width: padWidth, height: 52)

                    // Keypad
                    keypad
                        .frame(width: padWidth)
                        .opacity(isPaying ? 0.6 : 1)
                        .allowsHitTesting(!isPaying)

                    // Card / Cash buttons
                    HStack(spacing: 12) {
                        Button {
                            guard !isPaying else { return }
                            onCard(amount)
                        } label: {
                            Text(isRtl ? "כרטיס" : "Card")
                                .font(.system(size: 18, weight: .semibold))
                                
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    amount > 0
                                    ? (colorScheme == .dark ? Color.white : Color.black)
                                    : Color.gray.opacity(0.4)
                                )
                                .foregroundColor(
                                    amount > 0
                                    ? (colorScheme == .dark ? Color.black : Color.white)
                                    : Color.white.opacity(0.9)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(amount <= 0 || isPaying)

                        Button {
                            guard !isPaying else { return }
                            onCash(amount)
                        } label: {
                            Text(isRtl ? "מזומן" : "Cash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(amount <= 0 || isPaying)
                    }
                    .frame(width: padWidth)
                    .padding(.top, 10)
                    .opacity(isPaying ? 0.75 : 1)
                    .allowsHitTesting(!isPaying)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                // ✅ PROGRESS OVERLAY (debounced + minimum visible time)
                if showOverlay {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        TerminalProgressRing(label: ringLabel)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear { input = "" }
            
            .onChange(of: isPaying) { paying in
                delayedShowWork?.cancel()
                delayedShowWork = nil

                if paying {
                    // Wait a bit before showing ring (prevents “flash”)
                    let work = DispatchWorkItem {
                        if isPaying {
                            overlayShownAt = Date()
                            withAnimation(.easeInOut(duration: 0.12)) {
                                showOverlay = true
                            }
                        }
                    }
                    delayedShowWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)

                } else {
                    // If it appeared, keep it visible briefly so it doesn't blink
                    let minVisible: TimeInterval = 0.30
                    let shownFor = Date().timeIntervalSince(overlayShownAt ?? Date())
                    let delay = max(0, minVisible - shownFor)

                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            showOverlay = false
                        }
                        overlayShownAt = nil
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showOverlay)
        }

        // MARK: - Keypad
        private var keypad: some View {
            let rows: [[String]] = [
                ["3", "2", "1"],
                ["6", "5", "4"],
                ["9", "8", "7"],
                ["⌫", "0", "C"]
            ]
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

            return LazyVGrid(columns: cols, spacing: 10) {
                ForEach(rows, id: \.self) { row in
                    ForEach(row, id: \.self) { key in
                        Button { tapKey(key) } label: {
                            Text(key)
                                .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                                .frame(width: 80, height: 64)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(isPaying)
                    }
                }
            }
        }

        private func tapKey(_ key: String) {
            guard !isPaying else { return }
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                guard key.allSatisfy(\.isNumber) else { return }
                if input.count < 7 { input.append(contentsOf: key) }
            }
        }
    }

    // MARK: - Phone / Name steps

    private var phoneStep: some View {
        VStack(spacing: 24) {

            Text(isRtl ? "מה מספר הטלפון שלך?" : "What’s your phone number?")
                .font(kioskFont(26, weight: .bold))
                .multilineTextAlignment(.center)

            Text(isRtl ? "כדי שנעדכן אותך כשההזמנה מוכנה"
                       : "So we can notify you when your order is ready")
                .font(kioskFont(16, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            phoneDisplay

            phonePad
                .environment(\.layoutDirection, .leftToRight)

            VStack(spacing: 10) {

                // ✅ Next
                Button {
                    posSavedPhone = phoneDigits.filter(\.isNumber)
                    goToChargeFromPhone_push()
                } label: {
                    Text(isRtl ? "המשך לתשלום" : "Next")
                        .font(kioskFont(18, weight: .bold))
                        .foregroundColor(
                            phoneValid
                                ? (colorScheme == .dark ? .black : .white)
                                : .black
                        )
                        .frame(width: 300, height: 52)
                        .background(
                            phoneValid
                                ? (colorScheme == .dark ? .white : (cashPointMode ? .black : MenuTheme.buttonBackground))
                                : Color.gray.opacity(0.4)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!phoneValid)

                // ✅ Skip (exactly like nameStep: shows whenever cashPointMode)
                if cashPointMode {
                    Button {
                        // don't save phone, just continue
                        payError = nil
                        paymentStarted = false
                        goToChargeFromPhone_push()
                    } label: {
                        Text(isRtl ? "דלג" : "Skip")
                            .font(kioskFont(16, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 300, height: 44)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var phoneDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if formattedPhone.isEmpty {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 2, height: 24)
            } else {
                Text(formattedPhone)
                   // .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .font(kioskFont(22, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 300, height: 52)
    }

    private var phonePad: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(["1","2","3","4","5","6","7","8","9","","0","⌫"], id: \.self) { key in
                if key.isEmpty {
                    Color.clear.frame(height: 64)
                } else {
                    Button {
                        tapPhoneKey(key)
                    } label: {
                        Text(key)
                            .font(kioskFont(26, weight: .bold))
                            .frame(width: 80, height: 64)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .frame(width: 300)
    }

    private func tapPhoneKey(_ key: String) {
        if key == "⌫" {
            if !phoneDigits.isEmpty {
                phoneDigits.removeLast()
            }
        } else if key.count == 1, let c = key.first, c.isNumber {
            if phoneDigits.filter(\.isNumber).count < 10 {
                phoneDigits.append(c)
            }
        }
    }

    private var shouldShowCardButton: Bool {
        // Hide the card button only if we *already* have a full approved card
        // and nothing is left to pay.
        if hasApprovedCardPayment && remainingToPay <= 0 {
            return false
        }

        // In all other cases (initial state, after cancel/decline, partial cash, split, etc.)
        // show the card button so the waiter can try again.
        return true
    }
    
    private var phoneValid: Bool {
        let d = phoneDigits.filter(\.isNumber)
        return d.count == 10 && d.first == "0"
    }

    private func formatIL(_ raw: String) -> String {
        // Keep digits only, and clamp to 10 digits
        let d = String(raw.filter(\.isNumber).prefix(10))
        guard !d.isEmpty else { return "" }

        // 0XX
        if d.count <= 3 { return d }

        // 0XX-XXX
        if d.count <= 6 {
            let p1 = d.prefix(3)
            let p2 = d.dropFirst(3)
            return "\(p1)-\(p2)"
        }

        // 0XX-XXX-XXXX  ✅
        let p1 = d.prefix(3)
        let p2 = d.dropFirst(3).prefix(3)
        let p3 = d.dropFirst(6) // up to 4 digits (because we clamped to 10)
        return "\(p1)-\(p2)-\(p3)"
    }

    private var hasConfirmedPhoneForThisFlow: Bool {
        cashPointMode ? hasSavedPhone : false
    }
    
    @FocusState private var nameFocused: Bool
    
    
    // ✅ Name step with HE/AR toggle ONLY for miniAppId == 13
    private var nameStep: some View {
        // ✅ detect shop 13 (use MenuTheme.miniId as you do elsewhere)
        let isMini13 = (MenuTheme.miniId == 13)

        // ✅ IMPORTANT: fallback display uses saved value if local `name` is still empty
        let saved = posSavedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.isEmpty ? saved : cleanName
        let displayValid = displayName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2

        return VStack(spacing: 24) {
            Text(isRtl ? "מה השם שלך?" : "What’s your name?")
                .font(kioskFont(26, weight: .bold))
                .multilineTextAlignment(.center)

            Text(isRtl ? "נכתוב את זה על ההזמנה" : "We’ll put it on your order")
                .font(kioskFont(15, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // ✅ NEW: HE/AR toggle (only for mini 13)
            if isMini13 {
                HStack {
                    Spacer()

                    Button {
                        setNameKbMode(nameKbMode == .he ? .ar : .he)
                        Haptics.light()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 14, weight: .bold))

                            Text(nameKbMode == .he ? "HE" : "AR")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 300)
            }

            // ✅ DISPLAY BOX (NO TextField, NO system keyboard)
            HStack(spacing: 10) {
                Text(displayName.isEmpty ? (isRtl ? "" : "Enter name…") : displayName)
                    .font(kioskFont(22, weight: .semibold))
                    .foregroundColor(displayName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)

                if !displayName.isEmpty {
                    Button {
                        print("✅ CLEAR tapped")
                        name = ""
                        posSavedName = ""
                        didConfirmNameThisSession = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 300, height: 52)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())

            // ✅ YOUR CUSTOM KEYBOARD ONLY
            nameKeyboard

            VStack(spacing: 10) {
                Button {
                    // ✅ persist the visible name (fallback-safe)
                    let final = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    posSavedName = final
                    name = final

                    didConfirmNameThisSession = true
                    goToChargeFromName_push()
                } label: {
                    Text(isRtl ? "המשך" : "Continue to payment")
                        .font(kioskFont(18, weight: .bold))
                        .frame(width: 300, height: 52)
                        .background(displayValid ? Color.primary : Color.gray.opacity(0.4))
                        .foregroundColor(
                            displayValid
                            ? Color(UIColor.systemBackground)
                            : Color(UIColor.systemBackground).opacity(0.9)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!displayValid)

                // (keep your skip disabled)
                if cashPointMode && 1 == 2 {
                    Button {
                        didConfirmNameThisSession = false
                        push(requiresPhoneStep ? .phone : .charge)
                        paymentStarted = false
                        payError = nil
                    } label: {
                        Text(isRtl ? "דלג" : "Skip")
                            .font(kioskFont(16, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 300, height: 44)
                    }
                }
            }
        }
        .onAppear {
            // ✅ sync local state once so keyboard edits continue naturally
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !posSavedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = posSavedName
            }
        }
    }
  

    private var nameKeyboard: some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone

        let phoneMaxWidth: CGFloat = UIScreen.main.bounds.width - 40
        let iPadMaxWidth: CGFloat = 600
        let maxWidth = isPhone ? phoneMaxWidth : iPadMaxWidth

        let rows: [[String]] = {
            if isMini13 {
                return (nameKbMode == .ar) ? arabicRowsWide : hebrewRowsWide
            } else {
                return hebrewRowsWide
            }
        }()

        return VStack(spacing: isPhone ? 10 : 12) {
            ForEach(rows.indices, id: \.self) { idx in
                let row = rows[idx]
                HStack(spacing: isPhone ? 6 : 10) {

                    // ✅ RTL: render row reversed so delete ends up on LEFT visually
                    let visualKeys = isRtl ? Array(row.reversed()) : Array(row.reversed())

                    ForEach(visualKeys, id: \.self) { key in
                        Button {
                            tapNameKey(key)
                        } label: {
                            Text(keyLabel(key))
                                .font(
                                    kioskFont(
                                        isPhone
                                        ? (key == "⌫" ? 18 : 20)
                                        : (key == "⌫" ? 22 : 22),
                                        weight: .semibold
                                    )
                                )
                                .frame(
                                    width: keyWidth(for: key, row: row, maxWidth: maxWidth, isPhone: isPhone),
                                    height: isPhone ? 50 : 58
                                )
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(
                                    cornerRadius: isPhone ? 10 : 12,
                                    style: .continuous
                                ))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, isPhone ? 12 : 20)
        .environment(\.layoutDirection, .rightToLeft) // ✅ lock layout so SwiftUI won’t mirror it
    }

    private func keyWidth(for key: String,
                          row: [String],
                          maxWidth: CGFloat,
                          isPhone: Bool) -> CGFloat {
        if key == "Space" || key == "רווח" {
            return isPhone ? maxWidth * 0.60 : maxWidth * 0.55
        }
        if key == "⌫" {
            return isPhone ? maxWidth * 0.15 : maxWidth * 0.18
        }
        let count = row.count
        let spacing = CGFloat((count - 1) * (isPhone ? 6 : 10))
        return (maxWidth - spacing) / CGFloat(count)
    }

    private var hebrewRowsWide: [[String]] {
        [
            // Row 1 – like iOS: ק ר א ט ו ן ם פ + delete
            ["ק","ר","א","ט","ו","ן","ם","פ","⌫"],

            // Row 2 – ends with ך ף
            ["ש","ד","ג","כ","ע","י","ח","ל","ך","ף"],

            // Row 3 – add apostrophe "'" at the end
            ["ז","ס","ב","ה","נ","מ","צ","ת","'"],

            // Space row
            ["רווח"]
        ]
    }
    
    private var latinRowsWide: [[String]] {
        [
            // Row 1: QWERTYUIOP
            ["Q","W","E","R","T","Y","U","I","O","P"],

            // Row 2: ASDFGHJKL
            ["A","S","D","F","G","H","J","K","L"],

            // Row 3: ZXCVBNM + delete at the end (like iPhone/iPad)
            ["Z","X","C","V","B","N","M","⌫"],

            // Space row
            ["Space"]
        ]
    }

    private func keyLabel(_ key: String) -> String {
        switch key {
        case "Space": return "Space"
        case "רווח": return "רווח"
        case "⌫":    return "⌫"
        default:     return key
        }
    }

    private func tapNameKey(_ key: String) {
        if cleanName.isEmpty { name = "" }

        switch key {
        case "⌫":
            if !name.isEmpty { name.removeLast() }

        case "Space", "רווח", "مسافة":
            if !name.hasSuffix(" ") { name.append(" ") }

        default:
            if name.count < 32 { name.append(key) }
        }

        posSavedName = cleanName
    }

    // MARK: - Cash UI pieces

    private var cashAmountDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if cashInput.isEmpty {
                Text(isRtl ? "0" : "0")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(String(format: "\(currency)%.2f", cashAmount))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 260, height: 52)
    }

    private var cashKeypad: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        let keys = ["1","2","3","4","5","6","7","8","9","C","0","⌫"]

        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(keys, id: \.self) { key in
                Button {
                    tapCashKey(key)
                } label: {
                    Text(key)
                        .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                        .frame(width: 80, height: 64)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .frame(width: 260)
        .padding(.top, 8)
    }

    private func tapCashKey(_ key: String) {
        switch key {
        case "C":
            cashInput = ""
            justUsedBills = false

        case "⌫":
            if !cashInput.isEmpty { cashInput.removeLast() }
            // If you delete everything, treat as no-bills state again
            if cashInput.isEmpty { justUsedBills = false }

        default:
            if key.allSatisfy(\.isNumber) {
                if justUsedBills {
                    // First digit after using bills → OVERRIDE the amount
                    cashInput = key
                    justUsedBills = false
                } else if cashInput.count < 7 {
                    cashInput.append(contentsOf: key)
                }
            }
        }
    }

    private func recomputeRemainingFromTotals() {
        // ✅ In split mode, remainingToPay is owned by splitParts math.
        if isSplitMode { return }

        let base = round2(initialPaymentTarget) // includes discount + tip
        let paid = round2(cardPaidTotal + cashPaidTotal)
        remainingToPay = round2(max(base - paid, 0))
    }
    // MARK: - Split card helper
    private func startCardForSplitPart(index: Int) {
        cancelPendingRestart()
        guard splitParts.indices.contains(index),
              !splitParts[index].isPaid else {
            splitCardTapLocked = false
            return
        }

        // ✅ integer split amount → round anyway for safety
        let amount = round2(splitParts[index].amount)
        guard amount >= 0.01 else {
            splitCardTapLocked = false
            return
        }

        guard !isPaying else {
            splitCardTapLocked = false
            return
        }

        // ✅ common helper (demo + real) — always on MainActor
        @MainActor
        func applyApprovedSplit(amount: Double) {
            lastResultWasUnknown = false

            // ✅ totals
            cardPaidTotal = round2(cardPaidTotal + amount)

            // ✅ mark split row as paid (recomputes remainingToPay)
            markPartPaid(index)

            // ✅ after recompute
            hasApprovedCardPayment = (remainingToPay <= 0.1)

            if remainingToPay <= 0.1 {
                playSuccessAndCompleteOrder()
            } else {
                // ✅ split part approved but order still has remaining → commit snapshot (no reset)
                commitPartialSnapshot()
            }
        }

        // Start payment UI state
        isPaying = true
        payError = nil

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    self.isPaying = false
                    self.splitCardTapLocked = false
                    applyApprovedSplit(amount: amount)   // ✅ no "self."
                }
            }
            return
        }
        let t0 = Date()
        if ticketNow > 0 {
            beginPayAttempt("SPLIT\(index+1)")
            pLog(.apiStartBegin,
                 ticket: ticketNow,
                 amount: amount,
                 reason: "split pay() begin idx=\(index)")
        }

        ZCreditPaymentHandler.shared.pay(amount: amount, orderId: nil) { result in
            Task { @MainActor in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if self.ticketNow > 0 {
                    self.pLog(.apiStartDone,
                              ticket: self.ticketNow,
                              amount: amount,
                              status: "\(result.status)",
                              ms: ms,
                              reason: result.message)
                }

                self.isPaying = false
                self.splitCardTapLocked = false

                switch result.status {
                case .approved:
                    if self.ticketNow > 0 {
                        self.pLog(.resultApproved,
                                  ticket: self.ticketNow,
                                  amount: amount,
                                  status: "approved")
                    }
                    applyApprovedSplit(amount: amount)

                case .declined:
                    if self.ticketNow > 0 {
                        self.pLog(.resultDeclined,
                                  ticket: self.ticketNow,
                                  amount: amount,
                                  status: "declined",
                                  reason: result.message)
                    }
                    let fallback = self.isRtl
                        ? "תשלום החלק נדחה. נסה שוב או בחר אמצעי תשלום אחר."
                        : "This part of the payment was declined. Try again or choose another method."
                    self.payError = result.message.isEmpty ? fallback : result.message

                case .unknown:
                    if self.ticketNow > 0 {
                        self.pLog(.resultUnknown,
                                  ticket: self.ticketNow,
                                  amount: amount,
                                  status: "unknown",
                                  reason: result.message)
                    }
                    let fallback = self.isRtl
                        ? "מצב העסקה לא ברור — בדוק במסוף. אם מופיע Approved, סמן את החלק הזה כשולם והמשך."
                        : "Status for this part is unclear — check the terminal. If it shows Approved, mark this part as paid and continue."
                    self.payError = result.message.isEmpty ? fallback : result.message
                    self.lastResultWasUnknown = true
                }
            }
        }
    }
    // MARK: - Split amount pad view

    private struct SplitAmountPadView: View {
        let isRtl: Bool
        let currency: String
        let title: String
        @Binding var input: String
        let onDone: (String) -> Void
        let onCancel: () -> Void

        private var displayValue: String {
            let filtered = input.filter(\.isNumber)
            return filtered.isEmpty ? "0" : filtered
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
                    HStack {
                        if isRtl { Spacer() }

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .padding(10)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }

                        if !isRtl { Spacer() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    Spacer()

                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text(currency)
                            .font(.system(size: 30, weight: .bold))
                        Text(displayValue)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                    }

                    keypad

                    Button {
                        onDone(input)
                    } label: {
                        Text(isRtl ? "אישור" : "Confirm")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 220, height: 52)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .padding(.top, 8)

                    Spacer()
                }
                .padding(.bottom, 20)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
        }

        private var keypad: some View {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
            let keys = ["1","2","3","4","5","6","7","8","9","C","0","⌫"]

            return LazyVGrid(columns: cols, spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        tapKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                            .frame(width: 80, height: 64)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(width: 280)
            .padding(.top, 8)
        }

        private func tapKey(_ key: String) {
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                if key.allSatisfy(\.isNumber) {
                    if input.count < 7 {
                        input.append(contentsOf: key)
                    }
                }
            }
        }
    }
    
    private var confirmationStep: some View {
        let qrURL = "https://minis.studio/shop/12"

        return VStack(spacing: 18) {
            Spacer()

            Text(isRtl ? "ההזמנה התקבלה" : "Order received")
                .font(kioskFont(28, weight: .bold))
                .multilineTextAlignment(.center)

            Text(isRtl ? "ההזמנה שלך בהכנה" : "Your order is being prepared")
                .font(kioskFont(26, weight: .semibold))
                .multilineTextAlignment(.center)
            
            Text("הרווחת חותמת אחת - כל קפה 10 עלינו.\nלשמירת החותמת בכרטיסיה סרוק את הקוד")
                .font(kioskFont(18))
                .multilineTextAlignment(.center)
                .lineSpacing(8)

            DotQRView(
                text: qrURL,
                overlayLabel: "MINI",
                logoKnockoutFraction: 0.28
            )
            .frame(width: 220, height: 220)

            Button {
                cancelConfirmationAutoReset()
                dismissFlowFromConfirmation()
            } label: {
                Text(isRtl ? "הזמנה חדשה" : "New order")
                    .font(kioskFont(20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 260, height: 54)
                    .background(cashPointMode ? .black : MenuTheme.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            Spacer()
        }
        .onAppear {
            scheduleConfirmationAutoReset()
        }
        .onDisappear {
            if cashPointMode && hasAnyPayment && remainingToPay > 0.1 {
                   persistPartialPaySnapshot()
               }
            cancelPendingRestart()   // ✅ add

            didInit = false
              clearDraftContact()
            cancelConfirmationAutoReset()
        }
    }
    private func scheduleConfirmationAutoReset() {
        cancelConfirmationAutoReset()

        confirmationAutoResetTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            await MainActor.run {
                dismissFlowFromConfirmation()
            }
        }
    }

    private func cancelConfirmationAutoReset() {
        confirmationAutoResetTask?.cancel()
        confirmationAutoResetTask = nil
    }
    private func dismissFlowFromConfirmation() {
        didInit = false
        clearDraftContact()
        cancelPendingRestart()   // ✅ add

        DispatchQueue.main.async {
            self.onFinish()
        }
    }
    private func goToConfirmationAfterSuccess() {
        // prevent double navigation
        if didFinishThisFlow { return }
        didFinishThisFlow = true

        // clean UI state
        isPaying = false
        paymentStarted = false
        payError = nil

        // ✅ navigate (root if we’re at root, push if we’re already in stack)
        if path.isEmpty {
            root = .confirmation
        } else {
            push(.confirmation)
        }
    }
    
    private func debugShowConfirmation() {
        // stop any payment UI
        isPaying = false
        paymentStarted = false

        // 🔧 DEBUG: call onCompleted as if order finished
        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameParam  = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name

        let summary = buildPaymentSummary()

        let discountOff: Double = studentDiscountActive
            ? max(0, total - effectiveTotal)
            : 0

        let tipOff = max(0, tipAmount)

            //  onCompleted(phoneParam, nameParam, summary, discountOff, tipOff)

        // clear error so UI is clean
        payError = nil

        // ✅ IMPORTANT: push confirmation (do NOT reset path)
        if path.isEmpty {
            root = .confirmation
        } else {
            push(.confirmation)
        }
    }
   
    
    // MARK: - Phone & name helpers (keep as in your current file)

    // NOTE: keep your existing `phoneStep`, `nameStep`, `phonePad`, `nameKeyboard`,
    // `formatIL`, etc. from your current OrderFlowView implementation.
}

extension String {
    var trimmedIsEmpty: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
