import SwiftUI
import CoreImage.CIFilterBuiltins
import Foundation

struct PrintLogsViewerSheet: View {

    // ✅ Optional: open already filtered
    let initialOrderId: Int?
    let titleOverride: String?

    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var events: [PrintEvent] = []
    @State private var payEvents: [PaymentEvent] = []
    @State private var copiedToast = false

    // ✅ WhatsApp number (no +)
    private let whatsappTo = "447522552608"

    // ✅ NEW: split share into 2 short messages
    private enum ShareTab: String, CaseIterable, Identifiable {
        case printers = "🖨️ מדפסות"
        case payments = "💳 תשלומים"
        var id: String { rawValue }
    }
    @State private var shareTab: ShareTab = .printers

    // MARK: - Init

    init(
        initialOrderId: Int? = nil,
        titleOverride: String? = nil
    ) {
        self.initialOrderId = initialOrderId
        self.titleOverride = titleOverride
        _query = State(initialValue: initialOrderId.map(String.init) ?? "")
    }

    // MARK: - Computed

    private var parsedOrderId: Int? {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Int(t.filter(\.isNumber))
    }

    private var headerTitle: String {
        titleOverride ?? "לוגים למדפסות"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {

                // 🔎 Search
                VStack(alignment: .trailing, spacing: 8) {
                    Text("חפש לפי מספר הזמנה / טיקט")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)

                        TextField("לדוגמה: 4663", text: $query)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: query) { _ in reload() }

                        if !query.isEmpty {
                            Button {
                                query = ""
                                events = []
                                payEvents = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // 📄 Results
                if let oid = parsedOrderId, (!events.isEmpty || !payEvents.isEmpty) {

                    // ✅ build 2 short messages
                    let printersText = makeShareTextPrinters(orderId: oid, events: events)
                    let paymentsText = makeShareTextPayments(orderId: oid, payEvents: payEvents)

                    let activeText = (shareTab == .printers) ? printersText : paymentsText
                    let wa = whatsappURL(text: activeText)

                    VStack(spacing: 10) {

                        // Header
                        HStack {
                            Text("הזמנה \(oid)")
                                .font(.system(size: 18, weight: .bold))
                            Spacer()

                            Button {
                                UIPasteboard.general.string = activeText
                                copiedToast = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    copiedToast = false
                                }
                                Haptics.light()
                            } label: {
                                Text("העתק")
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)

                        // ✅ choose which QR/message to send
                        Picker("", selection: $shareTab) {
                            ForEach(ShareTab.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)

                        // 📱 QR
                        VStack(spacing: 8) {
                            Text("סרקו לשליחה בוואטסאפ")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)

                            if let wa {
                                Image(uiImage: qrImage(from: wa.absoluteString) ?? UIImage())
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 220, height: 220) // ✅ a bit bigger, still safe
                                    .padding(10)
                                    .background(Color(.systemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }

                        Divider().padding(.top, 6)

                        ScrollView {
                            VStack(spacing: 10) {

                                // 💳 PAYMENTS
                                VStack(alignment: .trailing, spacing: 8) {
                                    Text("💳 PAYMENTS")
                                        .font(.system(size: 14, weight: .bold))

                                    if payEvents.isEmpty {
                                        Text("(no payment logs for this ticket)")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    } else {
                                        ForEach(payEvents.indices, id: \.self) { i in
                                            paymentRow(payEvents[i])
                                        }
                                    }
                                }

                                Divider().padding(.vertical, 6)

                                // 🖨️ PRINTERS
                                VStack(alignment: .trailing, spacing: 8) {
                                    Text("🖨️ PRINTERS")
                                        .font(.system(size: 14, weight: .bold))

                                    if events.isEmpty {
                                        Text("(no printer logs for this order)")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    } else {
                                        ForEach(events.indices, id: \.self) { i in
                                            logRow(events[i])
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }

                } else if parsedOrderId != nil {
                    Spacer()
                    Text("אין לוגים להזמנה הזו")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Spacer()
                    Text("הקלידו מספר הזמנה כדי לראות לוגים")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(8)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .top) {
                if copiedToast {
                    Text("הועתק ✅")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 6)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)   // ✅ HARD RTL
        .onAppear {
            if initialOrderId != nil { reload() }
        }
    }

    // MARK: - Helpers

    private func reload() {
        guard let oid = parsedOrderId else {
            events = []
            payEvents = []
            return
        }

        // ✅ Helpers
        func startOfTodayIL() -> TimeInterval {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
            return cal.startOfDay(for: Date()).timeIntervalSince1970
        }

        func filterTodayOrRecent(_ all: [PrintEvent]) -> [PrintEvent] {
            guard !all.isEmpty else { return [] }

            let todayStart = startOfTodayIL()
            let today = all.filter { $0.ts >= todayStart }
            if !today.isEmpty { return today }

            // fallback: last 12h (covers after-midnight / overnight)
            let cutoff = Date().addingTimeInterval(-12 * 60 * 60).timeIntervalSince1970
            let recent = all.filter { $0.ts >= cutoff }
            if !recent.isEmpty { return recent }

            // last resort: show everything
            return all
        }

        // ✅ 1) printers (orderId-based)
        let allPrinterEvents = PrintJournal.shared.read(orderId: oid)
        events = filterTodayOrRecent(allPrinterEvents)

        // ✅ 2) payments (ticket-based)
        // Try exact ticket first
        var pe = PaymentJournal.shared.read(ticket: oid)

        // If empty: find closest payment attempt near the best timestamp we have
        if pe.isEmpty {
            // Prefer last printer event time from the FILTERED list (today/recent),
            // otherwise fall back to last raw printer event, otherwise now.
            let refTs =
                events.last?.ts
                ?? allPrinterEvents.last?.ts
                ?? Date().timeIntervalSince1970

            let miniAppId = UserDefaults.standard.integer(forKey: "miniAppId")

            pe = PaymentJournal.shared.readClosestAttempt(
                nearTs: refTs,
                miniAppId: miniAppId,
                maxWindowSeconds: 10 * 60
            )
        }

        payEvents = pe
    }
    private func logRow(_ e: PrintEvent) -> some View {
        VStack(alignment: .trailing, spacing: 6) {

            HStack {
                Text(formatTime(e.ts))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if let ms = e.ms {
                    Text("\(ms)ms")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("\(e.type.rawValue)  \(e.station.uppercased())")
                .font(.system(size: 16, weight: .bold))

            Text("\(e.host):\(e.port)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            if let r = e.reason {
                Text(r)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func paymentRow(_ e: PaymentEvent) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Text(formatTime(e.ts))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if let ms = e.ms {
                    Text("\(ms)ms")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(e.type.rawValue)
                .font(.system(size: 16, weight: .bold))

            if let s = e.status, !s.isEmpty {
                Text("status: \(s)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            if let r = e.reason, !r.isEmpty {
                Text(r)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Share text (split to 2 short messages)

    private func makeShareHeader(orderId: Int) -> String {

        func cleanName(_ s: String?) -> String {
            (s ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "Customer", with: "")
        }

        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "HH:mm:ss"
        let nowTime = f.string(from: now)

        let deviceName = UIDevice.current.name
        let customerName: String = {
            let a = cleanName(UserDefaults.standard.string(forKey: "posSavedName"))
            if !a.isEmpty { return a }
            let b = cleanName(UserDefaults.standard.string(forKey: "posCustomerName"))
            if !b.isEmpty { return b }
            let c = cleanName(UserDefaults.standard.string(forKey: "posCustomerNameLast"))
            if !c.isEmpty { return c }
            return ""
        }()

        return """
        Fastlane Alert
        #\(orderId) \(nowTime) \(deviceName)
        \(customerName.isEmpty ? "" : "Customer: \(customerName)")
        """
    }

    private func makeShareTextPayments(orderId: Int, payEvents: [PaymentEvent]) -> String {

        func money(_ v: Double) -> String { String(format: "%.2f", v) }

        func clip(_ s: String?, _ n: Int) -> String {
            let t = (s ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !t.isEmpty else { return "-" }
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }

        // ✅ super-short "why" tag so we can actually understand the story (CASH / LATER / CANCEL_TERM / AUTO / RETRY etc.)
        func whyTag(_ reason: String?) -> String {
            let r = (reason ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !r.isEmpty else { return "" }

            // keep it tiny + URL friendly
            let safe = r
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "|", with: "_")
            return " \(clip(safe, 10))"
        }

        let header = makeShareHeader(orderId: orderId)

        guard !payEvents.isEmpty else {
            return """
            \(header)
            💳 PAY: (none)
            """
        }

        // ✅ keep it short, but tell the story
        // - last 8 events (still usually tiny)
        // - fields: time + type + ₪amount + status + reasonTag (tiny)
        let lines = payEvents.suffix(8).map { e in
            let t = formatTime(e.ts)
            let type = e.type.rawValue
            let amt = money(e.amount)

            // status: show only if not "-"
            let status = clip(e.status, 12)
            let statusPart = (status == "-" ? "" : " \(status)")

            // why: only if exists
            let why = whyTag(e.reason)

            return "\(t) \(type) ₪\(amt)\(statusPart)\(why)"
        }

        return """
        \(header)
        💳 PAY
        \(lines.joined(separator: "\n"))
        """
    }

    private func makeShareTextPrinters(orderId: Int, events: [PrintEvent]) -> String {
        func clip(_ s: String, _ n: Int) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }

        let header = makeShareHeader(orderId: orderId)

        guard !events.isEmpty else {
            return """
            \(header)
            🖨️ PRINT: (none)
            """
        }

        // ✅ short: last ~8 lines, clipped
        let lines = events.suffix(8).map { e in
            let t = formatTime(e.ts)
            let ms = e.ms.map { "\($0)ms" } ?? "-"
            let reason = clip((e.reason ?? "").replacingOccurrences(of: "\n", with: " "), 60)
            return "\(t) \(e.station.uppercased()) \(e.type.rawValue) \(ms) \(reason)"
        }

        return """
        \(header)
        🖨️ PRINT
        \(lines.joined(separator: "\n"))
        """
    }

    private func whatsappURL(text: String) -> URL? {
        var comps = URLComponents(string: "https://wa.me/\(whatsappTo)")
        comps?.queryItems = [URLQueryItem(name: "text", value: text)]
        return comps?.url
    }

    private func formatTime(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func qrImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Payments log types

enum PaymentEventType: String, Codable {
    case uiTap = "UI_TAP"
    case uiRetryTap = "UI_RETRY_TAP"
    case uiBlocked = "UI_BLOCKED"

    case apiStartBegin = "API_START_BEGIN"
    case apiStartDone  = "API_START_DONE"
    case apiStartError = "API_START_ERROR"

    case resultApproved = "RESULT_APPROVED"
    case resultDeclined = "RESULT_DECLINED"
    case resultUnknown  = "RESULT_UNKNOWN"
    case resultPending  = "RESULT_PENDING"

    case reconcileTap   = "RECONCILE_TAP"
    case reconcileDone  = "RECONCILE_DONE"
    
    case orderComplete   = "ORDER_COMPLETE"
    case flowFinish      = "FLOW_FINISH"
    case callbackIgnored = "CALLBACK_IGNORED"
}

struct PaymentEvent: Codable {
    let ts: Double
    let ticket: Int
    let miniAppId: Int
    let amount: Double

    let attemptId: String
    let sessionId: String?
    let referenceNumber: String?
    let transactionId: String?

    let status: String?
    let path: String?
    let ms: Int?
    let reason: String?
    let type: PaymentEventType
}

final class PaymentJournal {
    static let shared = PaymentJournal()

    private let q = DispatchQueue(label: "PaymentJournal")
    private let maxBytes: Int = 2_500_000
    private let keepSeconds: Double = 60 * 60 * 24 * 7

    private lazy var fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("payment-journal.jsonl")
    }()

    func log(_ e: PaymentEvent) {
        q.async {
            self.appendLine(e)
            self.trimIfNeeded()
        }
    }

    func readAll() -> [PaymentEvent] {
        q.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }

            let decoder = JSONDecoder()
            var out: [PaymentEvent] = []
            for line in text.split(separator: "\n") {
                if let d = String(line).data(using: .utf8),
                   let ev = try? decoder.decode(PaymentEvent.self, from: d) {
                    out.append(ev)
                }
            }
            return out
        }
    }

    func read(ticket: Int) -> [PaymentEvent] {
        readAll()
            .filter { $0.ticket == ticket }
            .sorted { $0.ts < $1.ts }
    }

    /// ✅ Fallback: if ticket != orderId, match the closest attempt by time (same miniAppId)
    func readClosestAttempt(nearTs: Double, miniAppId: Int, maxWindowSeconds: Double) -> [PaymentEvent] {
        let all = readAll()
            .filter { $0.miniAppId == miniAppId }
            .sorted { $0.ts < $1.ts }

        guard !all.isEmpty else { return [] }

        var best: PaymentEvent? = nil
        var bestDelta = Double.greatestFiniteMagnitude

        for e in all {
            let d = abs(e.ts - nearTs)
            if d < bestDelta {
                bestDelta = d
                best = e
            }
        }

        guard let chosen = best, bestDelta <= maxWindowSeconds else { return [] }

        return all
            .filter { $0.attemptId == chosen.attemptId }
            .sorted { $0.ts < $1.ts }
    }

    func exportURL() -> URL { fileURL }

    // MARK: - Internals

    private func appendLine(_ e: PaymentEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        guard let data = try? encoder.encode(e),
              var line = String(data: data, encoding: .utf8)
        else { return }

        line.append("\n")
        let lineData = Data(line.utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            try? lineData.write(to: fileURL, options: .atomic)
        } else {
            if let fh = try? FileHandle(forWritingTo: fileURL) {
                defer { try? fh.close() }
                try? fh.seekToEnd()
                try? fh.write(contentsOf: lineData)
            }
        }
    }

    private func trimIfNeeded() {
        let cutoff = Date().timeIntervalSince1970 - keepSeconds

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return }

        var lines = text.split(separator: "\n").map(String.init)
        if lines.isEmpty { return }

        // time trim
        lines = lines.filter { line in
            guard let r = line.range(of: "\"ts\":") else { return true }
            let after = line[r.upperBound...]
            if let comma = after.firstIndex(of: ",") {
                let num = after[..<comma]
                return (Double(num) ?? 9e99) >= cutoff
            }
            return true
        }

        // size trim
        var newText = lines.joined(separator: "\n")
        newText.append(newText.isEmpty ? "" : "\n")

        if newText.utf8.count > maxBytes {
            while newText.utf8.count > maxBytes, lines.count > 50 {
                lines.removeFirst(50)
                newText = lines.joined(separator: "\n") + "\n"
            }
        }

        try? Data(newText.utf8).write(to: fileURL, options: .atomic)
    }
}

import SwiftUI

struct TodayPrintLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var events: [PrintEvent] = []

    // ✅ Israel “today start”
    private var todayStartTs: Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return cal.startOfDay(for: Date()).timeIntervalSince1970
    }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    VStack(spacing: 10) {
                        Text("אין לוגים מהיום")
                            .foregroundColor(.secondary)

                        Button("רענן") { load() }
                            .font(.system(size: 16, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .trailing, spacing: 10) {
                            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                                row(e)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("לוגים מהיום")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(8)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("רענן") { load() }
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { load() }
    }

    private func load() {
        // ✅ Read all -> filter today -> newest first
        let all = PrintJournal.shared.readAll()

        events = all
            .filter { $0.ts >= todayStartTs }
            .sorted { $0.ts > $1.ts }     // newest -> oldest

        // If you want OLDEST -> NEWEST instead, swap to:
        // .sorted { $0.ts < $1.ts }
    }

    private func row(_ e: PrintEvent) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Text(formatTime(e.ts))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                if let ms = e.ms {
                    Text("\(ms)ms")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("\(e.station.uppercased())  \(e.type.rawValue)")
                .font(.system(size: 16, weight: .bold))

            Text("\(e.host):\(e.port)  •  \(e.dedupeKey)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)

            if let r = e.reason, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(r)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatTime(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
