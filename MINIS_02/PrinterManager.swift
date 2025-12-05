import Foundation
import Network
import UIKit
import Network
import CoreFoundation   // ⬅️ add this

enum OneShotPrinter {
    static func send(host: String, port: UInt16, data: Data) {
        let hostNW = NWEndpoint.Host(host)
        let portNW = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 9100)

        let connection = NWConnection(host: hostNW, port: portNW, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Swift.print("📡 [OneShotPrinter] connected to \(host):\(port)")
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        Swift.print("⚠️ [OneShotPrinter] send error:", error)
                    } else {
                        Swift.print("✅ [OneShotPrinter] drawer pulse sent")
                    }
                    connection.cancel()
                })
            case .failed(let error):
                Swift.print("❌ [OneShotPrinter] connection failed:", error)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

struct EscPos {
    // Initialize / reset printer
    static let initPrinter = Data([0x1B, 0x40])

    // Line feed (n lines)
    static func feed(_ n: UInt8) -> Data { Data([0x1B, 0x64, n]) }

    // Cut paper
    static let cut = Data([0x1D, 0x56, 0x00])

    // 🔄 180° rotation (ESC { n)
      static let rotate180On  = Data([0x1B, 0x7B, 0x01])   // ESC { 1
      static let rotate180Off = Data([0x1B, 0x7B, 0x00])   // ESC { 0

    // 🔔 Open cash drawer (ESC p, m=0, t1=60 (0x3C = 600ms), t2=255)
    // Adjust timing bytes if your drawer needs different pulse length.
    static let openDrawer    = Data([0x1B, 0x70, 0x00, 0x40, 0x50])
     static let openDrawerAlt = Data([0x1B, 0x70, 0x01, 0x40, 0x50])

    // Raster image (GS v 0) with 180° rotation
    static func raster(_ image: UIImage, maxWidthDots: Int = 576) -> Data {
        guard let rotated = rotate180(image),
              let cg = rotated.cgImage else { return Data() }

        let scale = CGFloat(maxWidthDots) / CGFloat(cg.width)
        let W = maxWidthDots
        let H = max(1, Int(CGFloat(cg.height) * scale))

        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: W,
            height: H,
            bitsPerComponent: 8,
            bytesPerRow: W,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return Data()
        }

        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

        guard let gray = ctx.makeImage(),
              let buf = gray.dataProvider?.data else { return Data() }
        let px = CFDataGetBytePtr(buf)!

        var mono = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            mono[i] = px[i] < 200 ? 1 : 0
        }

        let bytesPerRow = (W + 7) / 8
        var out = Data([
            0x1D, 0x76, 0x30, 0x00,
            UInt8(bytesPerRow & 0xFF), UInt8(bytesPerRow >> 8),
            UInt8(H & 0xFF),         UInt8(H >> 8)
        ])

        for y in 0..<H {
            for bx in 0..<bytesPerRow {
                var b: UInt8 = 0
                for bit in 0..<8 {
                    let x = bx * 8 + bit
                    if x < W, mono[y * W + x] == 1 {
                        b |= (0x80 >> bit)
                    }
                }
                out.append(b)
            }
        }

        out.append(0x0A) // line feed
        return out
    }

    // Rotate image 180°
    private static func rotate180(_ image: UIImage) -> UIImage? {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        ctx.translateBy(x: size.width, y: size.height)
        ctx.rotate(by: .pi)
        image.draw(in: CGRect(origin: .zero, size: size))

        let rotated = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rotated
    }
}

// MARK: - ESC/POS text helpers (alignment + style)
extension EscPos {
    /// ESC a n  (0 = left, 1 = center, 2 = right)
    static func align(_ mode: UInt8) -> Data {
        Data([0x1B, 0x61, mode])
    }

    /// ESC ! n + ESC E (bold)
    /// bit 3 = double height, bit 4 = double width
    static func style(doubleHeight: Bool = false,
                      doubleWidth: Bool = false,
                      bold: Bool = false) -> Data {
        var flags: UInt8 = 0
        if doubleHeight { flags |= 0x10 }
        if doubleWidth  { flags |= 0x20 }

        var d = Data()
        // ESC ! n  → font size flags
        d.append(contentsOf: [0x1B, 0x21, flags])
        // ESC E n  → bold on/off
        d.append(contentsOf: [0x1B, 0x45, bold ? 1 : 0])
        return d
    }
}

/// Simple ASCII line helper (no Hebrew, just plain text)
func asciiLine(_ s: String) -> Data {
    Data((s + "\n").utf8)
}

func visualHebrew(_ s: String) -> String {
    String(s.reversed())
}

/// Encode Hebrew line as Windows-1255 (or ISO-8859-8), with LF at the end
func hebrewLineData(_ s: String) -> Data {
    let visual = visualHebrew(s)

    // Try Windows-1255
    let win1255Enc = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
    )
    if let d = visual.data(using: String.Encoding(rawValue: win1255Enc)) {
        return d + Data([0x0A])    // LF
    }

    // Fallback: ISO-8859-8
    let iso8859_8_Enc = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.isoLatinHebrew.rawValue)
    )
    if let d = visual.data(using: String.Encoding(rawValue: iso8859_8_Enc)) {
        return d + Data([0x0A])
    }

    // Last fallback: UTF-8 (won't look right, but avoids crash)
    return Data((visual + "\n").utf8)
}
fileprivate func stationFromFilter(_ f: StationFilter) -> Station? {
    switch f {
    case .all:     return nil
    case .kitchen: return .kitchen
    case .bar:     return .bar
    case .bakery:  return .bakery
    }
}

fileprivate func stationFromString(_ s: String?) -> Station? {
    guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
    if raw.contains("bar") || raw.contains("drink") || raw.contains("beverage") { return .bar }
    if raw.contains("kitchen") || raw.contains("food") { return .kitchen }
    return nil
}

