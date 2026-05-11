import SwiftUI
import UIKit
import Speech
import AVFoundation

// MARK: - Adaptive Color Palette

private enum BrainColors {
    static let pageBg        = Color("BrainPageBg",     bundle: nil)
    static let cardFill      = Color("BrainCardFill",   bundle: nil)
    static let cardStroke    = Color("BrainCardStroke",  bundle: nil)
    static let textPrimary   = Color("BrainTextPrimary", bundle: nil)
    static let textSecondary = Color("BrainTextSecondary", bundle: nil)
    static let textTertiary  = Color("BrainTextTertiary", bundle: nil)
    static let textQuaternary = Color("BrainTextQuaternary", bundle: nil)
    static let subtleFill    = Color("BrainSubtleFill",  bundle: nil)
    static let subtleStroke  = Color("BrainSubtleStroke", bundle: nil)
    static let invertedText  = Color("BrainInvertedText", bundle: nil)
    static let invertedBg    = Color("BrainInvertedBg",  bundle: nil)
    static let accent        = Color(red: 0.45, green: 0.95, blue: 0.72)
}

// MARK: - Brain Models

struct BrainMetric: Identifiable, Hashable, Codable {
    let title: String
    let value: String

    var id: String { title }
}

struct BrainBreakdownRow: Identifiable, Hashable, Codable {
    let title: String
    let value: String

    var id: String { title + ":" + value }
}

struct BrainReportPeriod: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let primaryValue: String
    let primaryLabel: String
    let metrics: [BrainMetric]
    let graphValues: [Double]
    let breakdownRows: [BrainBreakdownRow]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: BrainReportPeriod, rhs: BrainReportPeriod) -> Bool { lhs.id == rhs.id }
}

