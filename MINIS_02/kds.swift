import SwiftUI
import Foundation

import AVFoundation

private struct WaitBadge: Equatable {
    let systemImage: String
    let text: String
}

private struct WaitBadgeView: View {
    let badge: WaitBadge

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: badge.systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black.opacity(0.75))

            Text(badge.text)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.black.opacity(0.85))

            Image(systemName: badge.systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.black.opacity(0.06)))
    }
}

struct SwipeUpCardCarousel: View {

    @AppStorage("kds.selectedStations") private var selectedStationsRaw: String = ""
    @AppStorage("kds.historyCardIds") private var historyCardIdsRaw: String = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("admin.pickupLocation") private var adminPickupLocation: String = "humanity"
    enum Tab: String, CaseIterable { case active = "עכשיו", history = "היסטוריה" }
    @State private var showDrinkComic = false
    @State private var drinkComicPulse = false
    @State private var showPastryComic = false
    @State private var pastryComicPulse = false
    @State private var pastryComicToken = UUID()
    @State private var debugPlayer: AVPlayer? = nil
    @AppStorage(ExperienceModeKeys.mode) private var experienceModeRaw: String = ExperienceMode.casual.rawValue
    
    private func cardStatusFromBackend(_ s: Int) -> Card.Status {
        // ✅ Your rule: active only when status < 2
        return (s < 2) ? .active : .history
    }
    
    
    private func normalizeModToken(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: " ", with: "")
    }

    private func isDefaultHiddenModifier(_ stripped: String) -> Bool {
        // Put here whatever you already hide as “default”
        // (examples — tweak to YOUR defaults)
        let t = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        // If you already hide "רגיל", "סטנדרט", etc:
        let hidden: Set<String> = ["רגיל", "סטנדרט", "ברירת מחדל"]

        // NOTE: we intentionally DO NOT include "קטן" here anymore,
        // because we will allow it only when it came from "גודל:קטן".
        return hidden.contains(t)
    }
    
    private func ensureDefaultExperienceMode() {
        if UserDefaults.standard.string(forKey: ExperienceModeKeys.mode) == nil {
            UserDefaults.standard.set(ExperienceMode.casual.rawValue, forKey: ExperienceModeKeys.mode)
        }
    }
    private func debugPlayBeepOnce() {
        // Try a few common filename variants
        let candidates: [(String, String)] = [
            ("bell", "mp4"),
            ("bell", "m4a"),
            ("bell", "mp3"),
            ("bell", "m4a")
        ]

        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                print("🔊 DEBUG: found sound file:", name + "." + ext, "→", url.lastPathComponent)

                let item = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: item)
                player.volume = 1.0

                // Keep strong reference
                debugPlayer = player

                // Nuke silent mode / routing surprises
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                    try AVAudioSession.sharedInstance().setActive(true)
                    print("🔊 DEBUG: AVAudioSession active")
                } catch {
                    print("🔊 DEBUG: AVAudioSession error:", error.localizedDescription)
                }

                // Observe end
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                    print("🔊 DEBUG: playback ended")
                }

                player.play()
                print("🔊 DEBUG: player.play() called")
                return
            }
        }

        print("🔊 DEBUG: beep file NOT found in bundle. Checked:", candidates.map { "\($0.0).\($0.1)" }.joined(separator: ", "))
    }
    private func isWaitingForPastry(_ card: Card) -> Bool {
        guard card.status == .active else { return false }
        guard card.station == .bar else { return false }

        let sameOrderActive = cards.filter { $0.orderId == card.orderId && $0.status == .active }
        let hasBar = sameOrderActive.contains { $0.station == .bar }
        let hasBakery = sameOrderActive.contains { $0.station == .bakery }

        return hasBar && hasBakery
    }
    
    private func stationFromPrinters(_ printers: [String]?) -> Station {
        let set = Set(printers ?? [])

        // Priority rules (important!)
        if set.contains("s1") { return .kitchen }   // מטבח
        if set.contains("s2") { return .bar }       // בר
        if set.contains("s3") { return .bakery }    // ויטרינה

        // fallback (safe default)
        return .bar
    }
    enum Station: String, CaseIterable, Identifiable, Hashable {
        case bar = "בר"
        case bakery = "מאפיה"
        case kitchen = "מטבח"
        var id: String { rawValue }
    }

    @MainActor
    private func triggerPastryComic() {
        pastryComicToken = UUID()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            showPastryComic = true
            pastryComicPulse.toggle()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.25)) {
                showPastryComic = false
            }
        }
    }
    
    private func isWaitingForDrink(_ card: Card) -> Bool {
        // Must be bakery station
        guard card.station == .bakery else { return false }

        // Must be ACTIVE
        guard card.status == .active else { return false }

        // Must have BOTH active cards for this order: bar + bakery
        let sameOrderActive = cards.filter { $0.orderId == card.orderId && $0.status == .active }
        let hasBar = sameOrderActive.contains { $0.station == .bar }
        let hasBakery = sameOrderActive.contains { $0.station == .bakery }

        return hasBar && hasBakery
    }
    
    struct Order: Identifiable, Equatable {
        let id: Int
        let number: Int
        let customerName: String
        let note: String?
        var items: [OrderItem]
        var isTA: Bool
        var placedAt: Date
        let backendStatus: Int        // ✅ ADD
        var customerPhone: String?
    }
    
    
    private func bestPhone(_ o: KDSAdminOrderDTO) -> String? {
        let raw = (o.customerPhone ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    
    
    
    struct OrderItem: Identifiable, Equatable {
        let id: Int
        let name: String
        let qty: Int
        let station: Station
        let modifiers: String?
    }

    struct ItemRow: Identifiable, Equatable {
        let id: Int
        let qty: Int
        let name: String
        let modifierLines: [String]
    }

    struct Card: Identifiable, Equatable {

        enum Status { case active, history }

        let id: String                 // "\(orderId)-\(station.rawValue)"
        let orderId: Int               // backend order id
        let station: Station

        // ✅ NEW: printed “big number” (ticketNumber / number)
        // If you don’t have it, set nil and fall back to orderId in UI.
        var orderNumber: Int?

        var name: String
        var isTA: Bool

        // ✅ Keep exactly what you show on ticket (you changed this to "HH:mm   dd/MM/yyyy")
        var timeText: String

        var itemRows: [ItemRow]
        var note: String?

        // ✅ For black phone bar + call button
        var customerPhone: String?

        var status: Status
        var completedAt: Date?

        // ✅ For trimming and sorting
        var placedAt: Date

        // MARK: - Helpers (use these in UI so it matches printer)

        /// Printed “big id” at top of ticket: prefer orderNumber, else orderId.
        var printedTopNumberText: String {
            if let n = orderNumber, n > 0 { return "\(n)" }
            return "\(orderId)"
        }

        /// Team tables should not print phone (like your makeJob logic)
        var isTeamTable: Bool {
            name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("שולחן")
        }

        /// Phone line (nil if empty or team table)
        var phoneLine: String? {
            guard !isTeamTable else { return nil }
            let p = (customerPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? nil : p
        }
    }
    
    @MainActor
    private func trimCardsToMax(activeMax: Int = 25, historyMax: Int = 25) {

        // ---------- HISTORY cap ----------
        var historyIdxOldestFirst: [Int] = cards.enumerated()
            .filter { $0.element.status == .history }
            .sorted {
                let a = $0.element.completedAt ?? $0.element.placedAt
                let b = $1.element.completedAt ?? $1.element.placedAt
                return a < b
            }
            .map(\.offset)

        if historyIdxOldestFirst.count > historyMax {
            let removeCount = historyIdxOldestFirst.count - historyMax
            let toRemove = Array(historyIdxOldestFirst.prefix(removeCount)).sorted(by: >)
            for idx in toRemove { cards.remove(at: idx) }
        }

        // ---------- ACTIVE cap ----------
        var activeIdxOldestFirst: [Int] = cards.enumerated()
            .filter { $0.element.status == .active }
            .sorted { $0.element.placedAt < $1.element.placedAt }
            .map(\.offset)

        if activeIdxOldestFirst.count > activeMax {
            let removeCount = activeIdxOldestFirst.count - activeMax
            let toRemove = Array(activeIdxOldestFirst.prefix(removeCount)).sorted(by: >)
            for idx in toRemove { cards.remove(at: idx) }
        }
    }
    
    private var miniAppId: Int {
        let v = UserDefaults.standard.integer(forKey: "miniAppId")
        if v > 0 { return v }

        // fallback if you still store it as string "shopId"
        if let s = UserDefaults.standard.string(forKey: "shopId"),
           let n = Int(s), n > 0 {
            return n
        }

        return 12
    }
    
    private func teamNameFramed(_ text: String) -> some View {
        Text("＊＊＊ \(text) ＊＊＊")
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundColor(.black)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .center)   // ✅
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
            )
    }

    private let pollSeconds: Double
    init(pollSeconds: Double = 8.0) {
        self.pollSeconds = pollSeconds
    }
     struct PrintedTicketHeader: View {
        let orderIdText: String
        let customerName: String
        let phone: String?
        let isTA: Bool
        let dateTimeText: String   // "HH:mm   dd/MM/yyyy"
        let isTeamTable: Bool

        var body: some View {
            VStack(spacing: 8) {

                // 1) ORDER ID (huge, centered)
                Text(orderIdText)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 2) Customer name (or framed team table)
                if isTeamTable {
                    teamNameFramed(customerName)
                } else {
                    Text(customerName.isEmpty ? "—" : customerName)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // 3) Phone black bar (only if exists and not team table)
                if let p = phone, !p.isEmpty, !isTeamTable {
                    blackBar(p)
                }

                // 4) TA black bar
                if isTA {
                    blackBar("TA")
                }

                // 5) Date/time big centered
                Text(dateTimeText)
                    .font(.system(size: 18, weight: .regular, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }

        private func blackBar(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
        }

         private func teamNameFramed(_ text: String) -> some View {
             Text("＊＊＊ \(text) ＊＊＊")
                 .font(.system(size: 18, weight: .bold, design: .monospaced))
                 .foregroundColor(.black)
                 .padding(.vertical, 6)
                 .frame(maxWidth: .infinity, alignment: .center)   // ✅
                 .overlay(
                     RoundedRectangle(cornerRadius: 10, style: .continuous)
                         .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
                 )
         }
    }

    @State private var selectedTab: Tab = .active
    @State private var selectedStations: Set<Station> = Set(Station.allCases)

    @State private var orders: [Order] = []
    @State private var cards: [Card] = []
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var didInitialPollLoad: Bool = false
    @State private var seenActiveOrderIds: Set<Int> = []
    
    private let rowHeight: CGFloat = 230

    private var screenBG: Color { Color(red: 50/255, green: 78/255, blue: 87/255) }
    private var cardBG: Color { Color.white }
    private var cardStroke: Color { Color.black.opacity(0.08) }
    private var cardRadius: CGFloat { 12 }
    private var sepText: String { String(repeating: "—", count: 18) }

    // MARK: - Storage

    private func loadStationsFromStorage() -> Set<Station> {
        let raw = selectedStationsRaw.split(separator: ",").map { String($0) }
        let restored = Set(raw.compactMap { Station(rawValue: $0) })
        return restored.isEmpty ? Set(Station.allCases) : restored
    }
    
    private func setOrderStatus(orderId: Int, status: Int) async throws {
        let url = URL(string: "https://minis.studio/api/admin/orders/\(orderId)/status")!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        let payload: [String: Int] = ["status": status]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func saveStationsToStorage(_ set: Set<Station>) {
        let sorted = Station.allCases.filter { set.contains($0) }.map { $0.rawValue }
        selectedStationsRaw = sorted.joined(separator: ",")
    }

    private func loadHistoryMap() -> [String: Date] {
        var out: [String: Date] = [:]
        for p in historyCardIdsRaw.split(separator: ",") {
            let bits = p.split(separator: "|", maxSplits: 1).map(String.init)
            guard bits.count == 2, let ts = Double(bits[1]) else { continue }
            out[bits[0]] = Date(timeIntervalSince1970: ts)
        }
        return out
    }

    private func saveHistoryMap(_ map: [String: Date]) {
        historyCardIdsRaw = map
            .sorted { $0.value > $1.value }
            .map { "\($0.key)|\($0.value.timeIntervalSince1970)" }
            .joined(separator: ",")
    }

    private func markCardHistory(_ card: Card) {
        var map = loadHistoryMap()
        map[card.id] = Date()
        saveHistoryMap(map)

        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx].status = .history
            cards[idx].completedAt = map[card.id]
        }
    }

    private func stripModifierTitle(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }

        // Support normal ":" and the full-width "：" (sometimes appears from copy/paste)
        if let r = t.range(of: ":") ?? t.range(of: "：") {
            let after = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? t : after
        }

        return t
    }
    // MARK: - Cards

    // MARK: - Cards (ADD ONLY)

    @MainActor
    private func applyFetchedOrdersAddOnly(_ fetched: [Order]) {

        // ✅ 0) PLAY BELL when a NEW ACTIVE order arrives (but NOT on first load)
        let activeIdsNow = Set(fetched.filter { $0.backendStatus < 2 }.map(\.id))
        let newActiveIds = activeIdsNow.subtracting(seenActiveOrderIds)

        if didInitialPollLoad, !newActiveIds.isEmpty && miniAppId == 13{
            debugPlayBeepOnce()
        }

        // Update seen set (and mark that we completed first load)
        seenActiveOrderIds.formUnion(activeIdsNow)
        didInitialPollLoad = true

        // --- your existing code continues ---
        self.orders = fetched

        let historyMap = loadHistoryMap()

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        df.dateFormat = "HH:mm   dd/MM/yyyy"

      //  let cutoff = Date().addingTimeInterval(-TimeInterval(40 * 60))

        for order in fetched {

            let backendStatus: Card.Status = cardStatusFromBackend(order.backendStatus)
           // if backendStatus == .history, order.placedAt < cutoff {
           //     continue
           // }

            let grouped = Dictionary(grouping: order.items, by: { $0.station })

            for (station, items) in grouped {
                let id = "\(order.id)-\(station.rawValue)"
                let timeText = df.string(from: order.placedAt)

                if shouldExcludeCustomer(order.customerName) {
                    continue
                }

                let itemRows: [ItemRow] = items
                    .sorted { $0.name < $1.name }
                    .map { it in
                        let lines: [String] = {
                            let raw = (it.modifiers ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !raw.isEmpty else { return [] }

                            let parts: [String] = raw
                                .replacingOccurrences(of: "，", with: ",") // just in case
                                .split { ch in
                                    ch == "," || ch == "\n" || ch == "\r\n"
                                }
                                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }

                            // ✅ Detect explicit small size in ORIGINAL tokens (before stripping title)
                            let hasSmallSize = parts.contains { p in
                                let normalized = p
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .replacingOccurrences(of: "：", with: ":")
                                    .replacingOccurrences(of: " ", with: "")
                                return normalized == "גודל:קטן"
                            }

                            // 1) Strip titles
                            var lines: [String] = parts
                                .map { stripModifierTitle($0) }
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }

                            // 2) Hide defaults (your normal rule)
                            lines = lines.filter { !isDefaultHiddenModifier($0) }

                            // 3) ✅ Exception: if it's explicitly גודל:קטן, force-show it
                            if hasSmallSize {
                                let forced = "גודל: קטן"     // change to "קטן" if you prefer
                                if !lines.contains(forced) {
                                    lines.insert(forced, at: 0)
                                }
                                // avoid duplicates if "קטן" appears separately
                                lines.removeAll { $0 == "קטן" }
                            }

                            return lines
                        }()

                        return ItemRow(
                            id: it.id,
                            qty: it.qty,
                            name: it.name,
                            modifierLines: lines
                        )
                    }

                let note = normalizedNote(order.note)
                let forcedHistoryAt = historyMap[id]

                if let idx = cards.firstIndex(where: { $0.id == id }) {
                    cards[idx].orderNumber = order.number          // ✅ ADD

                    cards[idx].name = order.customerName
                    cards[idx].isTA = order.isTA
                    cards[idx].timeText = timeText
                    cards[idx].itemRows = itemRows
                    cards[idx].note = note
                    cards[idx].customerPhone = order.customerPhone
                    cards[idx].placedAt = order.placedAt

                    if let done = forcedHistoryAt {
                        cards[idx].status = .history
                        cards[idx].completedAt = done
                    } else {
                        // ✅ follow backend
                        cards[idx].status = backendStatus
                        if backendStatus == .history {
                            // give it a completion time if it just became history
                            cards[idx].completedAt = cards[idx].completedAt ?? Date()
                        } else {
                            cards[idx].completedAt = nil
                        }
                    }

                } else {
                    var new = Card(
                        id: id,
                        orderId: order.id,
                        station: station,
                        orderNumber: order.number,             // ✅ ADD

                        name: order.customerName,
                        isTA: order.isTA,
                        timeText: timeText,
                        itemRows: itemRows,
                        note: note,
                        customerPhone: order.customerPhone,
                        status: backendStatus,
                        completedAt: nil,
                        placedAt: order.placedAt
                    )

                    if let done = forcedHistoryAt {
                        new.status = .history
                        new.completedAt = done
                    } else if backendStatus == .history {
                        new.completedAt = Date()
                    }

                    if let lastIdx = cards.lastIndex(where: { $0.station == station }) {
                        cards.insert(new, at: lastIdx + 1)
                    } else {
                        cards.append(new)
                    }
                }
            }
        }

       // trimCardsToMax(activeMax: 25, historyMax: 25)
    }
    
    private func shouldExcludeCustomer(_ name: String) -> Bool {
        return false   // ✅ DEBUG: show EVERYTHING
    }

    // tiny helper for the insert case
    @MainActor
    private func lastSameStationIdx(_ station: Station) -> Int? {
        cards.lastIndex(where: { $0.station == station })
    }
    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                if let fetched = try? await fetchOrdersFromBackend(miniAppId: miniAppId) {
                    await MainActor.run {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            self.applyFetchedOrdersAddOnly(fetched)   // ✅ ONLY add/update in-place
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Networking

    private func fetchOrdersFromBackend(miniAppId: Int) async throws -> [Order] {

        var comps = URLComponents(string: "https://minis.studio/api/admin/ordersByLocation")!

        var q: [URLQueryItem] = [
            .init(name: "miniAppId", value: "\(miniAppId)")
        ]

        // ✅ Only miniAppId 13 uses location filtering
        if miniAppId == 13 {
            let loc = adminPickupLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty {
                q.append(.init(name: "pickupLocation", value: loc))
            }
        }

        comps.queryItems = q
        let url = comps.url!

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        print("📡 KDS fetch:", url.absoluteString)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys

        // ✅ Your endpoint returns wrapped { ok, count, orders }
        let wrapped = try decoder.decode(KDSAdminOrdersWrappedDTO.self, from: data)
        return mapDTOToOrders(wrapped.orders ?? [])
    }
    private func mapDTOToOrders(_ decodedArray: [KDSAdminOrderDTO]) -> [Order] {
        let now = Date()
        var out: [Order] = []
        out.reserveCapacity(decodedArray.count)

        for dto in decodedArray {
            out.append(mapOneOrder(dto, now: now))
        }
        return out
    }

    private func mapOneOrder(_ dto: KDSAdminOrderDTO, now: Date) -> Order {
        let placed = dto.placedAtDate ?? now
        let orderId = dto.id ?? dto.ticketNumber ?? 0
        let number = dto.ticketNumber ?? dto.number ?? dto.orderNumber ?? 0
        if dto.id == 27452 || dto.id == 27440 || dto.ticketNumber == 1040 || dto.ticketNumber == 1032 {
            print("🟦 KDS DEBUG HIT: id=\(dto.id ?? -1) ticket=\(dto.ticketNumber ?? -1) status=\(dto.status ?? -1) name=\(bestName(dto)) lines=\((dto.lines ?? dto.items ?? []).count)")
        }
        let itemsDTO: [KDSAdminLineItemDTO] = dto.lines ?? dto.items ?? []
        let items = mapLineItems(itemsDTO, orderId: orderId)

        return Order(
            id: orderId,
            number: number,
            customerName: bestName(dto),
            note: normalizedNote(dto.note),
            items: items,
            isTA: isTakeAway(dto),
            placedAt: placed,
            backendStatus: dto.status ?? 0,
            customerPhone: bestPhone(dto)     // ✅ ADD
        )
    }

    private func mapLineItems(
        _ itemsDTO: [KDSAdminLineItemDTO],
        orderId: Int
    ) -> [OrderItem] {

        var out: [OrderItem] = []
        out.reserveCapacity(itemsDTO.count)

        var usedIds = Set<Int>()

        for (idx, li) in itemsDTO.enumerated() {
            let st = stationFromPrinters(li.printers)

            let name = (li.name ?? "—")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let qty = max(1, li.qty ?? li.quantity ?? 1)

            let rawMods = (li.modifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // ✅ base candidate (may repeat!)
            let candidate = li.itemId ?? 0

            // ✅ force uniqueness per LINE if candidate repeats / is 0
            let uniqueId: Int = {
                if candidate != 0, !usedIds.contains(candidate) { return candidate }
                // stable-ish per order, includes index + content
                return "\(orderId)|\(idx)|\(name)|\(qty)|\(st.rawValue)|\(rawMods)".hashValue
            }()

            usedIds.insert(uniqueId)

            out.append(
                OrderItem(
                    id: uniqueId,
                    name: name.isEmpty ? "—" : name,
                    qty: qty,
                    station: st,
                    modifiers: rawMods.isEmpty ? nil : rawMods
                )
            )
        }
        let dups = Dictionary(grouping: out, by: \.id).filter { $1.count > 1 }
        if !dups.isEmpty {
            print("🟥 DUP ITEM IDS:", dups.map { "\($0.key): \($0.value.map{$0.name})" })
        }
        return out
    }

    private func stableFallbackItemId(orderId: Int, name: String?, station: String?) -> Int {
        "\(orderId)|\(name ?? "")|\(station ?? "")".hashValue
    }

    private func normalizedNote(_ note: String?) -> String? {
        let n = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    private func bestName(_ o: KDSAdminOrderDTO) -> String {
        let raw = (o.customerDisplayName ?? o.customerName ?? o.displayName ?? o.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "—" : raw.uppercased()
    }

    private func isTakeAway(_ o: KDSAdminOrderDTO) -> Bool {
        if let v = o.isTA { return v }
        if let s = o.service?.lowercased() { return s != "sit" }
        if let f = o.fulfillment?.lowercased() {
            return f.contains("take") || f.contains("pickup") || f == "ta"
        }
        return false
    }
    private struct PastryComicOverlay: View {
        let pulse: Bool

        @State private var shake = false
        @State private var pop = false

        var body: some View {
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                VStack(spacing: 20) {

                    // 🥐 BIG SHAKING PASTRY ICON
                    Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                        .font(.system(size: 120, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                        .rotationEffect(.degrees(shake ? -8 : 8))
                        .scaleEffect(pop ? 1.15 : 0.9)
                        .animation(
                            .linear(duration: 0.08)
                                .repeatCount(12, autoreverses: true),
                            value: shake
                        )
                        .animation(
                            .spring(response: 0.35, dampingFraction: 0.55),
                            value: pop
                        )

                    // 💬 Comic label
                    Text("++++ מחכה למאפה ++++")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.black.opacity(0.2), lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    Text("המאפיה על זה 🥐✨")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .onAppear {
                
                shake = true
                pop = true
            }
            .allowsHitTesting(false)
        }
    }
    private struct DrinkComicOverlay: View {
        let pulse: Bool

        @State private var shake = false
        @State private var pop = false

        var body: some View {
            ZStack {
                // Soft dim background
                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                VStack(spacing: 20) {

                    // ☕ BIG SHAKING COFFEE
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 120, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                        .rotationEffect(.degrees(shake ? -8 : 8))
                        .scaleEffect(pop ? 1.15 : 0.9)
                        .animation(
                            .linear(duration: 0.08)
                                .repeatCount(12, autoreverses: true),
                            value: shake
                        )
                        .animation(
                            .spring(response: 0.35, dampingFraction: 0.55),
                            value: pop
                        )

                    // 💬 Comic label
                    Text("++++ מחכה לשתייה ++++")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.black.opacity(0.2), lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    // Optional fun sub-text
                    Text("הבר מכין את הקפה ☕✨")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .onAppear {
                shake = true
                pop = true
            }
            .allowsHitTesting(false) // ✅ never blocks UI
        }
    }

    private struct ComicRays: View {
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    ForEach(0..<16, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: w * 0.08, height: h * 1.2)
                            .rotationEffect(.degrees(Double(i) * (360.0 / 16.0)))
                            .position(x: w/2, y: h/2)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func mapStation(_ raw: String?) -> Station? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("kitchen") || s.contains("מטבח") { return .kitchen }
        if s.contains("bakery")  || s.contains("מאפ")  { return .bakery }
        if s.contains("bar")     || s.contains("בר")   { return .bar }
        if s.contains("cashpoint") || s.contains("teal") { return .bar }
        return nil
    }
    
    @MainActor
    private func triggerDrinkComic() {
        // If already showing, restart it
        showDrinkComic = false
        drinkComicPulse = false

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            showDrinkComic = true
            drinkComicPulse = true
        }

        // Auto-hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                showDrinkComic = false
                drinkComicPulse = false
            }
        }
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            ZStack {
                screenBG.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 16)

                    let orderedStations = Station.allCases.filter { selectedStations.contains($0) }

                    if orderedStations.isEmpty {
                        Text("Select a station")
                            .foregroundColor(.white.opacity(0.75))
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.top, 40)
                        Spacer()
                    } else {
                        VStack(spacing: 16) {
                            ForEach(orderedStations) { st in
                                StationRow(
                                    station: st,
                                    tab: selectedTab,
                                    rowHeight: rowHeight,
                                    cards: cards,
                                    cardBG: cardBG,
                                    stroke: cardStroke,
                                    radius: cardRadius,
                                    sepText: sepText,
                                    onMoveToHistory: { dismissed in

                                        // ✅ Comic overlay when bakery is waiting for drink
                                        if dismissed.station == .bar, isWaitingForPastry(dismissed) {
                                            triggerPastryComic()
                                        }

                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            markCardHistory(dismissed)
                                        }

                                        Task {
                                            let statusToSend: Int = {
                                                switch dismissed.station {
                                                case .kitchen: return 3
                                                case .bar:     return 4
                                                case .bakery:  return 5
                                                }
                                            }()
                                            try? await setOrderStatus(orderId: dismissed.orderId, status: statusToSend)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 10)

                        Spacer(minLength: 0)
                    }
                }

                // ✅ FULL SCREEN OVERLAY MUST LIVE INSIDE THE ZSTACK
                if showPastryComic {
                    PastryComicOverlay(pulse: pastryComicPulse)
                        .id(pastryComicToken)          // ✅ critical
                        .transition(.opacity)
                        .zIndex(1000)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                if adminPickupLocation == "cafeteria" {
                    adminPickupLocation = "humanity"
                }
               // debugPlayBeepOnce()   // ✅ TEMP DEBUG

                AudioServicesPlaySystemSound(1057)
             //   BellPlayer.shared.play()
                let restored = loadStationsFromStorage()
                 selectedStations = restored
                 saveStationsToStorage(restored) // optional, keeps raw normalized
                
                startPolling()
            }
            .onDisappear {
                stopPolling()
            }
            .onChange(of: selectedStations) { newValue in
                if newValue.isEmpty {
                    selectedStations = Set(Station.allCases)
                    return
                }
                saveStationsToStorage(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 24) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                            } label: {
                                Text(tab.rawValue.uppercased())
                                    .font(.system(size: 16, weight: selectedTab == tab ? .semibold : .regular))
                                    .foregroundColor(.white)
                                    .opacity(selectedTab == tab ? 1.0 : 0.55)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    MultiSegmentedStations(stations: Station.allCases, selected: $selectedStations)
                        .fixedSize()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.clear, for: .navigationBar)
        }
        .animation(.easeInOut(duration: 0.15), value: cards.count)
        .animation(.easeInOut(duration: 0.2), value: selectedStations)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .automatic)
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackground(.clear, for: .automatic)
    }
}

// MARK: - DTOs (unique names)

private struct KDSAdminOrdersWrappedDTO: Decodable {
    let ok: Bool?
    let count: Int?
    let orders: [KDSAdminOrderDTO]?
}

private struct KDSOrderV1DTO: Decodable {
    let idempotency: String?
    let id: Int?
    let ticketNumber: Int?
    let status: Int?
    let customerDisplayName: String?
    let customer: KDSOrderV1CustomerDTO?
    let basket: [KDSOrderV1BasketLineDTO]?
    let createdAtUtc: String?
}

private struct KDSOrderV1CustomerDTO: Decodable {
    let name: String?
}

private struct KDSOrderV1BasketLineDTO: Decodable {
    let lineId: Int?
    let productId: Int?
    let name: String?
    let quantity: Int?
}
private struct KDSAdminOrderDTO: Decodable {
    let id: Int?
    let ticketNumber: Int?
    let status: Int?
    let orderSource: String?
    let number: Int?
    let orderNumber: Int?
    let customerPhone: String?
    let customerName: String?
    let customerDisplayName: String?
    let displayName: String?
    let name: String?

    let note: String?
    let service: String?

    let isTA: Bool?
    let isDelivery: Bool?
    let fulfillment: String?

    let placedAt: String?
    let createdAt: String?
    let created: String?

    let lines: [KDSAdminLineItemDTO]?
    let items: [KDSAdminLineItemDTO]?

    
}

private struct KDSAdminLineItemDTO: Decodable {
    let itemId: Int?
    let name: String?
    let qty: Int?
    let quantity: Int?

    let printers: [String]?

    let station: String?
    let printer: String?
    let stationKey: String?

    // ✅ ADD
    let modifiers: String?
    let mods: String?

    enum CodingKeys: String, CodingKey {
        case itemId, name, qty, quantity, station, printer, stationKey

        case printers = "printers"
        case Printers = "Printers"
        case printerIds = "printerIds"
        case PrinterIds = "PrinterIds"
        case stationIds = "stationIds"

        // ✅ ADD: try common keys
        case modifiers = "modifiers"
        case Mods = "Mods"
        case mods = "mods"
        case modifierText = "modifierText"
        case note = "note"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        itemId = try c.decodeIfPresent(Int.self, forKey: .itemId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        qty = try c.decodeIfPresent(Int.self, forKey: .qty)
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity)

        station = try c.decodeIfPresent(String.self, forKey: .station)
        printer = try c.decodeIfPresent(String.self, forKey: .printer)
        stationKey = try c.decodeIfPresent(String.self, forKey: .stationKey)

        // printers (your existing logic)
        if let v = try? c.decodeIfPresent([String].self, forKey: .printers) {
            printers = v
        } else if let v = try? c.decodeIfPresent([String].self, forKey: .Printers) {
            printers = v
        } else if let v = try? c.decodeIfPresent([String].self, forKey: .printerIds) {
            printers = v
        } else if let v = try? c.decodeIfPresent([String].self, forKey: .PrinterIds) {
            printers = v
        } else if let v = try? c.decodeIfPresent([String].self, forKey: .stationIds) {
            printers = v
        } else {
            printers = nil
        }

        // ✅ modifiers (try many)
        let m1 = (try? c.decodeIfPresent(String.self, forKey: .modifiers)) ?? nil
        let m2 = (try? c.decodeIfPresent(String.self, forKey: .mods)) ?? nil
        let m3 = (try? c.decodeIfPresent(String.self, forKey: .Mods)) ?? nil
        let m4 = (try? c.decodeIfPresent(String.self, forKey: .modifierText)) ?? nil
        let m5 = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil

        modifiers = m1 ?? m2 ?? m3 ?? m4 ?? m5
        mods = nil
    }
}
private extension ISO8601DateFormatter {
    static let kdsFlex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Station row

private struct StationRow: View {
    let station: SwipeUpCardCarousel.Station
    let tab: SwipeUpCardCarousel.Tab
    let rowHeight: CGFloat
    let cards: [SwipeUpCardCarousel.Card]
    let cardBG: Color
    let stroke: Color
    let radius: CGFloat
    let sepText: String
    let onMoveToHistory: (SwipeUpCardCarousel.Card) -> Void

    @State private var lastActiveCount: Int = 0   // ✅ remember previous count (per station)

    private var activeCards: [SwipeUpCardCarousel.Card] {
        cards.filter { $0.station == station && $0.status == .active }
    }

    private func waitBannerText(
        allCards: [SwipeUpCardCarousel.Card],
        current: SwipeUpCardCarousel.Card
    ) -> String? {

        // Only ACTIVE cards participate
        guard current.status == .active else { return nil }

        // Collect all active cards for the same order
        let sameOrder = allCards.filter {
            $0.orderId == current.orderId && $0.status == .active
        }

        // Buckets logic (exactly like your snippet)
        let hasBar =
            sameOrder.contains { $0.station == .bar }

        let hasBakery =
            sameOrder.contains { $0.station == .bakery }

        let hasBarAndBakery = hasBar && hasBakery
        guard hasBarAndBakery else { return nil }

        // Only show on Bakery card
        guard current.station == .bakery else { return nil }

        return "מחכה לשתייה"
    }
    private var historyCards: [SwipeUpCardCarousel.Card] {
        cards.filter { $0.station == station && $0.status == .history }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private func waitBadge(for card: SwipeUpCardCarousel.Card) -> WaitBadge? {
        // ✅ Show ONLY on BAR when BAR+BAKERY tickets exist for same active order
        guard card.station == .bar else { return nil }
        guard card.status == .active else { return nil }

        let sameOrderActive = cards.filter { $0.orderId == card.orderId && $0.status == .active }
        let hasBar = sameOrderActive.contains { $0.station == .bar }
        let hasBakery = sameOrderActive.contains { $0.station == .bakery }
        guard hasBar && hasBakery else { return nil }

        return WaitBadge(systemImage: "takeoutbag.and.cup.and.straw.fill", text: "++++ מחכה למאפה ++++")
    }
    
   
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(station.rawValue.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 14)

            if tab == .active {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .center, spacing: 10) {
                            ForEach(activeCards) { card in
                                BonesCardActive(
                                    card: card,
                                    waitBadge: waitBadge(for: card),   // ✅ NEW
                                    cardBG: cardBG,
                                    stroke: stroke,
                                    radius: radius,
                                    sepText: sepText,
                                    onDismiss: { onMoveToHistory($0) }
                                )
                                .id(card.id)
                              
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                       
                    }
                   
                    .onAppear {
                        lastActiveCount = activeCards.count
                    }
                    .onChange(of: activeCards.map(\.id)) { ids in
                        let newCount = ids.count
                        defer { lastActiveCount = newCount }

                        // ✅ KEY FIX:
                        // Only snap back when cards were REMOVED (count decreased).
                        // When polling ADDS cards, do NOTHING (no jump back).
                        guard newCount < lastActiveCount else { return }
                        guard let first = ids.first else { return }

                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            proxy.scrollTo(first, anchor: .leading)
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(historyCards) { card in
                            BonesCardHistory(
                                card: card,
                                waitBadge: waitBadge(for: card),   // ✅ NEW
                                cardBG: cardBG,
                                stroke: stroke,
                                radius: radius,
                                sepText: sepText
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                   
                }
                .frame(maxHeight: 380)
            }
        }
    }
}

// MARK: - Layout helper

private func bonesItemsMaxHeight(for card: SwipeUpCardCarousel.Card) -> CGFloat {
    let lineCount = card.itemRows.count + ((card.note?.isEmpty == false) ? 1 : 0)
    let base: CGFloat = 70
    let perLine: CGFloat = 18
    let cap: CGFloat = 420
    let h = base + perLine * CGFloat(max(0, lineCount - 3))
    return min(cap, max(base, h))
}

// MARK: - Card Active

private struct PanCaptureView: UIViewRepresentable {
    var onChanged: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    var onEnded: (_ dx: CGFloat, _ dy: CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handle(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false  // ✅ helps prevent the scrollview from also moving
        v.addGestureRecognizer(pan)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        enum Lock { case none, vertical, horizontal }
        private var lock: Lock = .none

        let onChanged: (_ dx: CGFloat, _ dy: CGFloat) -> Void
        let onEnded: (_ dx: CGFloat, _ dy: CGFloat) -> Void

        init(onChanged: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void,
             onEnded: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        // ✅ Decide axis at the start using velocity
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            if abs(v.y) > abs(v.x) {
                lock = .vertical
            } else {
                lock = .horizontal
            }
            return true
        }

        // ✅ Only allow simultaneous recognition when NOT vertical-locked
        // This prevents the horizontal ScrollView from drifting sideways while you swipe up.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return lock != .vertical
        }

        @objc func handle(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            let dx = t.x
            let dy = t.y

            switch gr.state {
            case .changed:
                if lock == .vertical {
                    onChanged(dx, dy)
                }
            case .ended, .cancelled, .failed:
                if lock == .vertical {
                    onEnded(dx, dy)
                }
                lock = .none
            default:
                break
            }
        }
    }
}

// MARK: - Printed Ticket Header (FILE SCOPE)

private struct PrintedTicketHeader: View {
    let orderIdText: String
    let customerName: String
    let phone: String?
    let isTA: Bool
    let dateTimeText: String
    let isTeamTable: Bool

    var body: some View {
        VStack(spacing: 8) {

            Text(orderIdText)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .center)

            if isTeamTable {
                teamNameFramed(customerName)
            } else {
                Text(customerName.isEmpty ? "—" : customerName)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let p = phone?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty,
               !isTeamTable {
                Text(p)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundColor(.black.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if isTA {
                blackBar("TA")
            }

            Text(dateTimeText)
                .font(.system(size: 18, weight: .regular, design: .monospaced))
                .foregroundColor(.black.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
    }

    private func blackBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
            )
    }

    private func teamNameFramed(_ text: String) -> some View {
        Text("＊＊＊ \(text) ＊＊＊")
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundColor(.black)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct BonesCardActive: View {
    let card: SwipeUpCardCarousel.Card
    let waitBadge: WaitBadge?
    let cardBG: Color
    let stroke: Color
    let radius: CGFloat
    let sepText: String
    let onDismiss: (SwipeUpCardCarousel.Card) -> Void

    @State private var dragY: CGFloat = 0
    @State private var isDismissing = false

    // ✅ NEW: collapse width to 0 before removing from data (prevents “gap/ghost slot” in LazyHStack)
    @State private var isCollapsing = false

    // ✅ dynamic content height (measured from NON-scroll content)
    @State private var measuredItemsHeight: CGFloat = 0

    private let dismissThreshold: CGFloat = 55
    private let cardWidth: CGFloat = 260
    private let minCardHeight: CGFloat = 140

    // ✅ clamp + then scroll
    private let itemsScrollCap: CGFloat = 670
    private let itemsMinHeight: CGFloat = 60

    var body: some View {
        let progress = min(max((-dragY) / 140, 0), 1)

        // ✅ clamp + scroll decision
        let clampedItemsHeight = min(max(measuredItemsHeight, itemsMinHeight), itemsScrollCap)
        let needsScroll = measuredItemsHeight > itemsScrollCap

        // ✅ IMPORTANT: always measure the NON-scroll content (ScrollView reports differently)
        let measuredView =
            itemsContent
                .readHeight { h in
                    if abs(measuredItemsHeight - h) > 1 { measuredItemsHeight = h }
                }

        return VStack(alignment: .center, spacing: 10) {

            header
            if let b = waitBadge {
                WaitBadgeView(badge: b)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text(sepText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.black.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            Group {
                if needsScroll {
                    ScrollView(.vertical, showsIndicators: false) {
                        itemsContent
                    }
                    .frame(height: itemsScrollCap) // ✅ hard cap when scrolling
                } else {
                    measuredView
                        .frame(height: clampedItemsHeight) // ✅ grows up to cap
                }
            }
        }
        .padding(12)

        // ✅ KEY: collapse the layout slot instantly so neighbors squeeze in (no empty gap)
        .frame(width: isCollapsing ? 0 : cardWidth)
        .clipped() // important so content doesn’t “stick out” while width collapses

        .frame(minHeight: minCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(cardBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1)
        )
        .contentShape(Rectangle())

        // ✅ UIKit pan overlay that works even over inner vertical ScrollView
        .overlay(
            PanCaptureView(
                onChanged: { dx, dy in
                    guard !isDismissing && !isCollapsing else { return }
                    // Only take over when it's clearly vertical
                    guard abs(dy) > abs(dx) else { return }
                    dragY = min(0, dy)
                },
                onEnded: { dx, dy in
                    guard !isDismissing && !isCollapsing else { return }

                    // If it was mostly horizontal, don't do anything
                    guard abs(dy) > abs(dx) else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { dragY = 0 }
                        return
                    }

                    if dy < -dismissThreshold {
                        isDismissing = true

                        // ✅ 1) first collapse the width (squeezes neighbors immediately)
                        withAnimation(.easeOut(duration: 0.14)) {
                            dragY = 0
                            isCollapsing = true
                        }

                        // ✅ 2) then remove from data after the collapse finishes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                            onDismiss(card)
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { dragY = 0 }
                    }
                }
            )
            .allowsHitTesting(true)
        )
        .offset(y: isDismissing ? -16 : dragY)
        .opacity(isCollapsing ? 0 : (1 - Double(progress) * 0.12))
        .scaleEffect(isDismissing ? 0.98 : (1 - progress * 0.02))
        .animation(.easeOut(duration: 0.16), value: isDismissing)
    }

    // MARK: - Items

    @ViewBuilder
    private var itemsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.itemRows) { row in
                VStack(alignment: .leading, spacing: 4) {

                    // Main line: "QTY NAME" big
                    HStack(spacing: 8) {
                        Text("\(row.qty)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))

                        Text(row.name)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.black)

                    // Modifiers: indented, smaller
                    ForEach(row.modifierLines, id: \.self) { m in
                        Text("  " + m)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.black.opacity(0.75))
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }
            }

            if let note = card.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(.black.opacity(0.75))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header (centered ticket header)

    private var header: some View {
        PrintedTicketHeader(
            orderIdText: card.printedTopNumberText,
            customerName: card.name.isEmpty ? "—" : card.name,
            phone: card.phoneLine,
            isTA: card.isTA,
            dateTimeText: card.timeText,
            isTeamTable: card.isTeamTable
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Card History


private struct BonesCardHistory: View {
    let card: SwipeUpCardCarousel.Card
    let waitBadge: WaitBadge?
    let cardBG: Color
    let stroke: Color
    let radius: CGFloat
    let sepText: String

    @State private var ringing = false

    // ✅ Local helper (no dependency on parent scope)
    private func normalizeILPhoneToE164(_ raw: String?) -> String? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("+") { return s }

        let digits = s.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        if digits.hasPrefix("0"), digits.count >= 9 { return "+972" + digits.dropFirst() }
        if digits.hasPrefix("972") { return "+" + digits }
        return nil
    }

    private func callCustomer(_ card: SwipeUpCardCarousel.Card) {
        guard let toRaw = normalizeILPhoneToE164(card.customerPhone) else {
            print("📞 CALL DEBUG: missing phone, raw=", card.customerPhone ?? "nil")
            return
        }

        let encodedTo = toRaw.replacingOccurrences(of: "+", with: "%2B")

        guard let url = URL(string: "https://minis.studio/api/admin/voice/call?to=\(encodedTo)") else {
            print("📞 CALL DEBUG: bad URL from toRaw=", toRaw, "encodedTo=", encodedTo)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data() // avoids IIS 411
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as? HTTPURLResponse
                print("📞 CALL DEBUG ← status:", http?.statusCode ?? -1)
                print("📞 CALL DEBUG ← body:", String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
            } catch {
                print("📞 CALL DEBUG ❌ network error:", error.localizedDescription)
            }
        }
    }

    private func ring() {
        guard !ringing else { return }
        ringing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ringing = false }
    }

    private var shouldScroll: Bool {
        card.itemRows.count > 5 || (card.note?.isEmpty == false)
    }

    private var canCall: Bool {
        card.phoneLine != nil && normalizeILPhoneToE164(card.customerPhone) != nil
    }

    private let cardWidth: CGFloat = 260
    private let minCardHeight: CGFloat = 120

    var body: some View {
        let itemsMaxHeight = bonesItemsMaxHeight(for: card)

        return ZStack(alignment: .bottomTrailing) {

            VStack(alignment: .center, spacing: 10) {

                // ✅ SAME printed header as ACTIVE (big number + phone line + TA + datetime)
                PrintedTicketHeader(
                    orderIdText: card.printedTopNumberText,
                    customerName: card.name.isEmpty ? "—" : card.name,
                    phone: card.phoneLine,
                    isTA: card.isTA,
                    dateTimeText: card.timeText,
                    isTeamTable: card.isTeamTable
                )
                .frame(maxWidth: .infinity, alignment: .center)

                if let b = waitBadge {
                    WaitBadgeView(badge: b)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Text(sepText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)

                Group {
                    if shouldScroll {
                        ScrollView(.vertical, showsIndicators: false) { itemsContent }
                    } else {
                        itemsContent
                    }
                }
                .frame(maxHeight: itemsMaxHeight)
            }
            .padding(12)
            .frame(width: cardWidth)
            .frame(minHeight: minCardHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(cardBG)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1)
            )

            // ✅ Only show call button when we actually have a callable phone
            if canCall {
                Button {
                    ring()
                    callCustomer(card)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .padding(10)
                .rotationEffect(.degrees(ringing ? 12 : 0))
                .offset(x: ringing ? 2 : 0, y: ringing ? -1 : 0)
                .animation(
                    ringing ? .linear(duration: 0.06).repeatCount(10, autoreverses: true) : .default,
                    value: ringing
                )
            }
        }
    }

    // ✅ SAME item rendering as ACTIVE (qty + name + modifier lines + note)
    @ViewBuilder
    private var itemsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.itemRows) { row in
                VStack(alignment: .leading, spacing: 4) {

                    HStack(spacing: 8) {
                        Text("\(row.qty)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))

                        Text(row.name)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.black)

                    ForEach(row.modifierLines, id: \.self) { m in
                        Text("  " + m)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.black.opacity(0.75))
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }
            }

            if let note = card.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(.black.opacity(0.75))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stations picker

private struct MultiSegmentedStations: View {
    let stations: [SwipeUpCardCarousel.Station]
    @Binding var selected: Set<SwipeUpCardCarousel.Station>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(stations) { st in
                let isOn = selected.contains(st)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isOn { selected.remove(st) } else { selected.insert(st) }
                    }
                } label: {
                    Text(st.rawValue.uppercased())
                        .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                        .foregroundColor(isOn ? .black : .white)
                        .opacity(isOn ? 1.0 : 0.8)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isOn ? Color.white : Color.clear)
                        )
                       
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        // hugs content (no container bg)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .fixedSize(horizontal: true, vertical: true)
    }
}

private extension KDSAdminOrderDTO {

    /// Parses many timestamp shapes we commonly see from .NET + SQL + ISO strings.
    /// If there is no timezone in the string, we assume Europe/London (server time).
    static func parseFlexDate(_ s: String) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // 1) ISO 8601 with fractional seconds
        if let d = ISO8601DateFormatter.kdsFlex.date(from: raw) { return d }

        // 2) ISO 8601 without fractional seconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }

        // 3) Common .NET formats (with/without milliseconds)
        let london = TimeZone(identifier: "Europe/London") ?? .current

        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",   // no Z
            "yyyy-MM-dd'T'HH:mm:ss",       // no Z
            "yyyy-MM-dd HH:mm:ss.SSS",     // SQL-ish
            "yyyy-MM-dd HH:mm:ss"          // SQL-ish
        ]

        for f in fmts {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = london
            df.dateFormat = f
            if let d = df.date(from: raw) { return d }
        }

        return nil
    }

    var placedAtDate: Date? {
        let s = placedAt ?? createdAt ?? created
        guard let s else { return nil }
        return Self.parseFlexDate(s)
    }
}

import SwiftUI
import Foundation
import AVFoundation   // ✅ ADD


@MainActor
final class BellPlayer {
    static let shared = BellPlayer()

    private var audio: AVAudioPlayer?

    func play() {
        
        guard let url = Bundle.main.url(forResource: "bell", withExtension: "m4") else {
            print("🔔 bell.m4a not found in bundle")
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)

            audio = try AVAudioPlayer(contentsOf: url)
            audio?.volume = 1.0
            audio?.prepareToPlay()

            let ok = audio?.play() ?? false
            print("🔔 bell play ok=\(ok) duration=\(audio?.duration ?? 0)")
        } catch {
            print("🔔 BellPlayer error:", error.localizedDescription)
        }
    }
}