fileprivate func lineStation(_ line: KDSOrderLine) -> Station? {
    stationFromString(line.station ?? line.category)
}

func hebrewLine(_ text: String,
                widthDots: Int = 576,
                font: UIFont,
                align: NSTextAlignment = .right,
                topBottomPadding: CGFloat = 6,
                sidePadding: CGFloat = 8) -> UIImage {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.baseWritingDirection = .rightToLeft

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: para
    ]

    let max = CGSize(width: CGFloat(widthDots) - 2 * sidePadding,
                     height: .greatestFiniteMagnitude)
    let box = (text as NSString).boundingRect(with: max,
                                              options: [.usesLineFragmentOrigin],
                                              attributes: attrs,
                                              context: nil).integral
    let size = CGSize(width: CGFloat(widthDots), height: box.height + 2 * topBottomPadding)

    UIGraphicsBeginImageContextWithOptions(size, true, 1)
    UIColor.white.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))
    (text as NSString).draw(in: CGRect(x: sidePadding,
                                       y: topBottomPadding,
                                       width: max.width,
                                       height: box.height),
                            withAttributes: attrs)
    let img = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    return img
}

func separatorLine(_ text: String = "✱✱✱✱✱✱✱✱✱✱✱✱✱✱",
                   widthDots: Int = 576,
                   font: UIFont = .monospacedSystemFont(ofSize: 22, weight: .regular)) -> UIImage {
    hebrewLine(text,
               widthDots: widthDots,
               font: font,
               align: .center,
               topBottomPadding: 2,
               sidePadding: 8)
}

func dottedRule(widthDots: Int = 576) -> UIImage {
    hebrewLine(String(repeating: "·", count: 50),
               widthDots: widthDots,
               font: .monospacedSystemFont(ofSize: 18, weight: .regular),
               align: .center,
               topBottomPadding: 0,
               sidePadding: 8)
}

@MainActor
final class TCPPrinter: ObservableObject {
    enum PrinterConnState { case idle, connecting, ready, failed(String) }

    @Published private(set) var printerStatus: String = "Disconnected"
    @Published private(set) var printerState: PrinterConnState = .idle

    private var conn: NWConnection?
    private var host: String = "10.0.0.110"
    private var port: UInt16 = 9100

    private var sendQueue = DispatchQueue(label: "printer.send.queue")
    private var outbox: [Data] = []
    private var isFlushing = false

    func configure(host: String, port: UInt16 = 9100) {
        self.host = host
        self.port = port
    }

    func connectIfNeeded() {
        guard conn == nil else { return }
        printerStatus = "Connecting…"
        printerState = .connecting

        let c = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            Task { @MainActor in
                switch st {
                case .ready:
                    self.printerStatus = "Connected"
                    self.printerState = .ready
                    self.flush()
                case .failed(let e):
                    self.printerStatus = "Failed: \(e.localizedDescription)"
                    self.printerState = .failed(e.localizedDescription)
                    self.teardown()
                case .waiting(let e):
                    self.printerStatus = "Waiting: \(e.localizedDescription)"
                case .cancelled:
                    self.printerStatus = "Disconnected"
                    self.printerState = .idle
                default:
                    break
                }
            }
        }
        c.start(queue: sendQueue)
    }

    func clearQueue() {
        outbox.removeAll()
        isFlushing = false
    }

    func printJob(_ data: Data) {
        outbox.append(data)
        switch printerState {
        case .ready:
            flush()
        case .idle, .failed:
            connectIfNeeded()
        case .connecting:
            break
        }
    }

    private func flush() {
        guard let c = conn, !isFlushing, !outbox.isEmpty else { return }
        guard case TCPPrinter.PrinterConnState.ready = printerState else { return }

        isFlushing = true
        let job = outbox.removeFirst()
        c.send(content: job, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.isFlushing = false
                self.flush()
            }
        })
    }

    func disconnect() { teardown() }

    private func teardown() {
        conn?.cancel(); conn = nil
        isFlushing = false
        if outbox.isEmpty {
            printerState = .idle
            printerStatus = "Disconnected"
        }
    }
}



@MainActor
final class PrinterManager {
    enum Mode { case persistent, oneShot }

    static let shared = PrinterManager()
    private let debugTickets = true

    private let barPrinterIP     = "10.100.10.222"
    private let bakeryPrinterIP  = "10.100.10.221"
    private let kitchenPrinterIP = "10.100.10.220"

    private let barTCP     = TCPPrinter()
    private let bakeryTCP  = TCPPrinter()
    private let kitchenTCP = TCPPrinter()

    private var mode: Mode = .persistent