struct BrainCard: Identifiable, Hashable, Codable {
    let id: UUID
    let queryKey: String
    let title: String
    let subtitle: String
    let primaryValue: String
    let primaryLabel: String
    let metrics: [BrainMetric]
    let graphValues: [Double]
    var isPinned: Bool
    let reportTitle: String
    let reportSubtitle: String
    let periods: [BrainReportPeriod]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: BrainCard, rhs: BrainCard) -> Bool {
        lhs.id == rhs.id && lhs.isPinned == rhs.isPinned
    }

    static let jordanWineMock = BrainCard(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        queryKey: "product_sales:jordan_wine:march",
        title: "יין ירדן \u{00B7} מרץ",
        subtitle: "מבוסס על מכירות מוצר בין 1\u{2013}31 במרץ",
        primaryValue: "428",
        primaryLabel: "בקבוקים נמכרו",
        metrics: [
            BrainMetric(title: "הכנסות", value: "\u{20AA}31,220"),
            BrainMetric(title: "מול פבר׳", value: "+18%"),
            BrainMetric(title: "ממוצע/יום", value: "13.8")
        ],
        graphValues: [34, 41, 29, 52, 47, 61, 58, 74, 69, 88, 79, 96],
        isPinned: false,
        reportTitle: "Jordan Wine",
        reportSubtitle: "דוח מודיעין מוצר",
        periods: [
            BrainReportPeriod(
                id: "D", label: "D",
                primaryValue: "18", primaryLabel: "bottles sold",
                metrics: [
                    BrainMetric(title: "הכנסות", value: "\u{20AA}1,314"),
                    BrainMetric(title: "שינוי", value: "+6%"),
                    BrainMetric(title: "ממוצע", value: "2.2/hr")
                ],
                graphValues: [2, 4, 3, 5, 7, 4, 8, 9, 11, 13, 15, 18],
                breakdownRows: [
                    BrainBreakdownRow(title: "שעת שיא", value: "13:00\u{2013}14:00"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Dana \u{00B7} 6 בקבוקים"),
                    BrainBreakdownRow(title: "מוצר קשור", value: "יין אדום ישראלי \u{00B7} +12%")
                ]
            ),
            BrainReportPeriod(
                id: "W", label: "W",
                primaryValue: "96", primaryLabel: "bottles sold",
                metrics: [
                    BrainMetric(title: "הכנסות", value: "\u{20AA}7,104"),
                    BrainMetric(title: "שינוי", value: "+11%"),
                    BrainMetric(title: "ממוצע", value: "13.7/day")
                ],
                graphValues: [12, 18, 15, 21, 17, 28, 31],
                breakdownRows: [
                    BrainBreakdownRow(title: "יום שיא", value: "שישי \u{00B7} 28 בקבוקים"),
                    BrainBreakdownRow(title: "שעת שיא", value: "21:00\u{2013}22:00"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Dana \u{00B7} 32 בקבוקים"),
                    BrainBreakdownRow(title: "מוצר קשור", value: "יין אדום ישראלי \u{00B7} +12%")
                ]
            ),
            BrainReportPeriod(
                id: "M", label: "M",
                primaryValue: "428", primaryLabel: "bottles sold",
                metrics: [
                    BrainMetric(title: "הכנסות", value: "\u{20AA}31,220"),
                    BrainMetric(title: "שינוי", value: "+18%"),
                    BrainMetric(title: "ממוצע", value: "13.8/day")
                ],
                graphValues: [34, 41, 29, 52, 47, 61, 58, 74, 69, 88, 79, 96],
                breakdownRows: [
                    BrainBreakdownRow(title: "יום שיא", value: "שישי \u{00B7} 74 בקבוקים"),
                    BrainBreakdownRow(title: "שעת שיא", value: "21:00\u{2013}22:00"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Dana \u{00B7} 93 בקבוקים"),
                    BrainBreakdownRow(title: "מוצר קשור", value: "יין אדום ישראלי \u{00B7} +12%")
                ]
            ),
            BrainReportPeriod(
                id: "6M", label: "6M",
                primaryValue: "2,184", primaryLabel: "bottles sold",
                metrics: [
                    BrainMetric(title: "הכנסות", value: "\u{20AA}159k"),
                    BrainMetric(title: "שינוי", value: "+22%"),
                    BrainMetric(title: "ממוצע", value: "364/mo")
                ],
                graphValues: [280, 310, 344, 382, 415, 428],
                breakdownRows: [
                    BrainBreakdownRow(title: "חודש שיא", value: "מרץ \u{00B7} 428 בקבוקים"),
                    BrainBreakdownRow(title: "שעת שיא", value: "21:00\u{2013}22:00"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Dana \u{00B7} 488 בקבוקים"),
                    BrainBreakdownRow(title: "מוצר קשור", value: "יין אדום ישראלי \u{00B7} +12%")
                ]
            ),
            BrainReportPeriod(
                id: "Y", label: "Y",
                primaryValue: "4,912", primaryLabel: "bottles sold",
                metrics: [
                    BrainMetric(title: "הכנסות", value: "\u{20AA}358k"),
                    BrainMetric(title: "שינוי", value: "+31%"),
                    BrainMetric(title: "ממוצע", value: "409/mo")
                ],
                graphValues: [210, 224, 260, 288, 310, 344, 360, 382, 391, 415, 428, 452],
                breakdownRows: [
                    BrainBreakdownRow(title: "חודש שיא", value: "מרץ \u{00B7} 428 בקבוקים"),
                    BrainBreakdownRow(title: "שעת שיא", value: "21:00\u{2013}22:00"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Dana \u{00B7} 1,120 בקבוקים"),
                    BrainBreakdownRow(title: "מוצר קשור", value: "יין אדום ישראלי \u{00B7} +12%")
                ]
            )
        ]
    )

    static let dailySalesMock = BrainCard(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        queryKey: "daily_sales:today",
        title: "מכירות יומיות \u{00B7} אתמול",
        subtitle: "פירוט הכנסות לאתמול",
        primaryValue: "\u{20AA}21,513",
        primaryLabel: "revenue",
        metrics: [
            BrainMetric(title: "הזמנות", value: "443"),
            BrainMetric(title: "ממוצע לקוח", value: "\u{20AA}49"),
            BrainMetric(title: "שיא", value: "13:00")
        ],
        graphValues: [120, 340, 890, 1620, 2810, 4100, 6200, 8900, 11400, 14200, 17800, 21513],
        isPinned: false,
        reportTitle: "Daily Sales",
        reportSubtitle: "דוח מודיעין מכירות",
        periods: [
            BrainReportPeriod(
                id: "D", label: "D",
                primaryValue: "\u{20AA}21,513", primaryLabel: "revenue",
                metrics: [
                    BrainMetric(title: "הזמנות", value: "443"),
                    BrainMetric(title: "שינוי", value: "+14%"),
                    BrainMetric(title: "ממוצע", value: "\u{20AA}49")
                ],
                graphValues: [120, 340, 890, 1620, 2810, 4100, 6200, 8900, 11400, 14200, 17800, 21513],
                breakdownRows: [
                    BrainBreakdownRow(title: "שעת שיא", value: "13:00\u{2013}14:00 \u{00B7} \u{20AA}3,420"),
                    BrainBreakdownRow(title: "פריט מוביל", value: "Latte \u{00B7} 94 נמכרו"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Yael \u{00B7} \u{20AA}6,210")
                ]
            ),
            BrainReportPeriod(
                id: "W", label: "W",
                primaryValue: "\u{20AA}148k", primaryLabel: "revenue",
                metrics: [
                    BrainMetric(title: "הזמנות", value: "3,012"),
                    BrainMetric(title: "שינוי", value: "+11%"),
                    BrainMetric(title: "ממוצע", value: "\u{20AA}49")
                ],
                graphValues: [18200, 21500, 19800, 22100, 24600, 20300, 21513],
                breakdownRows: [
                    BrainBreakdownRow(title: "יום שיא", value: "חמישי \u{00B7} \u{20AA}24,600"),
                    BrainBreakdownRow(title: "פריט מוביל", value: "Latte \u{00B7} 620 נמכרו"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Yael \u{00B7} \u{20AA}41k")
                ]
            ),
            BrainReportPeriod(
                id: "M", label: "M",
                primaryValue: "\u{20AA}612k", primaryLabel: "revenue",
                metrics: [
                    BrainMetric(title: "הזמנות", value: "12,480"),
                    BrainMetric(title: "שינוי", value: "+18%"),
                    BrainMetric(title: "ממוצע", value: "\u{20AA}49")
                ],
                graphValues: [14200, 15800, 18100, 19400, 20200, 21100, 22400, 19800, 21513, 23100, 20800, 22600],
                breakdownRows: [
                    BrainBreakdownRow(title: "שבוע שיא", value: "Week 3 \u{00B7} \u{20AA}162k"),
                    BrainBreakdownRow(title: "פריט מוביל", value: "Latte \u{00B7} 2,640 נמכרו"),
                    BrainBreakdownRow(title: "קופאי מוביל", value: "Yael \u{00B7} \u{20AA}168k")
                ]
            )
        ]
    )

    static let cashierPerformanceMock = BrainCard(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        queryKey: "cashier_performance:all",
        title: "ביצועי קופאים",
        subtitle: "דירוג מכירות צוות החודש",
        primaryValue: "12",
        primaryLabel: "active cashiers",
        metrics: [
            BrainMetric(title: "מוביל", value: "Dana"),
            BrainMetric(title: "הכנסות", value: "\u{20AA}168k"),
            BrainMetric(title: "ממוצע/עובד", value: "\u{20AA}51k")
        ],
        graphValues: [168, 142, 131, 118, 104, 97, 88, 76, 64, 52, 41, 33],
        isPinned: false,
        reportTitle: "Cashier Performance",
        reportSubtitle: "דוח מודיעין צוות",
        periods: [
            BrainReportPeriod(
                id: "D", label: "D",
                primaryValue: "8", primaryLabel: "active today",
                metrics: [
                    BrainMetric(title: "מוביל", value: "Yael"),
                    BrainMetric(title: "הכנסות", value: "\u{20AA}6,210"),
                    BrainMetric(title: "ממוצע", value: "\u{20AA}2,689")
                ],
                graphValues: [6210, 4800, 3920, 3100, 2400, 1800, 1200, 880],
                breakdownRows: [
                    BrainBreakdownRow(title: "#1 Yael", value: "\u{20AA}6,210 \u{00B7} 127 הזמנות"),
                    BrainBreakdownRow(title: "#2 Dana", value: "\u{20AA}4,800 \u{00B7} 98 הזמנות"),
                    BrainBreakdownRow(title: "#3 Omer", value: "\u{20AA}3,920 \u{00B7} 80 הזמנות")
                ]
            ),
            BrainReportPeriod(
                id: "M", label: "M",
                primaryValue: "12", primaryLabel: "active cashiers",
                metrics: [
                    BrainMetric(title: "מוביל", value: "Dana"),
                    BrainMetric(title: "הכנסות", value: "\u{20AA}168k"),
                    BrainMetric(title: "ממוצע", value: "\u{20AA}51k")
                ],
                graphValues: [168, 142, 131, 118, 104, 97, 88, 76, 64, 52, 41, 33],
                breakdownRows: [
                    BrainBreakdownRow(title: "#1 Dana", value: "\u{20AA}168k \u{00B7} 3,429 הזמנות"),
                    BrainBreakdownRow(title: "#2 Yael", value: "\u{20AA}142k \u{00B7} 2,898 הזמנות"),
                    BrainBreakdownRow(title: "#3 Omer", value: "\u{20AA}131k \u{00B7} 2,673 הזמנות")
                ]
            )
        ]
    )

    static let hourlySalesMock = BrainCard(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        queryKey: "hourly_sales:today",
        title: "מכירות לפי שעה \u{00B7} היום",
        subtitle: "הכנסות לפי שעה להיום",
        primaryValue: "13:00",
        primaryLabel: "peak hour",
        metrics: [
            BrainMetric(title: "שיא הכנסה", value: "\u{20AA}3,420"),
            BrainMetric(title: "איטית", value: "08:00"),
            BrainMetric(title: "עכשיו", value: "\u{20AA}1,240/hr")
        ],
        graphValues: [120, 220, 480, 890, 1620, 2810, 3420, 2900, 2100, 1800, 1620, 1240],
        isPinned: false,
        reportTitle: "Hourly Sales",
        reportSubtitle: "דוח מודיעין שעתי",
        periods: [
            BrainReportPeriod(
                id: "D", label: "D",
                primaryValue: "13:00", primaryLabel: "peak hour",
                metrics: [
                    BrainMetric(title: "שיא הכנסה", value: "\u{20AA}3,420"),
                    BrainMetric(title: "איטית", value: "08:00"),
                    BrainMetric(title: "ממוצע/שעה", value: "\u{20AA}1,793")
                ],
                graphValues: [120, 220, 480, 890, 1620, 2810, 3420, 2900, 2100, 1800, 1620, 1240],
                breakdownRows: [
                    BrainBreakdownRow(title: "שעת שיא", value: "13:00 \u{00B7} \u{20AA}3,420"),
                    BrainBreakdownRow(title: "שעה חלשה", value: "08:00 \u{00B7} \u{20AA}120"),
                    BrainBreakdownRow(title: "שעת צהריים", value: "12:00\u{2013}14:00 \u{00B7} \u{20AA}9,130")
                ]
            ),
            BrainReportPeriod(
                id: "W", label: "W",
                primaryValue: "13:00", primaryLabel: "avg peak hour",
                metrics: [
                    BrainMetric(title: "שיא הכנסה", value: "\u{20AA}4,100"),
                    BrainMetric(title: "איטית", value: "07:00"),
                    BrainMetric(title: "ממוצע/שעה", value: "\u{20AA}1,880")
                ],
                graphValues: [180, 310, 620, 1100, 1940, 3200, 4100, 3400, 2600, 2100, 1800, 1400],
                breakdownRows: [
                    BrainBreakdownRow(title: "שעת שיא", value: "13:00 \u{00B7} \u{20AA}4,100"),
                    BrainBreakdownRow(title: "שעה חלשה", value: "07:00 \u{00B7} \u{20AA}180"),
                    BrainBreakdownRow(title: "שעת צהריים", value: "12:00\u{2013}14:00 \u{00B7} \u{20AA}10,700")
                ]
            ),
            BrainReportPeriod(
                id: "M", label: "M",
                primaryValue: "13:00", primaryLabel: "avg peak hour",
                metrics: [
                    BrainMetric(title: "שיא הכנסה", value: "\u{20AA}4,800"),
                    BrainMetric(title: "איטית", value: "07:00"),
                    BrainMetric(title: "ממוצע/שעה", value: "\u{20AA}2,040")
                ],
                graphValues: [240, 420, 810, 1400, 2200, 3600, 4800, 3900, 3000, 2400, 2000, 1600],
                breakdownRows: [
                    BrainBreakdownRow(title: "שעת שיא", value: "13:00 \u{00B7} \u{20AA}4,800"),
                    BrainBreakdownRow(title: "שעה חלשה", value: "07:00 \u{00B7} \u{20AA}240"),
                    BrainBreakdownRow(title: "שעת צהריים", value: "12:00\u{2013}14:00 \u{00B7} \u{20AA}12,300")
                ]
            )
        ]
    )
}

// MARK: - Brain API Contract

struct BrainQueryRequest: Codable {
    let miniAppId: Int
    let question: String
    let language: String
    let timezone: String
}

struct BrainQueryResponse: Codable {
    let card: BrainCard
    let sql: String?
    let rowCount: Int?
    let executionMs: Int?
}

// MARK: - Brain Debug Log
//
// Persists a rolling history of every Brain query response so we can inspect
// the exact SQL, row counts, and execution time after the fact without
// touching server logs. Stored in UserDefaults — fine for dev/debug use.

struct BrainDebugEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let question: String
    let queryKey: String
    let sql: String?
    let rowCount: Int?
    let executionMs: Int?
}

enum BrainDebugLog {
    private static let storageKey = "brain.debug.log"
    private static let maxEntries = 50

    /// Append the latest response to the front of the rolling log (newest first).
    static func append(question: String, response: BrainQueryResponse) {
        var entries = load()
        let entry = BrainDebugEntry(
            id: UUID(),
            timestamp: Date(),
            question: question,
            queryKey: response.card.queryKey,
            sql: response.sql,
            rowCount: response.rowCount,
            executionMs: response.executionMs
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        // Also dump to Xcode console so debugging is immediate.
        let preview = (response.sql ?? "<mock — no sql>")
            .split(separator: "\n").prefix(3).joined(separator: " ⏎ ")
        print("""
        🧠 Brain ▶︎ \(entry.queryKey)
           q: \(question)
           rows: \(response.rowCount.map(String.init) ?? "—") · \(response.executionMs.map { "\($0)ms" } ?? "—")
           sql: \(preview)
        """)
    }

    /// Returns the rolling log, newest first.
    static func load() -> [BrainDebugEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([BrainDebugEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

struct PinnedBrainCardState: Identifiable, Codable {
    var id: String { queryKey }
    let queryKey: String
    let question: String
    var card: BrainCard
    var lastUpdatedAt: Date
    var lastRefreshFailed: Bool

    var timeAgoLabel: String {
        let seconds = Date().timeIntervalSince(lastUpdatedAt)
        if lastRefreshFailed { return "רענון נכשל" }
        if seconds < 60 { return "עודכן עכשיו" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "עודכן לפני \(minutes) דק׳" }
        let hours = Int(minutes / 60)
        return "עודכן לפני \(hours) ש׳"
    }
}

enum BrainHealthStatus {
    case unknown, checking, online, offline
}

enum BrainServiceError: Error {
    case invalidURL
    case badResponse(status: Int)
    case decodingFailed(underlying: Error)
}

// MARK: - Brain Voice Manager

final class BrainVoiceManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var permissionDenied: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "he-IL"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 1.5
    private var tonePlayer: AVAudioPlayer?

    private func makeToneData(frequency: Double, duration: Double) -> Data {
        let sampleRate: Double = 44100
        let count = Int(sampleRate * duration)
        var bytes = Data()
        // WAV header
        let dataSize = UInt32(count * 2)
        let fileSize = dataSize + 36
        bytes.append(contentsOf: [0x52,0x49,0x46,0x46]) // RIFF
        bytes.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        bytes.append(contentsOf: [0x57,0x41,0x56,0x45]) // WAVE
        bytes.append(contentsOf: [0x66,0x6D,0x74,0x20]) // fmt
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        bytes.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(44100).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(88200).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        bytes.append(contentsOf: [0x64,0x61,0x74,0x61]) // data
        bytes.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        // Sine wave with fade
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let fade = min(1.0, min(t / 0.005, (duration - t) / 0.005))
            let sample = Int16(fade * 12000.0 * sin(2.0 * .pi * frequency * t))
            bytes.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }
        return bytes
    }

    private func playTone(frequency: Double, duration: Double = 0.08) {
        let data = makeToneData(frequency: frequency, duration: duration)
        tonePlayer = try? AVAudioPlayer(data: data)
        tonePlayer?.volume = 0.4
        tonePlayer?.play()
    }

    func requestPermissionAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                switch speechStatus {
                case .authorized:
                    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if granted {
                                self.startRecording()
                            } else {
                                self.permissionDenied = true
                            }
                        }
                    }
                default:
                    self.permissionDenied = true
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stopRecording()
        } else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            transcript = ""
            requestPermissionAndStart()
        }
    }

    private func startRecording() {
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        if #available(iOS 13.0, *), speechRecognizer.supportsOnDeviceRecognition {

            recognitionRequest.requiresOnDeviceRecognition = true

        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.transcript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                    self.cleanupAudio()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            playTone(frequency: 1200, duration: 0.08)
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            cleanupAudio()
        }
    }

    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionRequest?.endAudio()
        cleanupAudio()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isRecording else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.stopRecording()
        }
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }
}

// MARK: - Brain Service

final class BrainService {
    static let shared = BrainService()
    private init() {
        // Register `false` as the fallback for the mock key so unset devices
        // hit the live API by default. The in-app toggle can still flip it on.
        UserDefaults.standard.register(defaults: [Self.mockKey: false])
    }

    // v2 key forces the new default (false → live API) on devices that previously
    // saved `true` under the old "brain.useMockBackend" key. Bumping the suffix
    // is cheaper than writing a one-off migration.
    private static let mockKey = "brain.useMockBackend.v2"

    static var useMockBackend: Bool {
        UserDefaults.standard.bool(forKey: mockKey)
    }

    static func setUseMockBackend(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: mockKey)
    }

    private var useMock: Bool { Self.useMockBackend }

    private let endpoint = URL(string: "https://minis.studio/brain/query")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private let healthURL = URL(string: "https://minis.studio/brain/health")!
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func healthCheck() async throws -> Bool {
        let (_, response) = try await session.data(from: healthURL)
        guard let http = response as? HTTPURLResponse else {
            throw BrainServiceError.badResponse(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BrainServiceError.badResponse(status: http.statusCode)
        }
        return true
    }

    // MARK: UI compatibility

    /// Legacy entry point kept so existing call sites (and previews) keep compiling.
    /// New code should prefer `query(_ request:)` and use the full `BrainQueryResponse`.
    func query(_ question: String) async throws -> BrainCard {
        let request = BrainQueryRequest(
            miniAppId: 0,
            question: question,
            language: "en",
            timezone: TimeZone.current.identifier
        )
        let response = try await query(request)
        return response.card
    }

    // MARK: Backend-ready entry point

    func query(_ request: BrainQueryRequest) async throws -> BrainQueryResponse {
        if useMock {
            return try await mockResponse(for: request)
        }
        return try await liveResponse(for: request)
    }

    // MARK: Mock routing (kept identical to previous behavior, wrapped in BrainQueryResponse)

    private func mockResponse(for request: BrainQueryRequest) async throws -> BrainQueryResponse {
        try await Task.sleep(nanoseconds: UInt64.random(in: 700_000_000...1_000_000_000))

        let q = request.question.lowercased()
        let card: BrainCard
        if q.contains("cashier") || q.contains("staff") {
            card = BrainCard.cashierPerformanceMock
        } else if q.contains("hour") {
            card = BrainCard.hourlySalesMock
        } else if q.contains("wine") || q.contains("jordan") {
            card = BrainCard.jordanWineMock
        } else if q.contains("sale") || q.contains("revenue") || q.contains("best item") {
            card = BrainCard.dailySalesMock
        } else {
            card = BrainCard.dailySalesMock
        }

        let mockSql = "SELECT product_name, SUM(quantity) AS total_qty,\n       SUM(line_total) AS revenue\nFROM order_items\nWHERE shop_id = \(request.miniAppId)\nGROUP BY product_name\nORDER BY total_qty DESC\nLIMIT 50;"
        let mockRows = Int.random(in: 8...64)
        let mockMs = Int.random(in: 80...280)

        return BrainQueryResponse(
            card: card,
            sql: mockSql,
            rowCount: mockRows,
            executionMs: mockMs
        )
    }

    // MARK: Live network call

    private func liveResponse(for request: BrainQueryRequest) async throws -> BrainQueryResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BrainServiceError.badResponse(status: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BrainServiceError.badResponse(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BrainServiceError.badResponse(status: http.statusCode)
        }

        do {
            return try decoder.decode(BrainQueryResponse.self, from: data)
        } catch {
            throw BrainServiceError.decodingFailed(underlying: error)
        }
    }
}

// MARK: - Tesla3

struct Tesla3: View {

    let embedded: Bool
    init(embedded: Bool = false) { self.embedded = embedded }

    @State private var showCreateShopFlow = false
    @State private var showAnalytics = false
    @State private var showCashpoint = false
    @State private var showMenu = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage("dashboard.showSetupFromOnboarding")
    private var showSetupFromOnboarding: Bool = false

    var body: some View {
        Group {
            if embedded {
                content
                    .toolbar(.visible, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
            } else {
                NavigationStack {
                    content
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    private var content: some View {
        ZStack {
            RestaurantAIHomeMock(
                onOpenAnalytics: { showAnalytics = true },
                onOpenMenu: { showMenu = true },
                onOpenCashpoint: { showCashpoint = true },
                onCreateShop: { showCreateShopFlow = true },
                showSetupFromOnboarding: showSetupFromOnboarding,
                onDismissSetup: { showSetupFromOnboarding = false }
            )
            .environment(\.layoutDirection, .rightToLeft)
            .padding(.top, embedded ? 60 : 0)

            NavigationLink(
                destination: AnalyticsV1View().preferredColorScheme(.dark),
                isActive: $showAnalytics
            ) { EmptyView() }
            .hidden()

            NavigationLink(
                destination: menuView()
                            .toolbar(.hidden, for: .navigationBar),
                isActive: $showMenu
            ) { EmptyView() }
            .hidden()

            NavigationLink(
                destination: CashPointView(),
                isActive: $showCashpoint
            ) { EmptyView() }
            .hidden()

            NavigationLink(
                destination: FastlaneOnboardingMock {
                    showCreateShopFlow = false
                }
                    .toolbar(.hidden, for: .navigationBar),
                isActive: $showCreateShopFlow
            ) { EmptyView() }
            .hidden()

            if embedded {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(BrainColors.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.leading, 14)
                    .padding(.top, 10)

                    Spacer()
                }
                .zIndex(9999)
            }
        }
    }
}

// MARK: - Root AI Home

struct RestaurantAIHomeMock: View {

    let onOpenAnalytics: () -> Void
    let onOpenMenu: () -> Void
    let onOpenCashpoint: () -> Void
    let onCreateShop: () -> Void

    let showSetupFromOnboarding: Bool
    let onDismissSetup: () -> Void

    @StateObject private var vm = DashboardVM()

    @State private var shops: [ShopOption] = []
    @State private var selectedShop: ShopOption = .init(id: 12, name: "בית העם")

    @State private var aiText: String = "יין ירדן במרץ?"
    @State private var activeBrainCard: BrainCard?
    @State private var pinnedStates: [PinnedBrainCardState] = []
    @State private var selectedBrainCardForReport: BrainCard?
    @State private var lastBrainQuestion: String = ""
    @State private var pinnedRefreshTimer: Timer?
    @State private var isBrainLoading: Bool = false
    @State private var brainError: Bool = false
    @State private var recentQuestions: [String] = []
    @State private var lastBrainResponse: BrainQueryResponse?
    @AppStorage("brain.useMockBackend.v2") private var useMockBrain = false
    @AppStorage("brain.suggestions.dismissed") private var dismissedChipsRaw: String = ""
    @State private var brainHealthStatus: BrainHealthStatus = .unknown
    @State private var brainHealthMessage: String = ""
    @StateObject private var voice = BrainVoiceManager()

    // Starter suggestion chips — the four reports business owners ask about most.
    // `id` matches the queryKey the API returns so the chip auto-hides once pinned.
    private let starterChips: [BrainSuggestionChip] = [
        BrainSuggestionChip(
            id: "daily_sales:yesterday",
            label: "💰 מכירות אתמול",
            question: "מכירות אתמול"
        ),
        BrainSuggestionChip(
            id: "top_items:yesterday",
            label: "📦 פריטים מאתמול",
            question: "פריטים מאתמול"
        ),
        BrainSuggestionChip(
            id: "top_items:today",
            label: "⭐️ הפריט הכי טוב היום",
            question: "הפריט הכי טוב היום"
        ),
        BrainSuggestionChip(
            id: "hourly_sales:today",
            label: "⏱ מכירות לפי שעה",
            question: "מכירות לפי שעה"
        )
    ]

    private var dismissedChipIds: Set<String> {
        Set(dismissedChipsRaw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    private var visibleStarterChips: [BrainSuggestionChip] {
        let pinnedKeys = Set(pinnedStates.map { $0.queryKey })
        let dismissed = dismissedChipIds
        return starterChips.filter { chip in
            !pinnedKeys.contains(chip.id) && !dismissed.contains(chip.id)
        }
    }

    private func dismissChip(_ chip: BrainSuggestionChip) {
        var ids = dismissedChipIds
        ids.insert(chip.id)
        dismissedChipsRaw = ids.sorted().joined(separator: ",")
    }

    private func tapChip(_ chip: BrainSuggestionChip) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        aiText = chip.question
        submitBrainQuery()
    }

    var body: some View {
        ZStack {
            BrainColors.pageBg
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {

                    ShopTopBar(
                        selectedShop: $selectedShop,
                        shops: shops,
                        onCreateShop: onCreateShop
                    )

                    if showSetupFromOnboarding {
                        SetupMiniCard(
                            onDismiss: onDismissSetup,
                            onMenu: {
                                onDismissSetup()
                                onOpenMenu()
                            },
                            onCashpoint: {
                                onDismissSetup()
                                onOpenCashpoint()
                            }
                        )
                    }

                    LiveHeroHeader(
                        turnover: vm.turnover,
                        orders: vm.orders,
                        aov: vm.aov,
                        cashpointOrders: vm.cashpointOrders,
                        selfOrders: vm.selfOrders
                    )
                    .padding(.top, 8)

                    AskFastlaneCard(
                        text: $aiText,
                        showResult: .init(
                            get: { activeBrainCard != nil },
                            set: { if !$0 { activeBrainCard = nil } }
                        ),
                        recentQuestions: recentQuestions,
                        isRecording: voice.isRecording,
                        onMicTap: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            voice.toggleRecording()
                        },
                        onSubmit: { submitBrainQuery() }
                    )
                    .onChange(of: voice.isRecording) { recording in
                        if recording {
                            aiText = ""
                        }
                    }
                    .onChange(of: voice.transcript) { newValue in
                        if voice.isRecording {
                            aiText = newValue
                        }
                    }
                    .onChange(of: voice.isRecording) { recording in
                        if !recording && !voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            aiText = voice.transcript
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                submitBrainQuery()
                            }
                        }
                    }
                    .alert("נדרשת גישה למיקרופון", isPresented: $voice.permissionDenied) {
                        Button("הגדרות") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        Button("ביטול", role: .cancel) {}
                    } message: {
                        Text("קלט קולי של Brain דורש גישה למיקרופון וזיהוי דיבור. הפעל בהגדרות.")
                    }

                    // Starter suggestion chips — discovery for first-time users.
                    // Auto-hide per chip when pinned or dismissed; whole row hides
                    // while a query is loading or a card is on screen.
                    if !visibleStarterChips.isEmpty
                        && activeBrainCard == nil
                        && !isBrainLoading
                        && !brainError {
                        BrainSuggestionsRow(
                            chips: visibleStarterChips,
                            onTap: { tapChip($0) },
                            onDismiss: { chip in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    dismissChip(chip)
                                }
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if isBrainLoading {
                        BrainThinkingCard()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if brainError {
                        BrainErrorCard(onRetry: { submitBrainQuery() })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let card = activeBrainCard {
                        BrainMetricGraphCard(
                            card: card,
                            response: lastBrainResponse,
                            onPinToggle: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                    togglePin(for: card)
                                }
                            },
                            onOpenReport: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedBrainCardForReport = card
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !pinnedStates.isEmpty {
                        PinnedDashboardSection(
                            states: pinnedStates,
                            onUnpin: { state in
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                    unpinCard(state.card)
                                }
                            },
                            onOpenReport: { state in
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedBrainCardForReport = state.card
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    QuickActionsRow(
                        onMenu: onOpenMenu,
                        onCashpoint: onOpenCashpoint,
                        onAnalytics: onOpenAnalytics
                    )
                    .padding(.top, 2)

                    OperationalPulseCard()
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
        }
        .navigationDestination(isPresented: .init(
            get: { selectedBrainCardForReport != nil },
            set: { if !$0 { selectedBrainCardForReport = nil } }
        )) {
            if let card = selectedBrainCardForReport {
                BrainReportView(card: card)
                    .environment(\.layoutDirection, .rightToLeft)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .onAppear {
            loadPinnedStates()
            loadRecentQuestions()
            checkBrainHealth()
            refreshPinnedBrainCards()
            pinnedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                refreshPinnedBrainCards()
            }

            let loadedOwner = OwnerShopsStore.load()
            let loaded: [ShopOption] = loadedOwner.enumerated().map { idx, s in
                ShopOption(id: 12 + idx, name: s.name)
            }

            if loaded.isEmpty {
                let created = OwnerShopsStore.addShop(name: "בית העם")
                shops = [ShopOption(id: 12, name: created.name)]
                selectedShop = shops[0]
            } else {
                shops = loaded
                selectedShop = loaded.first ?? .init(id: 12, name: "בית העם")
            }

            vm.startPolling(miniAppId: selectedShop.id)
        }
        .onDisappear {
            vm.stopPolling()
            pinnedRefreshTimer?.invalidate()
            pinnedRefreshTimer = nil
        }
    }

    private func togglePin(for card: BrainCard) {
        if let idx = pinnedStates.firstIndex(where: { $0.queryKey == card.queryKey }) {
            pinnedStates.remove(at: idx)
            activeBrainCard?.isPinned = false
        } else {
            guard !pinnedStates.contains(where: { $0.queryKey == card.queryKey }) else { return }
            var pinned = card
            pinned.isPinned = true
            let state = PinnedBrainCardState(
                queryKey: card.queryKey,
                question: lastBrainQuestion.isEmpty ? card.title : lastBrainQuestion,
                card: pinned,
                lastUpdatedAt: Date(),
                lastRefreshFailed: false
            )
            pinnedStates.append(state)
            activeBrainCard?.isPinned = true
        }
        savePinnedStates()
    }

    private func unpinCard(_ card: BrainCard) {
        pinnedStates.removeAll { $0.queryKey == card.queryKey }
        if activeBrainCard?.queryKey == card.queryKey {
            activeBrainCard?.isPinned = false
        }
        savePinnedStates()
    }

    private static let pinnedStatesKey = "brain.pinned.states"
    private static let legacyPinnedCardsKey = "brain.pinned.cards"

    private func savePinnedStates() {
        guard let data = try? JSONEncoder().encode(pinnedStates) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinnedStatesKey)
    }

    private func loadPinnedStates() {
        if let data = UserDefaults.standard.data(forKey: Self.pinnedStatesKey),
           let states = try? JSONDecoder().decode([PinnedBrainCardState].self, from: data) {
            var seen = Set<String>()
            pinnedStates = states.filter { seen.insert($0.queryKey).inserted }
            return
        }
        // Migrate legacy [BrainCard] format
        if let data = UserDefaults.standard.data(forKey: Self.legacyPinnedCardsKey),
           let cards = try? JSONDecoder().decode([BrainCard].self, from: data) {
            var seen = Set<String>()
            pinnedStates = cards
                .filter { seen.insert($0.queryKey).inserted }
                .map { card in
                    var c = card
                    c.isPinned = true
                    return PinnedBrainCardState(
                        queryKey: c.queryKey,
                        question: c.title,
                        card: c,
                        lastUpdatedAt: .distantPast,
                        lastRefreshFailed: false
                    )
                }
            savePinnedStates()
            UserDefaults.standard.removeObject(forKey: Self.legacyPinnedCardsKey)
        }
    }

    private func refreshPinnedBrainCards() {
        guard !pinnedStates.isEmpty else { return }
        let shopId = selectedShop.id
        for i in pinnedStates.indices {
            let state = pinnedStates[i]
            Task {
                let request = BrainQueryRequest(
                    miniAppId: shopId,
                    question: state.question,
                    language: "en",
                    timezone: TimeZone.current.identifier
                )
                do {
                    let response = try await BrainService.shared.query(request)
                    BrainDebugLog.append(question: state.question, response: response)
                    await MainActor.run {
                        guard let idx = pinnedStates.firstIndex(where: { $0.queryKey == state.queryKey }) else { return }
                        var updated = response.card
                        updated.isPinned = true
                        pinnedStates[idx].card = updated
                        pinnedStates[idx].lastUpdatedAt = Date()
                        pinnedStates[idx].lastRefreshFailed = false
                        savePinnedStates()
                    }
                } catch {
                    await MainActor.run {
                        guard let idx = pinnedStates.firstIndex(where: { $0.queryKey == state.queryKey }) else { return }
                        pinnedStates[idx].lastRefreshFailed = true
                    }
                }
            }
        }
    }

    private static let recentQuestionsKey = "brain.recent.questions"

    private func saveRecentQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentQuestions.filter {

            $0.trimmingCharacters(in: .whitespacesAndNewlines)

                .caseInsensitiveCompare(trimmed) != .orderedSame

        }
        list.insert(trimmed, at: 0)
        if list.count > 5 { list = Array(list.prefix(5)) }
        recentQuestions = list
        UserDefaults.standard.set(list, forKey: Self.recentQuestionsKey)
    }

    private func loadRecentQuestions() {
        recentQuestions = (UserDefaults.standard.stringArray(forKey: Self.recentQuestionsKey) ?? [])
            .prefix(5)
            .map { $0 }
    }
    

    private func checkBrainHealth() {
        if useMockBrain {
            brainHealthStatus = .unknown
            brainHealthMessage = "מצב דמו"
            return
        }
        brainHealthStatus = .checking
        brainHealthMessage = "בודק שרת\u{2026}"
        Task {
            do {
                let _ = try await BrainService.shared.healthCheck()
                await MainActor.run {
                    brainHealthStatus = .online
                    brainHealthMessage = "שרת מחובר"
                }
            } catch {
                await MainActor.run {
                    brainHealthStatus = .offline
                    brainHealthMessage = "שרת מנותק"
                }
            }
        }
    }

    private func submitBrainQuery() {
        let question = aiText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBrainLoading else { return }
        lastBrainQuestion = question

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lastBrainResponse = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            activeBrainCard = nil
            brainError = false
            isBrainLoading = true
        }

        let request = BrainQueryRequest(
            miniAppId: selectedShop.id,
            question: question,
            language: "en",
            timezone: TimeZone.current.identifier
        )

        Task {
            do {
                let response = try await BrainService.shared.query(request)
                BrainDebugLog.append(question: question, response: response)

                // Always show the live response. Preserve only the user's pin flag,
                // and refresh the pinned cache with the fresh data so future reloads
                // don't fall back to stale numbers.
                var card = response.card
                let pinnedIdx = pinnedStates.firstIndex(where: { $0.queryKey == card.queryKey })
                if pinnedIdx != nil {
                    card.isPinned = true
                }

                await MainActor.run {
                    saveRecentQuestion(question)
                    lastBrainResponse = response
                    if let idx = pinnedIdx {
                        pinnedStates[idx].card = card
                        pinnedStates[idx].lastUpdatedAt = Date()
                        pinnedStates[idx].lastRefreshFailed = false
                        savePinnedStates()
                    }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        isBrainLoading = false
                        activeBrainCard = card
                    }
                }
            } catch {
                // Any failure (invalid URL, bad response, decoding) surfaces the existing BrainErrorCard.
                await MainActor.run {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        isBrainLoading = false
                        brainError = true
                    }
                }
            }
        }
    }
}

// MARK: - Live Hero

private struct LiveHeroHeader: View {
    let turnover: Int
    let orders: Int
    let aov: Double
    let cashpointOrders: Int
    let selfOrders: Int

    private var metaLine: String {
        let aovInt = Int(aov.rounded(.toNearestOrAwayFromZero))
        let oph = ordersPerHourSince8amIsrael(orders: orders)
        return "\(orders) הזמנות \u{00B7} \u{20AA}\(aovInt) ממוצע \u{00B7} \(String(format: "%.0f", oph))/שעה"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)

                Text("לייב היום")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(BrainColors.textTertiary)
            }

            Text(turnover, format: .number)
                .font(.system(size: 68, weight: .regular, design: .rounded))
                .monospacedDigit()
                .tracking(-1.1)
                .foregroundStyle(BrainColors.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: turnover)

            Text(metaLine)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(BrainColors.textSecondary)

            if orders > 0 {
                let selfPct = Int((Double(selfOrders) / Double(orders) * 100).rounded())

                HStack(alignment: .bottom, spacing: 8) {
                    Text("\(selfPct)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.accent)

                    Text("שירות עצמי")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(BrainColors.textSecondary)
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ask Brain

private struct AskFastlaneCard: View {
    @Binding var text: String
    @Binding var showResult: Bool

    let recentQuestions: [String]
    var isRecording: Bool = false
    var onMicTap: () -> Void = {}
    let onSubmit: () -> Void

    @State private var micPulse = false

    private let suggestions = [
        "הפריט הכי טוב היום",
        "מכירות לפי שעה",
        "יין במרץ"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack {
                Text("שאל את בריין")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(BrainColors.textTertiary)

                Spacer()

                if isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .opacity(micPulse ? 0.4 : 1.0)
                        Text("מקשיב")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.red.opacity(0.9))
                    }
                } else {
                    Text("BRAIN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(BrainColors.invertedText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(BrainColors.invertedBg)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {

                Button(action: onMicTap) {
                    ZStack {
                        if isRecording {
                            Circle()
                                .fill(.red.opacity(0.15))
                                .frame(width: 58, height: 58)
                                .scaleEffect(micPulse ? 1.2 : 1.0)
                                .opacity(micPulse ? 0.0 : 0.5)

                            Circle()
                                .fill(.red.opacity(0.10))
                                .frame(width: 52, height: 52)
                                .scaleEffect(micPulse ? 1.1 : 1.0)
                                .opacity(micPulse ? 0.0 : 0.4)
                        }

                        Circle()
                            .fill(isRecording ? .red.opacity(0.25) : BrainColors.subtleFill)

                        Circle()
                            .stroke(isRecording ? .red.opacity(0.5) : BrainColors.subtleStroke, lineWidth: 1)

                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: isRecording ? 14 : 17, weight: .semibold))
                            .foregroundStyle(isRecording ? .red : BrainColors.textPrimary)
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)

                TextField(isRecording ? "מקשיב\u{2026}" : "שאל את Brain כל דבר\u{2026}", text: $text)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textPrimary)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .disabled(isRecording)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .frame(maxWidth: .infinity)
                    .background(BrainColors.subtleFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isRecording ? .red.opacity(0.25) : BrainColors.subtleStroke, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BrainColors.invertedText)
                        .frame(width: 44, height: 44)
                        .background(BrainColors.invertedBg)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isRecording)
                .opacity(isRecording ? 0.4 : 1.0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            text = suggestion == "יין במרץ"
                            ? "כמה יינות ג׳ורדן נמכרו במרץ?"
                            : suggestion

                            onSubmit()
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(BrainColors.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(BrainColors.subtleFill)
                                .overlay(
                                    Capsule()
                                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !recentQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BrainColors.textQuaternary)

                        Text("אחרונים")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(BrainColors.textQuaternary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentQuestions, id: \.self) { question in
                                Button {
                                    text = question
                                    onSubmit()
                                } label: {
                                    Text(question)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(BrainColors.textTertiary)
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(BrainColors.subtleFill)
                                        .overlay(
                                            Capsule()
                                                .stroke(BrainColors.subtleStroke, lineWidth: 1)
                                        )
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isRecording)
        .onChange(of: isRecording) { recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    micPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    micPulse = false
                }
            }
        }
    }
}

// MARK: - Brain Loading Card

private struct BrainThinkingCard: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(BrainColors.textPrimary.opacity(pulse ? 0.30 : 0.10))
                    .frame(width: 10, height: 10)

                Text("Brain חושב\u{2026}")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BrainColors.textPrimary.opacity(pulse ? 0.10 : 0.05))
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(BrainColors.textPrimary.opacity(pulse ? 0.09 : 0.04))
                            .frame(height: 36)
                    }
                }

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrainColors.textPrimary.opacity(pulse ? 0.07 : 0.03))
                    .frame(height: 100)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Brain Health Dot

private struct BrainHealthDot: View {
    let status: BrainHealthStatus
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .unknown:  return .orange
        case .checking: return .gray
        case .online:   return .green
        case .offline:  return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(status == .checking ? (pulse ? 0.3 : 1.0) : 1.0)
            .animation(
                status == .checking
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: status) { newValue in
                pulse = newValue == .checking
            }
            .onAppear { pulse = status == .checking }
    }
}

// MARK: - Brain Suggestion Chips
//
// Starter prompts shown above the active card on first-time / empty state.
// Tap to populate the input and submit. Each chip auto-hides once its
// queryKey is pinned (so we don't suggest what's already on the dashboard)
// or when the user explicitly dismisses it via the "×".

private struct BrainSuggestionChip: Identifiable, Hashable {
    let id: String          // matches the queryKey returned by the API
    let label: String       // visible chip text (with emoji)
    let question: String    // the question text that gets submitted
}

private struct BrainSuggestionsRow: View {
    let chips: [BrainSuggestionChip]
    let onTap: (BrainSuggestionChip) -> Void
    let onDismiss: (BrainSuggestionChip) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Spacer()
                Text("נסה לשאול")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(BrainColors.textQuaternary)
                    .padding(.trailing, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        BrainSuggestionChipView(
                            chip: chip,
                            onTap: { onTap(chip) },
                            onDismiss: { onDismiss(chip) }
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

private struct BrainSuggestionChipView: View {
    let chip: BrainSuggestionChip
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                Text(chip.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(BrainColors.textPrimary)
                    .padding(.leading, 14)
                    .padding(.vertical, 9)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(BrainColors.textQuaternary)
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(BrainColors.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .stroke(BrainColors.cardStroke, lineWidth: 0.5)
        )
    }
}


// MARK: - Brain Card Breakdown
//
// Compact list of breakdown rows shown inline on the active card. Reveals up
// to 5 rows; if more exist we tail with "+N נוספים" so the user knows the full
// list lives in the report view.

private struct BrainCardBreakdown: View {
    let rows: [BrainBreakdownRow]
    var tableLayout: Bool = false        // top-items => 4-column aligned table
    private let visibleLimit = 5

    private var visibleRows: ArraySlice<BrainBreakdownRow> {
        rows.prefix(visibleLimit)
    }
    private var overflowCount: Int {
        max(0, rows.count - visibleLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
                .padding(.bottom, 8)

            if tableLayout {
                // Column header strip
                HStack(spacing: 8) {
                    Text("פריט")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("כמות")
                        .frame(width: 56, alignment: .trailing)
                    Text("הכנסה")
                        .frame(width: 76, alignment: .trailing)
                    Text("חלק")
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textQuaternary)
                .padding(.bottom, 4)
            }

            ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                if tableLayout {
                    let cells = parseTableRow(row.value)
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(BrainColors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(cells.qty)
                            .frame(width: 56, alignment: .trailing)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BrainColors.textSecondary)

                        Text(cells.revenue)
                            .frame(width: 76, alignment: .trailing)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BrainColors.textPrimary)

                        Text(cells.share)
                            .frame(width: 40, alignment: .trailing)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BrainColors.textTertiary)
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 10) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(BrainColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        Text(row.value)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BrainColors.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 5)
                }
            }

            if overflowCount > 0 {
                HStack {
                    Text("+\(overflowCount) נוספים")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(BrainColors.textTertiary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    /// Splits "215 יח׳ · ₪3,239 · 22%" into the three columns. Falls back
    /// gracefully if separators aren\'t present.
    private func parseTableRow(_ value: String) -> (qty: String, revenue: String, share: String) {
        let parts = value.components(separatedBy: " · ")
        if parts.count == 3 {
            return (qty: parts[0], revenue: parts[1], share: parts[2])
        }
        return (qty: value, revenue: "", share: "")
    }
}

// MARK: - Brain Error Card

private struct BrainErrorCard: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(BrainColors.textQuaternary)

            Text("Brain לא הצליח להשלים את השאילתה.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textTertiary)
                .multilineTextAlignment(.center)

            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))

                    Text("נסה שוב")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(BrainColors.textPrimary)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(BrainColors.subtleFill)
                .overlay(
                    Capsule()
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
    }
}

// MARK: - Brain Metric Graph Card (generic)

private struct BrainMetricGraphCard: View {

    let card: BrainCard
    var response: BrainQueryResponse? = nil
    let onPinToggle: () -> Void
    let onOpenReport: () -> Void

    // Card stays minimal (header + primary + metrics). Tap anywhere on the body
    // pushes to BrainReportView (the D/W/M tab view with breakdown rows).
    // Pin button + small debug button sit in the header — they have their own
    // Button hit areas and don't trigger the navigation tap.
    @State private var showDebugSheet = false

    private var isTopItemsReport: Bool {
        card.queryKey.hasPrefix("top_items")
    }

    /// Top-items cards show "פריטים · <period>" instead of "פריט מוביל · <period>".
    /// We extract the period from the server-provided title rather than hardcode it,
    /// so any future range labels (week / month / specific weekday / Hebrew month
    /// names) flow through automatically.
    private var displayTitle: String {
        if isTopItemsReport,
           let separator = card.title.range(of: " · ") {
            let period = card.title[separator.upperBound...]
            return "פריטים · \(period)"
        }
        return card.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)

                    if !isTopItemsReport {
                        Text(card.subtitle)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(BrainColors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let sql = response?.sql, !sql.isEmpty {
                    Button { showDebugSheet = true } label: {
                        Image(systemName: "ladybug")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrainColors.textTertiary)
                            .frame(width: 30, height: 30)
                            .background(BrainColors.subtleFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onPinToggle) {
                    Image(systemName: card.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(card.isPinned ? BrainColors.invertedText : BrainColors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(card.isPinned ? BrainColors.invertedBg : BrainColors.subtleFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Hide the giant primary value when this is a top-items card —
            // row #1 of the table below already shows the leader.
            if !isTopItemsReport {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.primaryValue)
                        .font(.system(size: 30, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.textPrimary)

                    Text(card.primaryLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textTertiary)
                }
            }

            if !isTopItemsReport {
                HStack(spacing: 14) {
                    ForEach(card.metrics) { metric in
                        ResultMiniMetric(title: metric.title, value: metric.value)
                    }
                }
            }

            // Inline breakdown — only when the API returned 2+ breakdown rows
            // (aggregate product query, top items, hourly distribution, etc.).
            // Single-product cards have empty breakdownRows so this is hidden.
            if let firstPeriod = card.periods.first,
               firstPeriod.breakdownRows.count >= 2 {
                BrainCardBreakdown(
                    rows: firstPeriod.breakdownRows,
                    tableLayout: isTopItemsReport
                )
                .padding(.top, 4)
            }

            HStack(spacing: 6) {
                Spacer()
                Text("פתח דוח מלא")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(BrainColors.textQuaternary)
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BrainColors.textQuaternary)
            }
            .padding(.top, 2)
        }
        .padding(15)
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onOpenReport()
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
        .sheet(isPresented: $showDebugSheet) {
            if let r = response {
                BrainDebugSheet(response: r)
            }
        }
    }
}

// MARK: - Brain Debug Sheet (dev only)

private struct BrainDebugSheet: View {
    let response: BrainQueryResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            BrainColors.pageBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("דיבאג Brain")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(BrainColors.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(BrainColors.subtleFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                if let sql = response.sql {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SQL")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(BrainColors.textQuaternary)

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(sql)
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .foregroundStyle(BrainColors.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(BrainColors.cardFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                                )
                        )
                    }
                }

                HStack(spacing: 24) {
                    if let rows = response.rowCount {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("שורות")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .tracking(1.0)
                                .foregroundStyle(BrainColors.textQuaternary)

                            Text("\(rows)")
                                .font(.system(size: 22, weight: .regular, design: .monospaced))
                                .foregroundStyle(BrainColors.textPrimary)
                        }
                    }

                    if let ms = response.executionMs {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("זמן ריצה")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .tracking(1.0)
                                .foregroundStyle(BrainColors.textQuaternary)

                            Text("\(ms)ms")
                                .font(.system(size: 22, weight: .regular, design: .monospaced))
                                .foregroundStyle(BrainColors.textPrimary)
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Brain Report View (generic)
//
// Mockup-first design: D / W / M / Y type picker + period navigator (← label →)
// + calendar icon for custom range. Mock data is generated on the fly for any
// period that's not the card's real current "D" data. When we wire to the API
// in Phase 2, only the data source changes — the UI stays the same.

private enum BrainPeriodType: String, CaseIterable, Identifiable {
    case D, W, M, Y
    var id: String { rawValue }

    var hebrewShort: String {
        switch self {
        case .D: return "יום"
        case .W: return "שבוע"
        case .M: return "חודש"
        case .Y: return "שנה"
        }
    }
}

private struct BrainReportView: View {
    let card: BrainCard

    @Environment(\.dismiss) private var dismiss
    @State private var periodType: BrainPeriodType = .D
    @State private var periodOffset: Int = 0  // 0 = current, -1 = previous, etc.
    @State private var showCustomRange = false
    @State private var breakdownExpanded = false   // top-10 by default; "הצג עוד" reveals all

    private var isTopItemsReport: Bool {
        let result = card.queryKey.hasPrefix("top_items")
        // Debug: confirm what queryKey + isTopItemsReport actually evaluate to
        // when the report view opens. Remove this print once verified.
        print("🧠 BrainReport ▶︎ queryKey='\(card.queryKey)' isTopItemsReport=\(result)")
        return result
    }
    @State private var customStart: Date? = nil
    @State private var customEnd: Date? = nil
    @State private var isCustomActive = false

    private var displayPeriod: BrainReportPeriod {
        BrainPeriodMockGenerator.generate(card: card, type: periodType, offset: periodOffset)
    }

    private var periodLabel: String {
        if isCustomActive, let s = customStart, let e = customEnd {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he")
            f.dateFormat = "d MMM"
            return "\(f.string(from: s)) – \(f.string(from: e))"
        }
        return BrainPeriodLabels.label(type: periodType, offset: periodOffset)
    }

    var body: some View {
        ZStack {
            BrainColors.pageBg
                .ignoresSafeArea()

            // Invisible UIKit bridge — re-enables interactivePopGestureRecognizer
            // so edge-swipe-back works even with the toolbar hidden.
            EnableSwipeBack()
                .frame(width: 0, height: 0)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    topBar
                    periodTypePicker
                    periodNavigator
                    periodCard(period: displayPeriod)
                    if !displayPeriod.breakdownRows.isEmpty {
                        if isTopItemsReport {
                            topItemsBreakdown(rows: displayPeriod.breakdownRows)
                        } else {
                            reportBreakdown(rows: displayPeriod.breakdownRows)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showCustomRange) {
            DateRangePickerSheet(
                initialStart: customStart,
                initialEnd: customEnd
            ) { start, end in
                customStart = start
                customEnd = end
                isCustomActive = true
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    // MARK: Subviews

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrainColors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(card.reportTitle.isEmpty ? card.title : card.reportTitle)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrainColors.textTertiary)
                .frame(width: 44, height: 44)
        }
    }

    private var periodTypePicker: some View {
        HStack(spacing: 6) {
            ForEach(BrainPeriodType.allCases) { type in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        periodType = type
                        periodOffset = 0
                        isCustomActive = false
                    }
                } label: {
                    let isActive = !isCustomActive && periodType == type
                    Text(type.hebrewShort)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActive ? BrainColors.invertedText : BrainColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(isActive ? BrainColors.invertedBg : BrainColors.subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrainColors.cardStroke, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showCustomRange = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isCustomActive ? BrainColors.invertedText : BrainColors.textSecondary)
                    .frame(width: 44, height: 36)
                    .background(isCustomActive ? BrainColors.invertedBg : BrainColors.subtleFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(BrainColors.cardStroke, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var periodNavigator: some View {
        HStack(spacing: 12) {
            // → back in time (older). In Hebrew RTL, the "back" arrow visually
            // points right; in our LTR Image space we use chevron.right to feel natural.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    periodOffset -= 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrainColors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(BrainColors.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(periodLabel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            // ← forward in time (newer, capped at offset 0)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    periodOffset = min(periodOffset + 1, 0)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(periodOffset < 0 ? BrainColors.textSecondary : BrainColors.textQuaternary)
                    .frame(width: 36, height: 36)
                    .background(BrainColors.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(periodOffset >= 0)
            .opacity(periodOffset >= 0 ? 0.45 : 1)
        }
    }

    private func periodCard(period: BrainReportPeriod) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top-items reports don't need the giant headline — row #1 of the
            // table below already shows the leader. Hide it for that intent.
            if !isTopItemsReport {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(period.primaryValue)
                        .font(.system(size: 54, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.textPrimary)

                    Text(period.primaryLabel)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textTertiary)
                }
            }

            HStack(spacing: 16) {
                ForEach(period.metrics) { metric in
                    ResultMiniMetric(title: metric.title, value: metric.value)
                }
            }

            MockLineGraph(values: period.graphValues.map { CGFloat($0) })
                .frame(height: 190)
                .padding(.top, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
        // Swipe to navigate periods. RIGHT = back in time, LEFT = forward (capped).
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { gesture in
                    let threshold: CGFloat = 50
                    if gesture.translation.width > threshold {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            periodOffset -= 1
                        }
                    } else if gesture.translation.width < -threshold {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            periodOffset = min(periodOffset + 1, 0)
                        }
                    }
                }
        )
    }

    private func reportBreakdown(rows: [BrainBreakdownRow]) -> some View {
        // Top 10 visible by default; "הצג עוד" reveals all (server returns up to 30).
        let visibleLimit = 10
        let showAll = breakdownExpanded || rows.count <= visibleLimit
        let visible = showAll ? Array(rows) : Array(rows.prefix(visibleLimit))
        let overflow = max(0, rows.count - visibleLimit)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("פירוט")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textPrimary)

                Spacer()

                Text("\(rows.count) פריטים")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(BrainColors.textTertiary)
            }

            ForEach(visible) { row in
                ReportRow(title: row.title, value: row.value)
            }

            if !showAll && overflow > 0 {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        breakdownExpanded = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Text("הצג עוד \(overflow) נוספים")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(BrainColors.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrainColors.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .background(BrainColors.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else if showAll && rows.count > visibleLimit {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        breakdownExpanded = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Text("הצג פחות")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(BrainColors.textTertiary)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrainColors.textTertiary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
    }

    // ---- Top-items table layout ----
    //
    // The server packs three values into BrainBreakdownRow.value with " · " as
    // a separator: "<qty> יח׳ · ₪<revenue> · <share>%". We split that here and
    // render each cell into its own right-aligned column so values line up
    // visually when the eye scans down the list.

    private func topItemsBreakdown(rows: [BrainBreakdownRow]) -> some View {
        let visibleLimit = 10
        let showAll = breakdownExpanded || rows.count <= visibleLimit
        let visible = showAll ? Array(rows) : Array(rows.prefix(visibleLimit))
        let overflow = max(0, rows.count - visibleLimit)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("פריטים מובילים")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textPrimary)
                Spacer()
                Text("\(rows.count) פריטים")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(BrainColors.textTertiary)
            }

            // Column headers
            HStack(spacing: 8) {
                Text("פריט")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("כמות")
                    .frame(width: 64, alignment: .trailing)
                Text("הכנסה")
                    .frame(width: 84, alignment: .trailing)
                Text("חלק")
                    .frame(width: 48, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(BrainColors.textTertiary)
            .padding(.top, 2)

            // Subtle divider
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            // Data rows
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                let cells = parseTopItemsRow(row.value)
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(cells.qty)
                        .frame(width: 64, alignment: .trailing)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.textSecondary)

                    Text(cells.revenue)
                        .frame(width: 84, alignment: .trailing)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.textPrimary)

                    Text(cells.share)
                        .frame(width: 48, alignment: .trailing)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BrainColors.textTertiary)
                }
                .padding(.vertical, 4)
            }

            if !showAll && overflow > 0 {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        breakdownExpanded = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Text("הצג עוד \(overflow) נוספים")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(BrainColors.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrainColors.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .background(BrainColors.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else if showAll && rows.count > visibleLimit {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        breakdownExpanded = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Text("הצג פחות")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(BrainColors.textTertiary)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrainColors.textTertiary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
    }

    /// Splits "215 יח׳ · ₪3,239 · 22%" into the three columns. Falls back to
    /// the whole string in the qty column if the separator isn't present.
    private func parseTopItemsRow(_ value: String) -> (qty: String, revenue: String, share: String) {
        let parts = value.components(separatedBy: " · ")
        if parts.count == 3 {
            return (qty: parts[0], revenue: parts[1], share: parts[2])
        }
        return (qty: value, revenue: "", share: "")
    }
}

// MARK: - Period mock data + labels

private enum BrainPeriodMockGenerator {
    /// Build a period for the requested type/offset based on the card's headline data.
    /// For (.D, offset 0) we re-use the card's real "D" period from the API if present.
    static func generate(card: BrainCard, type: BrainPeriodType, offset: Int) -> BrainReportPeriod {
        if type == .D, offset == 0,
           let real = card.periods.first(where: { $0.id == "D" }) {
            return real
        }

        let baseValue = parsePrimaryNumber(card.primaryValue)
        let scale = scaleFactor(type: type, offset: offset)
        let mockValue = max(Int(Double(baseValue) * scale), 0)

        return BrainReportPeriod(
            id: type.rawValue,
            label: type.hebrewShort,
            primaryValue: formatLikeOriginal(mockValue, original: card.primaryValue),
            primaryLabel: card.primaryLabel,
            metrics: scaleMetrics(card.metrics, scale: scale),
            graphValues: generateGraph(type: type, peak: max(Double(mockValue), 1)),
            breakdownRows: generateBreakdown(type: type)
        )
    }

    // ---- helpers ----

    private static func scaleFactor(type: BrainPeriodType, offset: Int) -> Double {
        let typeMultiplier: Double = {
            switch type {
            case .D: return 1.0
            case .W: return 6.4
            case .M: return 27.3
            case .Y: return 312.0
            }
        }()
        let drift = pow(0.93, Double(abs(offset)))   // older periods slightly less
        return typeMultiplier * drift
    }

    private static func parsePrimaryNumber(_ s: String) -> Int {
        let digits = s.compactMap { $0.isNumber ? $0 : nil }
        return Int(String(digits)) ?? 0
    }

    private static func formatLikeOriginal(_ value: Int, original: String) -> String {
        if original.contains("₪") {
            return "₪" + value.formatted(.number)
        }
        // For things like "13:00" (peak hour) we don't scale — keep as-is.
        if original.contains(":") {
            return original
        }
        return value.formatted(.number)
    }

    private static func scaleMetrics(_ metrics: [BrainMetric], scale: Double) -> [BrainMetric] {
        metrics.map { metric in
            let digits = metric.value.compactMap { $0.isNumber ? $0 : nil }
            guard let n = Int(String(digits)) else { return metric }
            let scaled = max(Int(Double(n) * scale), 0)

            if metric.value.contains("₪") {
                return BrainMetric(title: metric.title, value: "₪" + scaled.formatted(.number))
            }
            if metric.value.contains(":") {
                return metric
            }
            return BrainMetric(title: metric.title, value: scaled.formatted(.number))
        }
    }

    private static func generateGraph(type: BrainPeriodType, peak: Double) -> [Double] {
        let count: Int = {
            switch type {
            case .D: return 24
            case .W: return 7
            case .M: return 30
            case .Y: return 12
            }
        }()

        let center = Double(count) / 2.0
        return (0..<count).map { i in
            let dx = (Double(i) - center) / center
            let bell = max(1.0 - dx * dx, 0.0)
            let noise = Double.random(in: 0.75...1.15)
            return peak * bell * noise / Double(count) * 4.0
        }
    }

    private static func generateBreakdown(type: BrainPeriodType) -> [BrainBreakdownRow] {
        switch type {
        case .D:
            return [
                BrainBreakdownRow(title: "שעה הכי טובה", value: "13:00"),
                BrainBreakdownRow(title: "פריט מוביל", value: "הפוך"),
                BrainBreakdownRow(title: "קופאי מוביל", value: "דנה")
            ]
        case .W:
            return [
                BrainBreakdownRow(title: "יום הכי טוב", value: "שישי"),
                BrainBreakdownRow(title: "שעה הכי טובה", value: "13:00"),
                BrainBreakdownRow(title: "פריט מוביל", value: "הפוך")
            ]
        case .M:
            return [
                BrainBreakdownRow(title: "שבוע הכי טוב", value: "שבוע 3"),
                BrainBreakdownRow(title: "יום הכי טוב", value: "שישי 21"),
                BrainBreakdownRow(title: "פריט מוביל", value: "הפוך")
            ]
        case .Y:
            return [
                BrainBreakdownRow(title: "חודש הכי טוב", value: "אוגוסט"),
                BrainBreakdownRow(title: "רבעון הכי טוב", value: "Q3"),
                BrainBreakdownRow(title: "פריט מוביל", value: "הפוך")
            ]
        }
    }
}

private enum BrainPeriodLabels {
    static func label(type: BrainPeriodType, offset: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "he_IL")

        switch type {
        case .D:
            switch offset {
            case 0: return "היום"
            case -1: return "אתמול"
            case -2: return "שלשום"
            default:
                let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
                formatter.dateFormat = "EEEE, d MMMM"
                return formatter.string(from: date)
            }
        case .W:
            switch offset {
            case 0: return "השבוע"
            case -1: return "שבוע שעבר"
            default: return "לפני \(-offset) שבועות"
            }
        case .M:
            let date = calendar.date(byAdding: .month, value: offset, to: now) ?? now
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        case .Y:
            let date = calendar.date(byAdding: .year, value: offset, to: now) ?? now
            formatter.dateFormat = "yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Date Range Picker Sheet (Airbnb-style)

private struct DateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: Date?
    let initialEnd: Date?
    let onApply: (Date, Date) -> Void

    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil
    @State private var displayedMonth: Date = Date()

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "he")
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return c
    }()

    private let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private let chipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he")
        f.dateFormat = "d MMM"
        return f
    }()

    private var canApply: Bool {
        startDate != nil && endDate != nil
    }

    var body: some View {
        ZStack {
            BrainColors.pageBg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                selectedChips
                    .padding(.top, 12)
                monthNavigator
                    .padding(.top, 16)
                weekdayHeaders
                    .padding(.top, 8)
                calendarGrid
                    .padding(.top, 4)
                Spacer()
                applyButton
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            startDate = initialStart
            endDate = initialEnd
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("בחר טווח תאריכים")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BrainColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(BrainColors.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Selected Dates Chips

    private var selectedChips: some View {
        HStack(spacing: 12) {
            dateChip(label: "מתאריך", date: startDate)
            Image(systemName: "arrow.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BrainColors.textQuaternary)
            dateChip(label: "עד תאריך", date: endDate)
        }
    }

    private func dateChip(label: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textQuaternary)
            Text(date.map { chipFormatter.string(from: $0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(date != nil ? BrainColors.textPrimary : BrainColors.textQuaternary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BrainColors.cardFill)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrainColors.cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Month Navigator

    private var monthNavigator: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrainColors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(BrainColors.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(headerFormatter.string(from: displayedMonth))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrainColors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(BrainColors.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Weekday Headers

    private var weekdayHeaders: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { day in
                Text(day)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textQuaternary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let days = daysInMonth()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(days, id: \.self) { day in
                if let day {
                    let isStart = isSameDay(day, startDate)
                    let isEnd = isSameDay(day, endDate)
                    let isInRange = isInSelectedRange(day)
                    let isToday = calendar.isDateInToday(day)
                    let isFuture = day > Date()

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        handleDayTap(day)
                    } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 15, weight: (isStart || isEnd) ? .bold : .regular, design: .rounded))
                            .foregroundStyle(
                                isFuture ? BrainColors.textQuaternary :
                                (isStart || isEnd) ? BrainColors.invertedText :
                                isToday ? BrainColors.accent :
                                BrainColors.textPrimary
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                Group {
                                    if isStart || isEnd {
                                        Circle().fill(BrainColors.accent)
                                    } else if isInRange {
                                        Rectangle().fill(BrainColors.accent.opacity(0.12))
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isFuture)
                } else {
                    Color.clear.frame(height: 42)
                }
            }
        }
    }

    // MARK: - Apply Button

    private var applyButton: some View {
        Button {
            guard let s = startDate, let e = endDate else { return }
            onApply(s, e)
            dismiss()
        } label: {
            Text("החל טווח")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(canApply ? BrainColors.invertedText : BrainColors.textQuaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(canApply ? BrainColors.invertedBg : BrainColors.subtleFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
    }

    // MARK: - Logic

    private func handleDayTap(_ day: Date) {
        if startDate == nil || (startDate != nil && endDate != nil) {
            startDate = day
            endDate = nil
        } else if let start = startDate {
            if day < start {
                startDate = day
            } else {
                endDate = day
            }
        }
    }

    private func isSameDay(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return calendar.isDate(a, inSameDayAs: b)
    }

    private func isInSelectedRange(_ day: Date) -> Bool {
        guard let s = startDate, let e = endDate else { return false }
        return day > s && day < e
    }

    private func daysInMonth() -> [Date?] {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return [] }

        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            var dc = comps
            dc.day = day
            days.append(calendar.date(from: dc))
        }
        return days
    }
}


// MARK: - Edge-swipe back enabler
//
// SwiftUI's `.toolbar(.hidden, for: .navigationBar)` also disables the system's
// `interactivePopGestureRecognizer`. This invisible host view walks up to the
// `UINavigationController` and re-enables it so users can still swipe-from-edge
// to dismiss BrainReportView.

private struct EnableSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let nav = uiViewController.navigationController
                ?? uiViewController.parent?.navigationController else { return }
            nav.interactivePopGestureRecognizer?.delegate = nil
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

private struct ReportRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textTertiary)

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Pinned Dashboard (generic)

private struct PinnedDashboardSection: View {
    let states: [PinnedBrainCardState]
    let onUnpin: (PinnedBrainCardState) -> Void
    let onOpenReport: (PinnedBrainCardState) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Text("מוצמדים")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(BrainColors.textTertiary)

                Spacer()

                Text("רענון אוטומטי")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textQuaternary)
            }

            ForEach(states) { state in
                PinnedMiniCard(
                    state: state,
                    onUnpin: { onUnpin(state) },
                    onOpenReport: { onOpenReport(state) }
                )
            }
        }
    }
}

private struct PinnedMiniCard: View {
    let state: PinnedBrainCardState
    let onUnpin: () -> Void
    let onOpenReport: () -> Void

    private var card: BrainCard { state.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.lastRefreshFailed ? .red : .green)
                            .frame(width: 5, height: 5)

                        Text(state.timeAgoLabel)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(state.lastRefreshFailed ? BrainColors.textTertiary : BrainColors.textQuaternary)
                    }
                }

                Spacer()

                Button(action: onUnpin) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrainColors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(BrainColors.subtleFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.primaryValue)
                    .font(.system(size: 30, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BrainColors.textPrimary)

                Text(card.primaryLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrainColors.textTertiary)
            }

            HStack(spacing: 14) {
                ForEach(card.metrics) { metric in
                    ResultMiniMetric(title: metric.title, value: metric.value)
                }
            }
        }
        .padding(15)
        .contentShape(Rectangle())
        .onTapGesture { onOpenReport() }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
    }
}

// MARK: - Graph

private struct MockLineGraph: View {
    let values: [CGFloat]

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 1
            let minValue = values.min() ?? 0
            let range = max(maxValue - minValue, 1)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))

            ZStack {
                VStack(spacing: geo.size.height / 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(BrainColors.subtleFill)
                            .frame(height: 1)
                    }
                }

                Path { path in
                    for index in values.indices {
                        let x = CGFloat(index) * step
                        let normalized = (values[index] - minValue) / range
                        let y = geo.size.height - (normalized * geo.size.height)

                        if index == values.startIndex {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(BrainColors.textPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(values.indices, id: \.self) { index in
                    let x = CGFloat(index) * step
                    let normalized = (values[index] - minValue) / range
                    let y = geo.size.height - (normalized * geo.size.height)

                    Circle()
                        .fill(BrainColors.textPrimary)
                        .frame(width: index == values.count - 1 ? 8 : 5, height: index == values.count - 1 ? 8 : 5)
                        .position(x: x, y: y)
                        .opacity(index == values.count - 1 ? 1 : 0.55)
                }
            }
        }
    }
}

// MARK: - Shared Small Views

private struct ResultMiniMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textQuaternary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ButtonChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(BrainColors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(BrainColors.subtleFill)
            .overlay(
                Capsule()
                    .stroke(BrainColors.cardStroke, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Actions

private struct QuickActionsRow: View {
    let onMenu: () -> Void
    let onCashpoint: () -> Void
    let onAnalytics: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            TeslaControlButton(title: "תפריט", systemImage: "menucard.fill", action: onMenu)
            TeslaControlButton(title: "קופה", systemImage: "hand.point.up.braille.fill", action: onCashpoint)
            TeslaControlButton(title: "דוחות", systemImage: "chart.line.uptrend.xyaxis", action: onAnalytics)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TeslaControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(BrainColors.textTertiary)
                    .tracking(1.0)

                ZStack {
                    Circle()
                        .fill(BrainColors.cardFill)

                    Circle()
                        .stroke(BrainColors.cardStroke, lineWidth: 1)

                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BrainColors.textPrimary)
                }
                .frame(width: 56, height: 56)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Operational Pulse

private struct OperationalPulseCard: View {
    var body: some View {
        HStack(spacing: 12) {
            PulseItem(icon: "checkmark.circle.fill", title: "תשלומים", value: "תקין")
            PulseItem(icon: "printer.fill", title: "מדפסות", value: "2 מחוברות")
            PulseItem(icon: "ipad.and.iphone", title: "מכשירים", value: "3 מחוברים")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BrainColors.subtleStroke, lineWidth: 1)
                )
        )
    }
}

private struct PulseItem: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrainColors.textSecondary)

            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textQuaternary)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(BrainColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Setup Card

private struct SetupMiniCard: View {
    let onDismiss: () -> Void
    let onMenu: () -> Void
    let onCashpoint: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("סיים הגדרה")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)

                    Text("שלב 1 \u{2014} הוסף את המוצרים שלך")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textSecondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BrainColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(BrainColors.subtleFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button(action: onMenu) {
                    Text("צור תפריט")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(BrainColors.invertedText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(BrainColors.invertedBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onCashpoint) {
                    Text("קופה")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(BrainColors.subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(BrainColors.cardStroke, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BrainColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BrainColors.cardStroke, lineWidth: 1)
                )
        )
    }
}

// MARK: - Shop Top Bar

private struct ShopTopBar: View {
    @Binding var selectedShop: ShopOption
    let shops: [ShopOption]
    let onCreateShop: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Menu {
                ForEach(shops) { shop in
                    Button {
                        selectedShop = shop
                    } label: {
                        Text(shop.name)
                    }
                }

                Divider()

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCreateShop()
                } label: {
                    Label("צור חנות", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 6) {
                    Text("בית העם היום")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrainColors.textPrimary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrainColors.textTertiary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}
