import SwiftUI
import Foundation

struct SalesReportView: View {
    let title: String
    let shopName: String
    let initialRange: DashRange
    let reports: [ZReportDashboard]
    let makeTop: (_ subset: [ZReportDashboard]) -> (categories: [SalesLine], items: [SalesLine])
    let accent: Color

    // ✅ period segment
    @AppStorage("sales.range.v1") private var rangeRaw: String = DashRange.d.rawValue
    @State private var range: DashRange = .d

    // ✅ day paging only for .d
    @State private var dayPage: Int = 0

    @State private var searchText: String = ""
    @State private var mode: SalesMode = .categories
    @AppStorage("sales.mode.v1") private var modeRaw: String = SalesMode.categories.rawValue

    private enum SalesMode: String, CaseIterable, Identifiable {
        case categories = "קטגוריות"
        case products = "פריטים"
        var id: String { rawValue }
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return cal
    }

    private var today: Date { calendar.startOfDay(for: Date()) }

    // MARK: - DayKey helpers
    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: calendar.startOfDay(for: d))
    }

    private func dateFromDayKey(_ key: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key) ?? today
    }

    // ✅ canonical key for each report (BusinessDay if present, else RangeFrom prefix)
    private func reportDayKey(_ r: ZReportDashboard) -> String {
        let bdRaw = (r.businessDay ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !bdRaw.isEmpty { return String(bdRaw.prefix(10)) }
        return String(r.rangeFrom.prefix(10)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestDayKey: String {
        reports.map(reportDayKey).max() ?? dayKey(today)
    }

    private var latestDay: Date {
        calendar.startOfDay(for: dateFromDayKey(latestDayKey))
    }

    // MARK: - Range interval (ending at latestDay)
    private var rangeInterval: DateInterval {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: latestDay) ?? latestDay

        switch range {
        case .d:
            // handled by pager (single day)
            return DateInterval(start: latestDay, end: endExclusive)

        case .w:
            let start = calendar.date(byAdding: .day, value: -6, to: latestDay) ?? latestDay
            return DateInterval(start: start, end: endExclusive)

        case .m:
            let start = calendar.date(byAdding: .day, value: -29, to: latestDay) ?? latestDay
            return DateInterval(start: start, end: endExclusive)

        case .m6:
            let start = calendar.date(byAdding: .month, value: -6, to: latestDay) ?? latestDay
            return DateInterval(start: start, end: endExclusive)

        case .y:
            let start = calendar.date(byAdding: .year, value: -1, to: latestDay) ?? latestDay
            return DateInterval(start: start, end: endExclusive)
        }
    }

    // MARK: - Day paging (only for .d)
    private var displayDay: Date {
        calendar.date(byAdding: .day, value: -dayPage, to: latestDay) ?? latestDay
    }

    private var targetKey: String {
        dayKey(displayDay)
    }

    private var dayReports: [ZReportDashboard] {
        reports.filter { reportDayKey($0) == targetKey }
    }

    // MARK: - Range subset
    private var reportsForRange: [ZReportDashboard] {
        if range == .d { return dayReports }

        let s = calendar.startOfDay(for: rangeInterval.start)
        let e = calendar.startOfDay(for: rangeInterval.end)

        return reports.filter { r in
            let dk = reportDayKey(r)
            let d = calendar.startOfDay(for: dateFromDayKey(dk))
            return d >= s && d < e
        }
    }

    // MARK: - JSON parsing
    private struct ZDash: Decodable {
        let top: Block?
        let all: Block?

        struct Block: Decodable {
            let categories: [CatLine]?
            let items: [ItemLine]?
        }

        struct CatLine: Decodable {
            let name: String?
            let amount: Double?
            let qty: Int?
        }

        struct ItemLine: Decodable {
            let productId: Int?
            let name: String?
            let amount: Double?
            let qty: Int?
            let category: String?
        }
    }

    private func decodeDash(_ jsonString: String) -> ZDash? {
        func decodeOnce(_ s: String) -> ZDash? {
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ZDash.self, from: data)
        }

        if let p = decodeOnce(jsonString) { return p }

        if let data = jsonString.data(using: .utf8),
           let inner = try? JSONDecoder().decode(String.self, from: data),
           let p2 = decodeOnce(inner) {
            return p2
        }

        return nil
    }

    // MARK: - Aggregate categories/items for any subset
    private func aggregatedCategories(from subset: [ZReportDashboard]) -> [SalesLine] {
        var map: [String: (amount: Double, qty: Int)] = [:]

        for r in subset {
            guard let s = r.jsonData, !s.isEmpty, let payload = decodeDash(s) else { continue }
            let src = payload.all?.categories ?? payload.top?.categories ?? []

            for c in src {
                let name = (c.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let cur = map[name] ?? (0, 0)
                map[name] = (cur.amount + (c.amount ?? 0), cur.qty + (c.qty ?? 0))
            }
        }

        var out = map.map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
        out.sort { $0.amount > $1.amount }
        return out
    }

    private func aggregatedItems(from subset: [ZReportDashboard]) -> [SalesLine] {
        var map: [String: (amount: Double, qty: Int)] = [:]

        for r in subset {
            guard let s = r.jsonData, !s.isEmpty, let payload = decodeDash(s) else { continue }
            let src = payload.all?.items ?? payload.top?.items ?? []

            for it in src {
                let name = (it.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let cur = map[name] ?? (0, 0)
                map[name] = (cur.amount + (it.amount ?? 0), cur.qty + (it.qty ?? 0))
            }
        }

        var out = map.map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
        out.sort { $0.amount > $1.amount }
        return out
    }

    private var categoriesForCurrentSelection: [SalesLine] {
        let cats = aggregatedCategories(from: reportsForRange)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? cats : cats.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var itemsForCurrentSelection: [SalesLine] {
        let items = aggregatedItems(from: reportsForRange)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Formatting
    private func number(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.grouping(.automatic))
    }

    private func dayLabelText() -> String {
        let d0 = calendar.startOfDay(for: displayDay)
        let today0 = calendar.startOfDay(for: Date())
        let yesterday0 = calendar.date(byAdding: .day, value: -1, to: today0) ?? today0

        if d0 == today0 { return "היום" }
        if d0 == yesterday0 { return "אתמול" }
        return targetKey
    }

    private func rangeLabelText() -> String {
        if range == .d { return dayLabelText() }

        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"

        let s = f.string(from: rangeInterval.start)
        let e = f.string(from: calendar.date(byAdding: .day, value: -1, to: rangeInterval.end) ?? rangeInterval.end)
        return "\(s) – \(e)"
    }

    // MARK: - UI

    private var rangePicker: some View {
        Picker("", selection: $range) {
            ForEach(DashRange.allCases) { r in
                Text(r.title).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: range) { newRange in
            rangeRaw = newRange.rawValue
            searchText = ""
            // day paging only relevant in .d
            if newRange != .d { dayPage = 0 }
        }
    }

    private var pagerRow: some View {
        HStack(spacing: 10) {
            Button { dayPage += 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)

            Spacer()

            Text(rangeLabelText())
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            Button { dayPage = max(0, dayPage - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .disabled(dayPage == 0)
        }
        .padding(.vertical, 6)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(SalesMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { newMode in
            modeRaw = newMode.rawValue
            searchText = ""
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField(mode == .categories ? "חיפוש קטגוריות" : "חיפוש פריטים", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ line: SalesLine) -> some View {
        HStack(spacing: 10) {

            HStack(spacing: 6) {
                Text(line.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("(\(line.qty))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(line.amount))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)

                Text("₪")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    
    private var listCard: some View {
        let headerIcon = (mode == .categories) ? "square.grid.2x2.fill" : "cup.and.saucer.fill"
        let headerTitle = (mode == .categories) ? "קטגוריות" : "פריטים"
        let data = (mode == .categories) ? categoriesForCurrentSelection : itemsForCurrentSelection

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accent)

                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accent)

                Spacer()
            }

            if reportsForRange.isEmpty {
                Text("אין דו״ח Z לטווח הזה.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)

            } else if data.isEmpty {
                Text("אין נתונים לטווח הזה.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)

            } else {
                VStack(spacing: 0) {
                    ForEach(Array(data.enumerated()), id: \.element.id) { idx, line in
                        row(line)
                        if idx != data.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))

                rangePicker

                // Day paging only when range == .d
                if range == .d {
                    pagerRow
                } else {
                    Text(rangeLabelText())
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                modePicker
                searchBar
                listCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .onAppear {
            range = DashRange(rawValue: rangeRaw) ?? initialRange
            mode = SalesMode(rawValue: modeRaw) ?? .categories
            dayPage = 0
        }
    }
}