    private var port: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: "kds.printer.port")
        let candidate = UInt16(exactly: raw) ?? 0
        return candidate == 0 ? 9100 : candidate
    }
    
    func openCashDrawer() {
        let job = EscPos.openDrawer
            + EscPos.feed(2)
            + EscPos.openDrawerAlt
            + EscPos.feed(2)

        Swift.print("🔔 [PrinterManager] openCashDrawer (one-shot) → BAKERY \(bakeryPrinterIP):\(port)")
        OneShotPrinter.send(host: bakeryPrinterIP, port: port, data: job)
    }
    private init() {
     
    }

    func updatePort(_ port: UInt16 = 9100) {
        UserDefaults.standard.set(Int(port), forKey: "kds.printer.port")

        barTCP.configure(host: barPrinterIP, port: port)
        bakeryTCP.configure(host: bakeryPrinterIP, port: port)
        kitchenTCP.configure(host: kitchenPrinterIP, port: port)

        if mode == .persistent {
            barTCP.connectIfNeeded()
            bakeryTCP.connectIfNeeded()
            kitchenTCP.connectIfNeeded()
        }
    }

    // === Mixed Hebrew + Price helper (2-column table line) ===
    // Hebrew label on the RIGHT (RTL), price on the LEFT (LTR).
    // The Hebrew label is reversed, the price is NOT reversed.
    func hebrewMixedLineData(label: String,
                             price: String,
                             totalWidth: Int = 42,   // 42 or 48 for your printer
                             leftPadding: Int = 1) -> Data {

        // Left margin so the text doesn't hug the edge
        let margin = String(repeating: " ", count: leftPadding)

        // Price text (keep as-is, LTR)
        let priceText = price

        // Start of the line: [margin][price][space]
        let leftPart = margin + priceText + " "

        // 🔹 Visual Hebrew only for the label (RTL fix)
        let visualLabel = visualHebrew(label)

        // Remaining width available for [spaces + label]
        let remainingWidth = max(0, totalWidth - leftPart.count)

        // Spaces so that the label is flush to the right edge
        let labelLen = visualLabel.count
        let spacesCount = max(1, remainingWidth - labelLen)
        let spaces = String(repeating: " ", count: spacesCount)

        // Final line: [margin][price][spaces][visual Hebrew label]
        let line = leftPart + spaces + visualLabel

        // Encode as Windows-1255
        let win1255Enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
        )
        if let d = line.data(using: String.Encoding(rawValue: win1255Enc)) {
            return d + Data([0x0A]) // LF
        }

        // Fallback: ISO-8859-8
        let iso8859_8_Enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.isoLatinHebrew.rawValue)
        )
        if let d = line.data(using: String.Encoding(rawValue: iso8859_8_Enc)) {
            return d + Data([0x0A])
        }

        // Last fallback: UTF-8
        return Data((line + "\n").utf8)
    }
    
    func updateMode(_ newMode: Mode) {
        mode = newMode
        barTCP.disconnect()
        bakeryTCP.disconnect()
        kitchenTCP.disconnect()
    }
    func printTaxInvoice(
        invoiceNumber: Int,
        date: Date = Date(),
        customerName: String?,
        items: [InvoiceItem],
        vatRate: Double = 0.17
    ) {
        // ---- BUSINESS DETAILS ----
        let businessName    = "בית העם קונדיטוריה ויין בע\"מ"
        let businessAddress = "מנורה 3 ירושלים"
        let businessPhone   = "טלפון: 0500000000"
        let businessVatId   = "ח.פ / עוסק מורשה: 516784139"

        // ---- DATE / META ----
        let df = DateFormatter()
        df.locale = Locale(identifier: "he_IL")
        df.dateFormat = "dd/MM/yyyy  HH:mm"
        let dateText = df.string(from: date)

        let invoiceIdText = "חשבונית מס #\(invoiceNumber)"

        let safeCustomer = (customerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let customerLine = safeCustomer.isEmpty ? "ללא שם לקוח" : "לקוח: \(safeCustomer)"

        // ---- TOTALS from REAL LINE DATA ----
        let gross = items.reduce(0) { $0 + $1.lineTotal }
        let net = gross / (1.0 + vatRate)
        let vatAmount = gross - net

        func money(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        // ---- DEBUG PREVIEW ----
        Swift.print("══════════ TAX INVOICE PREVIEW #\(invoiceNumber) ══════════")
        Swift.print("תאריך: \(dateText)")
        Swift.print("לקוח: \(safeCustomer.isEmpty ? "ללא שם לקוח" : safeCustomer)")
        Swift.print("────────────────────────────────────────────")
        for item in items {
            Swift.print("• \(item.quantity)x \(item.name) → \(money(item.lineTotal))")
        }
        Swift.print("────────────────────────────────────────────")
        Swift.print("סה\"כ לפני מע\"מ: \(money(net))")
        Swift.print("מע\"מ \(Int(vatRate * 100))%: \(money(vatAmount))")
        Swift.print("סה\"כ לתשלום: \(money(gross))")
        Swift.print("════════════════════════════════════════════\n")

        // ---- LAYOUT CONSTANTS ----
        let lineWidth = 42   // adjust if your printer is 48 chars wide

        func separatorLine() -> Data {
            let dashes = String(repeating: "-", count: lineWidth)
            return asciiLine(dashes)
        }

        // ---- BUILD ESC/POS JOB ----
        var job = Data()
        job += EscPos.initPrinter
        job += EscPos.feed(1)

        // Hebrew codepage (Windows-1255)
        job.append(contentsOf: [0x1B, 0x74, 33])  // ESC t 33

        // ===== TITLE: חשבונית מס (BIG, CENTER) =====
        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData("חשבונית מס")

        // ===== BUSINESS DETAILS (CENTER) =====
        job += EscPos.feed(1)
        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += hebrewLineData(businessName)
        job += hebrewLineData(businessAddress)
        job += hebrewLineData(businessPhone)
        job += hebrewLineData(businessVatId)

        job += EscPos.feed(1)

        // ===== INVOICE META (CENTER) =====
        job += hebrewLineData(invoiceIdText)
        job += hebrewLineData("תאריך: \(dateText)")
        job += hebrewLineData(customerLine)

        // ===== SEPARATOR =====
        job += EscPos.feed(1)
        job += EscPos.align(0)
        job += separatorLine()

        // ===== ITEMS TABLE =====
        job += EscPos.feed(1)
        job += EscPos.align(0)

        for item in items {
            let label = "\(item.quantity)x \(item.name)"
            let priceText = money(item.lineTotal)
            job += hebrewMixedLineData(
                label: label,
                price: priceText,
                totalWidth: lineWidth,
                leftPadding: 1
            )
        }

        // ===== SEPARATOR =====
        job += EscPos.feed(1)
        job += EscPos.align(0)
        job += separatorLine()

        // ===== TOTALS TABLE =====
        job += EscPos.feed(1)
        job += EscPos.align(0)

        // Subtotal
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += hebrewMixedLineData(
            label: "סה\"כ לפני מע\"מ",
            price: money(net),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        // VAT row
        job += hebrewMixedLineData(
            label: "מע\"מ \(Int(vatRate * 100))%",
            price: money(vatAmount),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        // Grand total – same layout, just bold
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: true)
        job += hebrewMixedLineData(
            label: "סה\"כ לתשלום",
            price: money(gross),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        // RESET + bottom padding + cut
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += EscPos.align(0)
        job += EscPos.feed(4)
        job += EscPos.cut

        Swift.print("🧾 [PrinterManager] printTaxInvoice → bakery (one-shot) \(bakeryPrinterIP):\(port)")
        OneShotPrinter.send(host: bakeryPrinterIP, port: port, data: job)
    }

    func print(order o: KDSAdminOrder, for station: StationFilter) {
        guard o.source == .kiosk else {
               Swift.print("🛑 [PrinterManager] skipping print for non-kiosk source: \(o.source)")
               return
           }

        let allLines = o.lines

        let kitchenLines: [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .kitchen }
        let bakeryLines:  [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bakery }
        let barLines:     [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bar }

        switch station {
        case .kitchen:
            guard !kitchenLines.isEmpty else {
                Swift.print("🧑‍🍳 KITCHEN: no lines to print for order #\(o.id)")
                return
            }

            debugTicketPreview(order: o, lines: kitchenLines, stationLabel: "Kitchen")

            let job = makeJob(order: o, lines: kitchenLines)
            Swift.print("🧑‍🍳 KITCHEN: sending \(job.count) bytes to \(kitchenPrinterIP):\(port)")

            send(job, via: kitchenTCP, host: kitchenPrinterIP)

        case .bakery:
            Swift.print("🧁 BAKERY printing order #\(o.id), lines=",
                        bakeryLines.map { "\($0.name) (\($0.category ?? "-"))" })

            guard !bakeryLines.isEmpty else {
                Swift.print("🧁 BAKERY: no lines to print for order #\(o.id)")
                return
            }

            debugTicketPreview(order: o, lines: bakeryLines, stationLabel: "Bakery")

            let job = makeJob(order: o, lines: bakeryLines)
            Swift.print("🧁 BAKERY: sending \(job.count) bytes to \(bakeryPrinterIP):\(port)")

            send(job, via: bakeryTCP, host: bakeryPrinterIP)

        case .all:
            guard !allLines.isEmpty else {
                Swift.print("📦 ALL: no lines to print for order #\(o.id)")
                return
            }

            let job = makeJob(order: o, lines: allLines)
            Swift.print("📦 ALL: sending \(job.count) bytes to bar \(barPrinterIP):\(port)")
            debugTicketPreview(order: o, lines: allLines, stationLabel: "All stations")

            send(job, via: barTCP, host: barPrinterIP)

        case .bar:
            Swift.print("🖨 BAR station handling order #\(o.id)")
            Swift.print("   • bakeryLines =",
                        bakeryLines.map { "\($0.name) (\($0.category ?? "-"))" })
            Swift.print("   • barLines    =",
                        barLines.map { "\($0.name) (\($0.category ?? "-"))" })

            if bakeryLines.isEmpty && barLines.isEmpty {
                Swift.print("🖨 BAR: no lines to print for order #\(o.id)")
                return
            }

            if !bakeryLines.isEmpty {
                debugTicketPreview(order: o,
                                   lines: bakeryLines,
                                   stationLabel: "Bakery via BAR")

                let bakeryJob = makeJob(order: o, lines: bakeryLines)
                Swift.print("🧁 BAKERY (from BAR): sending \(bakeryJob.count) bytes to \(bakeryPrinterIP):\(port)")
                send(bakeryJob, via: bakeryTCP, host: bakeryPrinterIP)
            }

            if !barLines.isEmpty {
                debugTicketPreview(order: o,
                                   lines: barLines,
                                   stationLabel: "Bar")

                let barJob = makeJob(order: o, lines: barLines)
                Swift.print("🖨 BAR: sending \(barJob.count) bytes to \(barPrinterIP):\(port)")
                send(barJob, via: barTCP, host: barPrinterIP)
            }
        }
    }

    
    
    
    
    func printSplitAllStations(order o: KDSAdminOrder) {
        guard o.source == .kiosk else {
                Swift.print("🛑 [PrinterManager] skipping split-all print for non-kiosk source: \(o.source)")
                return
            }

        let allLines = o.lines

        let kitchenLines: [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .kitchen }
        let bakeryLines:  [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bakery }
        let barLines:     [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bar }

        if kitchenLines.isEmpty && bakeryLines.isEmpty && barLines.isEmpty {
            Swift.print("🖨 SPLIT-ALL: no lines to print for order #\(o.id)")
            return
        }

        if !kitchenLines.isEmpty {
            debugTicketPreview(order: o,
                               lines: kitchenLines,
                               stationLabel: "Kitchen (split all)")

            let job = makeJob(order: o,
                              lines: kitchenLines,
                              rotated: true)     // 👈 here
            Swift.print("🧑‍🍳 SPLIT-ALL KITCHEN: sending \(job.count) bytes to \(kitchenPrinterIP):\(port)")
            send(job, via: kitchenTCP, host: kitchenPrinterIP)
        }

        if !bakeryLines.isEmpty {
            debugTicketPreview(order: o,
                               lines: bakeryLines,
                               stationLabel: "Bakery (split all)")

            let job = makeJob(order: o,
                              lines: bakeryLines,
                              rotated: true)     // 👈 here
            Swift.print("🧁 SPLIT-ALL BAKERY: sending \(job.count) bytes to \(bakeryPrinterIP):\(port)")
            send(job, via: bakeryTCP, host: bakeryPrinterIP)
        }

        if !barLines.isEmpty {
            debugTicketPreview(order: o,
                               lines: barLines,
                               stationLabel: "Bar (split all)")

            let job = makeJob(order: o,
                              lines: barLines,
                              rotated: true)     // 👈 here
            Swift.print("🍹 SPLIT-ALL BAR: sending \(job.count) bytes to \(barPrinterIP):\(port)")
            send(job, via: barTCP, host: barPrinterIP)
        }
    }

    fileprivate func normalizeCategory(_ s: String) -> String {
        // Strip emojis and symbols, keep letters/digits/spaces
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)

        return String(
            s.unicodeScalars
                .filter { allowed.contains($0) }
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }
    fileprivate func classifyStation(for line: KDSOrderLine) -> Station {
        let rawCat  = (line.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = line.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let cat  = normalizeCategory(rawCat)
        let name = rawName.lowercased()

        // 🔔 Hard-coded notes by name
        if rawName.contains("הערה לוטרינה") { return .bakery }
        if rawName.contains("הערה למטבח")  { return .kitchen }
        if rawName.contains("הערה לבר")     { return .bar }

        // Safety: any free-text mention of וטרינה → bakery
        if name.contains("וטרינה") {
            return .bakery
        }

        // 🍽️ CATEGORY-BASED KITCHEN RULES
        let isSaladCategory =
            cat.contains("סלט")   // ← ONLY category decides "salad"

        let isSandwichToastCategory =
            cat.contains("כריכים") ||
            cat.contains("טוסט")

        // 🧁 CATEGORY-BASED BAKERY
        let isBakeryCategory =
            cat.contains("מאפים מתוקים") ||
            cat.contains("מאפים מלוחים") ||
            cat.contains("עוגות ועוד")   ||
            cat.contains("מוצרים לבית")  ||
            cat.contains("מאפים")        ||
            cat.contains("מאפה")         ||
            cat.contains("עוגות")        ||
            cat.contains("עוגה")

        // 🧑‍🍳 route to KITCHEN
        if isSaladCategory {
            return .kitchen
        }

        // Sandwiches with toast in SAME category STILL go to kitchen only if category says so
        if isSandwichToastCategory && name.contains("טוסט") {
            return .kitchen
        }

        // 🧁 route to BAKERY
        if isBakeryCategory {
            return .bakery
        }

        // Non-toast inside כריכים category → bakery (same as before)
        if isSandwichToastCategory && !name.contains("טוסט") {
            return .bakery
        }

        // 🍹 everything else → BAR
        return .bar
    }

    private func send(_ job: Data, via printer: TCPPrinter, host: String) {
        // Ignore `printer` and `mode`, just fire one-shot
        OneShotPrinter.send(host: host, port: port, data: job)
    }

    private func debugTicketPreview(order: KDSAdminOrder,
                                    lines: [KDSOrderLine],
                                    stationLabel: String) {
        guard debugTickets else { return }

        Swift.print("──────── \(stationLabel.uppercased()) TICKET #\(order.id) ────────")
        Swift.print("Customer: \(order.customerName.isEmpty ? "-" : order.customerName)")
        Swift.print("Service:  \(serviceLabel(from: order.service))")
        Swift.print("Placed:   \(order.placedAt)")
        Swift.print("Items:")

        if lines.isEmpty {
            Swift.print("  (no lines)")
        } else {
            for ln in lines {
                let cat = ln.category ?? "-"
                Swift.print("  - \(ln.qty)x \(ln.name) [\(cat)]")

                if let mods = ln.modifiers?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !mods.isEmpty {
                    Swift.print("      · \(mods)")
                }
            }
        }

        Swift.print("────────────────────────────────────────────\n")
    }
    
    private func removeKeyword(_ keyword: String, from mods: String?) -> String {
        guard var m = mods else { return "" }

        m = m.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
        m = m.replacingOccurrences(of: "  ", with: " ")
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeJob(order o: KDSAdminOrder,
                         lines: [KDSOrderLine],
                         rotated: Bool = false) -> Data {

        // ====== STEP 1 – Build raw printable entries with size + cleaned modifiers ======
        struct PrintItem {
            var nameWithSize: String
            var qty: Int
            var modsClean: String   // modifiers AFTER removing גודל / group titles
        }

        let caution: String = {
            let name = o.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.lowercased() == "customer" { return "שם לקוח" }
            return name
        }()

        let orderIdText = "#\(o.id)"

        let df = DateFormatter()
        df.dateFormat = "HH:mm   dd/MM/yyyy"
        let orderMeta1 = df.string(from: o.placedAt)

        var rawItems: [PrintItem] = []

        for ln in lines {
            let (sizeWord, modsRest) = extractSize(from: ln.modifiers)
            let cleanName = ln.name.trimmingCharacters(in: .whitespacesAndNewlines)

            let rawModifiers = ln.modifiers ?? ""
            let modsLower = rawModifiers.lowercased()

            let nameWithSize: String = {
                // 1️⃣ Espresso / Macchiato (“כפול” logic)
                if cleanName == "אספרסו" || cleanName == "מקיאטו" {
                    if modsLower.contains("כפול") {
                        // Title: אספרסו כפול / מקיאטו כפול
                        return "\(cleanName) כפול"
                    } else {
                        return cleanName
                    }
                }

                // 2️⃣ Hafuch / Americano (“size” logic)
                if cleanName == "הפוך" || cleanName == "אמריקנו" {
                    if let size = sizeWord, !size.isEmpty {
                        return "\(cleanName) \(size)"
                    } else {
                        return "\(cleanName) קטן"
                    }
                }

                // 3️⃣ Generic case (use size if exists)
                if let size = sizeWord, !size.isEmpty {
                    return "\(cleanName) \(size)"
                }

                return cleanName
            }()

            // 👇 Build the modifiers string that will actually be printed
            let modsSource: String = {
                if cleanName == "אספרסו" || cleanName == "מקיאטו" {
                    // For espresso/macchiato we want to KEEP size (“גודל: ארוך”) and
                    // other modifiers, but DROP “כפול” from the printed modifiers.
                    return removeKeyword("כפול", from: rawModifiers)
                } else {
                    // For all other drinks, keep using modsRest (size already handled)
                    return modsRest
                }
            }()

            let modsClean = breakModifiers(modsSource)

            rawItems.append(
                PrintItem(
                    nameWithSize: nameWithSize,
                    qty: ln.qty,
                    modsClean: modsClean
                )
            )
        }

        // ====== STEP 2 – Merge items that share the same nameWithSize AND have no modifiers ======
        var mergedItems: [PrintItem] = []

        for item in rawItems {
            if item.modsClean.isEmpty {
                if let idx = mergedItems.firstIndex(where: {
                    $0.nameWithSize == item.nameWithSize && $0.modsClean.isEmpty
                }) {
                    mergedItems[idx].qty += item.qty
                } else {
                    mergedItems.append(item)
                }
            } else {
                // items with modifiers never merge
                mergedItems.append(item)
            }
        }

        // ====== STEP 3 – Build ESC/POS TEXT data ======
        var job = Data()
        job += EscPos.initPrinter

        // Hebrew codepage (Windows-1255)
        job.append(contentsOf: [0x1B, 0x74, 33])  // ESC t 33

        // 🔄 Optional 180° rotation
        if rotated {
            job += EscPos.rotate180On
        }

        let rawService = o.service?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let isTakeAwayService =
            rawService == "ta" ||
            rawService.contains("take") ||
            rawService.contains("to-go") ||
            rawService.contains("togo") ||
            rawService.contains("pickup") ||
            rawService.contains("collection")

        // ===== TOP PADDING =====
        job += EscPos.feed(2)

        let modifierIndent = "   "   // visual left padding for modifiers

        if rotated {
            
            if isTakeAwayService {
                job += EscPos.feed(1)
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)
                job += asciiLine("** TA **")
                
                job += EscPos.align(1)
            }
            // ============================================================
            // 🔄 ROTATED VERSION
            //
            // ESC order (top→bottom on paper as it prints):
            //   1. global separator
            //   2. items (with inner separators)
            //   3. meta (time, name, order, TA)
            //
            // After 180° flip in the printer, visual order (top→bottom) is:
            //   meta → items → global separator
            // so items are ABOVE the bottom line as desired.
            // ============================================================

            // ---- GLOBAL SEPARATOR (will become very bottom after rotation) ----
            job += EscPos.style(doubleHeight: false,
                                doubleWidth: false,
                                bold: false)
            job += EscPos.align(0)
            job += asciiLine("------------------------------------------------")
            job += EscPos.feed(1)

            // ---- ITEMS BLOCK ----
            for item in mergedItems.reversed() {

                // ITEM: BIG, BOLD, RIGHT ALIGN
               
                // Modifiers
                if !item.modsClean.isEmpty {
                    job += EscPos.feed(1)

                    job += EscPos.align(2)
                    job += EscPos.style(doubleHeight: false,
                                        doubleWidth: true,
                                        bold: false)

                    let lines = item.modsClean
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                        .map(String.init)

                    if lines.isEmpty {
                        job += hebrewLineData(modifierIndent + item.modsClean)
                    } else {
                        for m in lines {
                            job += hebrewLineData(modifierIndent + m)
                        }
                    }
                }

                job += EscPos.align(2)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)

            
                let title = "\(item.qty) \(item.nameWithSize)"
                job += hebrewLineData(title)

                // Per-item separator (between items)
                job += EscPos.feed(1)
                job += EscPos.style(doubleHeight: false,
                                    doubleWidth: false,
                                    bold: false)
                job += EscPos.align(0)
                job += asciiLine("------------------------------------------------")
                job += EscPos.feed(1)
            }

            // ---- META BLOCK (will appear at top after rotation) ----
            job += EscPos.feed(2)

            // Time/date – small, right
            job += EscPos.align(2)
            job += EscPos.style(doubleHeight: false,
                                doubleWidth: false,
                                bold: false)
            job += asciiLine(orderMeta1)

            // Customer name – big, center (Hebrew)
            job += EscPos.feed(1)
            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true,
                                doubleWidth: true,
                                bold: true)
            job += hebrewLineData(caution)

            // Order ID – big, center
            job += EscPos.feed(1)
            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true,
                                doubleWidth: true,
                                bold: true)
            job += asciiLine(orderIdText)

            // TA label (if needed)
            if isTakeAwayService {
                job += EscPos.feed(1)
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)
                job += asciiLine("** TA **")
            }

        } else {
            // ============================================================
            // ORIGINAL (NON-ROTATED) LAYOUT – unchanged
            // ============================================================

            // ===== TOP TA BLOCK (only for TA) =====
            if isTakeAwayService {
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)
                job += asciiLine("** TA **")
                job += EscPos.feed(1)
            }

            // ===== ORDER ID – BIG CENTERED =====
            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true,
                                doubleWidth: true,
                                bold: true)
            job += asciiLine(orderIdText)

            // SPACE
            job += EscPos.feed(1)

            // ===== CUSTOMER NAME – BIG CENTERED (HEBREW) =====
            job += hebrewLineData(caution)

            // MORE SPACE BEFORE DATE
            job += EscPos.feed(2)

            // ===== SMALL RIGHT-ALIGNED DATE/TIME =====
            job += EscPos.align(2)
            job += EscPos.style(doubleHeight: false,
                                doubleWidth: false,
                                bold: false)
            job += asciiLine(orderMeta1)

            // ===== SEPARATOR =====
            job += EscPos.style(doubleHeight: false,
                                doubleWidth: false,
                                bold: false)
            job += EscPos.align(0)
            job += asciiLine("------------------------------------------------")

            // ===== SPACE BEFORE ITEMS =====
            job += EscPos.feed(1)

            // ===== ITEMS – print in reverse to keep original visual order =====
            for item in mergedItems.reversed() {

                // ITEM: BIG, BOLD, RIGHT ALIGN
                job += EscPos.align(2)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)

                let title = "\(item.qty) \(item.nameWithSize)"
                job += hebrewLineData(title)

                // small padding before modifiers
                if !item.modsClean.isEmpty {
                    job += EscPos.feed(1)

                    // MODIFIERS – doubleWidth only (big but flatter), right aligned
                    job += EscPos.align(2)
                    job += EscPos.style(doubleHeight: false,
                                        doubleWidth: true,
                                        bold: false)

                    // break modifiers into lines if needed
                    let lines = item.modsClean
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                        .map(String.init)

                    if lines.isEmpty {
                        job += hebrewLineData(modifierIndent + item.modsClean)
                    } else {
                        for m in lines {
                            job += hebrewLineData(modifierIndent + m)
                        }
                    }
                }

                // SEPARATOR between items
                job += EscPos.feed(1)
                job += EscPos.style(doubleHeight: false,
                                    doubleWidth: false,
                                    bold: false)
                job += EscPos.align(0)
                job += asciiLine("------------------------------------------------")
                job += EscPos.feed(1)
            }

            // ===== BOTTOM TA BLOCK (for TA) =====
            if isTakeAwayService {
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: true,
                                    doubleWidth: true,
                                    bold: true)
                job += asciiLine("** TA **")
            }
        }

        // RESET + bottom padding
        job += EscPos.style(doubleHeight: false,
                            doubleWidth: false,
                            bold: false)
        job += EscPos.align(0)
        job += EscPos.feed(6)

        // 🔄 Turn rotation off if it was enabled
        if rotated {
            job += EscPos.rotate180Off
        }

        job += EscPos.cut

        return job
    }
}


fileprivate func breakModifiers(_ mods: String) -> String {
    mods
        .components(separatedBy: CharacterSet(charactersIn: "·,"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { token in
            if let r = token.range(of: ":") {
                return token[token.index(after: r.lowerBound)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return token
        }
        .joined(separator: "\n")
}

extension PrinterManager {

    // MARK: - Hebrew detection
    private func containsHebrew(_ s: String) -> Bool {
        return s.range(of: "\\p{Hebrew}", options: .regularExpression) != nil
    }

    // MARK: - Hebrew shaping (simple rule: flip entire cell if Hebrew exists)
    private func flipHebrewOnly(_ raw: String) -> String {
        return containsHebrew(raw) ? visualHebrew(raw) : raw
    }

    // MARK: - Black title bar
    private func makeBlackTitle(_ text: String, totalWidth: Int = 24) -> Data {
        let rendered = containsHebrew(text) ? visualHebrew(text) : text
        var line = rendered

        if line.count < totalWidth {
            let pad = totalWidth - line.count
            let left = pad / 2
            let right = pad - left
            line = String(repeating: " ", count: left) + line
                 + String(repeating: " ", count: right)
        } else if line.count > totalWidth {
            line = String(line.prefix(totalWidth))
        }

        var d = Data()

        // Double size font
        d.append(contentsOf: [0x1D, 0x21, 0x11])

        // Reverse ON (white text on black)
        d.append(contentsOf: [0x1D, 0x42, 0x01])

        // Print Hebrew (Windows-1255)
        let enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
        )
        d += (line as NSString).data(using: enc) ?? Data()
        d.append(0x0A)

        // Reverse OFF
        d.append(contentsOf: [0x1D, 0x42, 0x00])

        // Reset font
        d.append(contentsOf: [0x1D, 0x21, 0x00])

        return d
    }

    // MARK: - Table row
    private func makeDebugRow(_ columns: [String], align: [Character]) -> Data {
        let colWidths = [9, 9, 9, 12]   // columns RTL-reversed
        let totalCols = 4
        var parts: [String] = []

        for i in 0..<totalCols {
            let raw       = i < columns.count ? columns[i] : ""
            let alignType = i < align.count   ? align[i]   : "L"

            var s = flipHebrewOnly(raw)
            let colWidth = colWidths[i]

            if s.count > colWidth {
                s = String(s.prefix(colWidth))
            }

            let padding = max(0, colWidth - s.count)

            switch alignType {
            case "R":
                s = String(repeating: " ", count: padding) + s
            case "C":
                let left = padding / 2
                let right = padding - left
                s = String(repeating: " ", count: left) + s
                  + String(repeating: " ", count: right)
            default:
                s = s + String(repeating: " ", count: padding)
            }

            parts.append(s)
        }

        let line = parts.joined(separator: " | ")

        // 🔍 LOG PREVIEW
        Swift.print("ROW:", line)

        if containsHebrew(line) {
            let enc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
            )
            var d = (line as NSString).data(using: enc) ?? Data()
            d.append(0x0A)
            return d
        } else {
            return asciiLine(line)
        }
    }

    // MARK: - Separator
    private func makeDebugSeparator() -> Data {
        let totalChars = 48 // matches 9+9+9+12 + 3 separators*3
        let line = String(repeating: "-", count: totalChars)
        return asciiLine(line)
    }

    // MARK: - MAIN DEMO
    func printSalesDebugDemo() {
        Swift.print("=== DEBUG PRINT (מכירות + תקבולים) ===")

        var job = Data()
        job += EscPos.initPrinter
        job.append(contentsOf: [0x1B, 0x74, 33])

        // ---------- TITLE ----------
        job += makeBlackTitle("מכירות", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator()

        // ---------- HEADER ----------
        job += makeDebugRow(
            ["PPA", "סועד", "כולל מעמ", "ללא מעמ"],
            align: ["C","C","C","C"]
        )
        job += makeDebugSeparator()

        // ---------- ROWS ----------
        job += makeDebugRow(["26","14","375.0","מסעדה  7.713"], align: ["R","R","R","R"])
        job += makeDebugRow(["22","08","317.2","317.2     TA"], align: ["R","R","R","R"])
        job += makeDebugRow(["","","692.2","מכירות 7.713"], align: ["R","R","R","R"])
        job += makeDebugRow(["","","7.713","תשר    7.713"], align: ["R","R","R","R"])
        job += makeDebugRow(["","","699.9","סהכ    7.713"], align: ["R","R","R","R"])

        job += makeDebugSeparator()

        // ---------- תקבולים ----------
        job += makeBlackTitle("תקבולים", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator()

        job += makeDebugRow(["סכום","תשלום","סוג","כמות"], align: ["C","C","C","C"])
        job += makeDebugSeparator()

        job += makeDebugRow(["250.0","מזומן","-","3"], align: ["R","C","C","R"])
        job += makeDebugRow(["329.9","אשראי","-","5"], align: ["R","C","C","R"])

        job += makeDebugSeparator()
        job += makeDebugRow(["579.9","סהכ","","8"], align: ["R","C","C","R"])
        job += makeDebugSeparator()

        job += EscPos.feed(3)
        job += EscPos.cut

        Swift.print("SENDING", job.count, "bytes to printer")
        OneShotPrinter.send(host: bakeryPrinterIP, port: port, data: job)
    }
    
    func printCashPointSplit(
        orderNumber: Int,
        entries: [BasketEntry],
        total: Double,
        diningMode: DiningMode,
        customerName: String?
    ) {
        let lines: [KDSOrderLine] = entries.map { entry in
            KDSOrderLine(
                itemId: nil,
                productId: entry.item.id,
                name: entry.item.name,
                qty: entry.quantity,
                category: entry.item.category,
                status: 1,
                station: nil,
                modifiers: entry.subtitle
            )
        }

        let order = KDSAdminOrder(
            id: orderNumber,
            source: .kiosk,
            tableLabel: nil,
            bucket: .active,
            stage: .received,
            placedAt: Date(),
            scheduledFor: nil,
            customerName: customerName ?? "",
            totalGBP: total,
            itemSummary: "",
            isDelivery: false,
            shortCode: nil,
            lines: lines,
            service: diningMode == .dineIn ? "sit" : "ta",
            name: customerName
        )

        printSplitAllStations(order: order)
    }
}

fileprivate func serviceLabel(from raw: String?) -> String {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "sit", "dinein", "dine_in", "dine-in", "table", "eat-in", "eatin":
        return "לשבת"
    case "ta", "takeaway", "take_away", "take-away",
         "collection", "pickup", "pick_up", "pick-up",
         "to-go", "togo":
        return "לקחת"
    default:
        return "לשבת"
    }
}

fileprivate func extractSize(from modifiers: String?) -> (size: String?, rest: String) {
    guard var mods = modifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !mods.isEmpty else {
        return (nil, "")
    }

    let patterns = [
        #"(?i)(^|[·,\s])גודל\s*:?\s*([^·,\n]+)"#,
        #"(?i)(^|[·,\s])size\s*:?\s*([^·,\n]+)"#
    ]

    func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "·, "))
    }

    for pattern in patterns {
        if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(mods.startIndex..<mods.endIndex, in: mods)
            if let m = rx.firstMatch(in: mods, options: [], range: range),
               m.numberOfRanges >= 3,
               let capRange = Range(m.range(at: 2), in: mods) {

                let sizeVal = clean(String(mods[capRange]))
                if let fullRange = Range(m.range(at: 0), in: mods) {
                    mods.removeSubrange(fullRange)
                }
                return (sizeVal.isEmpty ? nil : sizeVal, clean(mods))
            }
        }
    }

    let keywords = ["קטן","בינוני","גדול","ענק","Small","Medium","Large","S","M","L"]
    if let kw = keywords.first(where: { mods.components(separatedBy: .whitespacesAndNewlines).contains($0) }) {
        if let tokenRange = mods.range(of: #"\b\#(kw)\b"#, options: [.regularExpression, .caseInsensitive]) {
            mods.removeSubrange(tokenRange)
        }
        return (kw, clean(mods))
    }

    return (nil, clean(mods))
}

fileprivate extension Optional where Wrapped == UInt16 {
    func nonZeroOrDefault(_ def: UInt16) -> UInt16 {
        switch self {
        case .some(let v) where v != 0: return v
        default: return def
        }
    }
}

fileprivate func removeGroupTitles(from mods: String) -> String {
    let tokens = mods
        .components(separatedBy: CharacterSet(charactersIn: "·,"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { token in
            if let r = token.range(of: #"^[^:]{1,30}:\s*"#, options: .regularExpression) {
                return token[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let r = token.range(of: #"^\(([^:]{1,30}):\s*"#, options: .regularExpression) {
                var t = token
                t.removeSubrange(r)
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return token
        }

    return tokens.joined(separator: " · ")
}


struct InvoiceItem {
    let name: String
    let quantity: Int
    let unitPrice: Double

    var lineTotal: Double {
        Double(quantity) * unitPrice
    }
}

123454
