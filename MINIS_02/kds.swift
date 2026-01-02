import SwiftUI

// MARK: - Models

struct KDSTicket: Identifiable, Hashable {
    let id = UUID()
    var orderNumber: String
    var tableOrChannel: String
    var service: String
    var elapsed: String
    var pace: String?
    var course: String?
    var lines: [KDSLine]
}

struct KDSLine: Identifiable, Hashable {
    let id = UUID()
    var qty: Int
    var name: String
    var priceText: String? = nil
    var isAlert: Bool = false
}

// History item stored per spot
struct SpotEntry: Identifiable, Hashable {
    let id = UUID()
    let ticket: KDSTicket
    let placedAt: Date
    let bartender: String
}

// MARK: - Preference Keys (accurate frames)

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct SpotFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Main View (Barista)

struct BarKDSBoardView: View {
    private let columns: [GridItem] = Array(repeating: .init(.flexible(), spacing: 10, alignment: .top), count: 5)

    @State private var incoming: [KDSTicket] = [
        KDSTicket(orderNumber: "#114", tableOrChannel: "Omer", service: "Bar", elapsed: "02:10", pace: nil, course: nil,
                  lines: [.init(qty: 2, name: "Cappuccino"),
                          .init(qty: 1, name: "Espresso")]),
        KDSTicket(orderNumber: "#116", tableOrChannel: "Yael", service: "Bar", elapsed: "01:25", pace: nil, course: nil,
                  lines: [.init(qty: 1, name: "Latte Oat"),
                          .init(qty: 1, name: "Americano")]),
        KDSTicket(orderNumber: "#111", tableOrChannel: "Tom", service: "Bar", elapsed: "04:01", pace: nil, course: nil,
                  lines: [.init(qty: 1, name: "Iced Latte"),
                          .init(qty: 1, name: "Croissant")]),
        KDSTicket(orderNumber: "#115", tableOrChannel: "Noa", service: "Bar", elapsed: "00:55", pace: nil, course: nil,
                  lines: [.init(qty: 1, name: "Cortado")]),
        KDSTicket(orderNumber: "#118", tableOrChannel: "Avi", service: "Bar", elapsed: "03:12", pace: nil, course: nil,
                  lines: [.init(qty: 1, name: "Hot Chocolate")]),
    ]

    // Spots 1-5 are pickup; row 6 is "Returns"
    private let pickupSpotCount = 5
    private var totalSpots: Int { pickupSpotCount + 1 } // + returns (spot 6)
    private var returnsIndex: Int { totalSpots - 1 }

    // Spot histories (index 0..5)
    @State private var spotHistory: [[SpotEntry]] = Array(repeating: [], count: 6)

    // frames
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var spotFrames: [Int: CGRect] = [:]

    // drag state (placing from incoming into a spot)
    @State private var draggingId: UUID? = nil
    @State private var draggingTicket: KDSTicket? = nil
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartFrame: CGRect = .zero
    @State private var hoveredSpot: Int? = nil
    @State private var isDropping: Bool = false

    // demo bartender identity
    @State private var bartenderName: String = "Bar 1"

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {

                // Top bar
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .opacity(0.65)

                    Text("Bar KDS")
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()

                    Menu {
                        Button("Bar 1") { bartenderName = "Bar 1" }
                        Button("Bar 2") { bartenderName = "Bar 2" }
                        Button("Bar 3") { bartenderName = "Bar 3" }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(0.7)
                            Text(bartenderName)
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(0.75)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.55)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.black.opacity(0.08)), alignment: .bottom)

                // Incoming grid
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(incoming) { ticket in
                            KDSTicketCard(ticket: ticket)
                                .opacity(draggingId == ticket.id ? 0.18 : 1.0)
                                .background(
                                    GeometryReader { g in
                                        Color.clear
                                            .preference(key: CardFrameKey.self, value: [ticket.id: g.frame(in: .global)])
                                    }
                                )
                                .contentShape(Rectangle())
                                .gesture(ticketDrag(ticket))
                        }
                    }
                    .padding(12)
                }
                .background(Color(.systemGroupedBackground))

                // Bottom: Spots 1-5 + Returns row 6
                SpotsHistoryBar(
                    pickupCount: pickupSpotCount,
                    histories: $spotHistory,
                    hoveredIndex: hoveredSpot,
                    onReturnEntry: { fromSpotIndex, entry in
                        moveEntryToReturns(fromSpotIndex: fromSpotIndex, entry: entry)
                    }
                )
                .background(Color.white)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.black.opacity(0.08)), alignment: .top)
            }

            // Floating full card
            if let t = draggingTicket, draggingId == t.id {
                KDSTicketCard(ticket: t)
                    .frame(width: dragStartFrame.width, height: dragStartFrame.height, alignment: .topLeading)
                    .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 12)
                    .scaleEffect(1.02)
                    .position(
                        x: (dragStartFrame.midX + dragTranslation.width),
                        y: (dragStartFrame.midY + dragTranslation.height)
                    )
                    .allowsHitTesting(false)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.92), value: dragTranslation)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .onPreferenceChange(CardFrameKey.self) { cardFrames = $0 }
        .onPreferenceChange(SpotFrameKey.self) { spotFrames = $0 }
        .onChange(of: dragTranslation) { _ in
            guard draggingTicket != nil, !isDropping else { return }
            let center = CGPoint(x: dragStartFrame.midX + dragTranslation.width,
                                 y: dragStartFrame.midY + dragTranslation.height)
            hoveredSpot = hoverSpotIndex(for: center)
        }
    }

    // MARK: - Drag: place into a spot history (last 5)

    private func ticketDrag(_ ticket: KDSTicket) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if draggingTicket == nil && !isDropping {
                    draggingTicket = ticket
                    draggingId = ticket.id
                    dragTranslation = .zero

                    if let f = cardFrames[ticket.id], f.width > 0, f.height > 0 {
                        dragStartFrame = f
                    } else {
                        dragStartFrame = CGRect(x: value.startLocation.x - 140,
                                                y: value.startLocation.y - 80,
                                                width: 280,
                                                height: 160)
                    }
                }

                guard draggingId == ticket.id, !isDropping else { return }
                dragTranslation = value.translation
            }
            .onEnded { _ in
                guard let t = draggingTicket, draggingId == t.id, !isDropping else { return }

                let center = CGPoint(x: dragStartFrame.midX + dragTranslation.width,
                                     y: dragStartFrame.midY + dragTranslation.height)

                if let idx = hoverSpotIndex(for: center),
                   let target = spotFrames[idx] {

                    isDropping = true
                    let targetCenter = CGPoint(x: target.midX, y: target.midY)
                    let needed = CGSize(width: targetCenter.x - dragStartFrame.midX,
                                        height: targetCenter.y - dragStartFrame.midY)

                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        dragTranslation = needed
                        hoveredSpot = idx
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                        placeIntoSpotHistory(t, spotIndex: idx)
                        cleanupDrag()
                    }
                } else {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        cleanupDrag(animatedOnly: true)
                    }
                }
            }
    }

    private func placeIntoSpotHistory(_ ticket: KDSTicket, spotIndex: Int) {
        guard let i = incoming.firstIndex(where: { $0.id == ticket.id }) else { return }
        let moved = incoming.remove(at: i)

        var history = spotHistory[spotIndex]
        history.insert(SpotEntry(ticket: moved, placedAt: Date(), bartender: bartenderName), at: 0)
        if history.count > 5 { history = Array(history.prefix(5)) }
        spotHistory[spotIndex] = history
    }

    private func moveEntryToReturns(fromSpotIndex: Int, entry: SpotEntry) {
        guard returnsIndex != fromSpotIndex else { return }

        if let idx = spotHistory[fromSpotIndex].firstIndex(where: { $0.id == entry.id }) {
            spotHistory[fromSpotIndex].remove(at: idx)
        }

        var returns = spotHistory[returnsIndex]
        returns.insert(entry, at: 0)
        if returns.count > 5 { returns = Array(returns.prefix(5)) }
        spotHistory[returnsIndex] = returns
    }

    private func cleanupDrag(animatedOnly: Bool = false) {
        if !animatedOnly {
            draggingTicket = nil
            draggingId = nil
        }
        dragTranslation = .zero
        hoveredSpot = nil
        isDropping = false
    }

    private func hoverSpotIndex(for point: CGPoint) -> Int? {
        for (idx, rect) in spotFrames {
            if rect.contains(point) { return idx }
        }
        return nil
    }
}

// MARK: - Ticket Card (grayscale)

struct KDSTicketCard: View {
    let ticket: KDSTicket

    var body: some View {
        VStack(spacing: 0) {

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {

                    HStack(spacing: 6) {
                        Text(ticket.orderNumber)
                            .font(.system(size: 12, weight: .bold))

                        Spacer(minLength: 0)

                        Text(ticket.elapsed)
                            .font(.system(size: 11, weight: .bold))
                            .opacity(0.85)
                    }

                    Text(ticket.tableOrChannel)
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.85)

                    Text(ticket.service)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.6)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(.black)
            .background(Color.black.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ticket.lines.prefix(6)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(line.qty)")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16, alignment: .leading)

                            Text(line.name)
                                .font(.system(size: 12, weight: line.isAlert ? .bold : .semibold))
                                .opacity(line.isAlert ? 0.95 : 0.9)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if let p = line.priceText {
                                Text(p)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.5))
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 1)
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Spots History Bar (big number header, returns label on spot 6)

struct SpotsHistoryBar: View {
    let pickupCount: Int
    @Binding var histories: [[SpotEntry]]
    var hoveredIndex: Int?
    var onReturnEntry: (Int, SpotEntry) -> Void

    private var total: Int { pickupCount + 1 }
    private var returnsIndex: Int { total - 1 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<total, id: \.self) { idx in
                SpotHistoryCell(
                    spotNumber: idx + 1,
                    entries: histories[idx],
                    isHovering: hoveredIndex == idx,
                    isReturnsSpot: idx == returnsIndex,
                    onReturn: { entry in onReturnEntry(idx, entry) }
                )
                .background(
                    GeometryReader { g in
                        Color.clear
                            .preference(key: SpotFrameKey.self, value: [idx: g.frame(in: .global)])
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

struct SpotHistoryCell: View {
    let spotNumber: Int
    let entries: [SpotEntry]
    let isHovering: Bool
    let isReturnsSpot: Bool
    let onReturn: (SpotEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(spotNumber)")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.black.opacity(0.90))

                if isReturnsSpot {
                    Text("Returns")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Capsule())
                }

                Spacer()
            }

            if entries.isEmpty {
                Text(isHovering ? "DROP" : "—")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black.opacity(isHovering ? 0.65 : 0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries.prefix(5)) { e in
                            SpotHistoryRow(
                                entry: e,
                                showReturn: !isReturnsSpot,
                                onReturn: { onReturn(e) }
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: 190, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(isHovering ? 0.06 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(isHovering ? 0.28 : 0.12), lineWidth: isHovering ? 2 : 1)
        )
    }
}

struct SpotHistoryRow: View {
    let entry: SpotEntry
    let showReturn: Bool
    let onReturn: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.ticket.tableOrChannel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.9))
                    .lineLimit(1)

                Text(entry.ticket.lines.prefix(2).map { "\($0.qty)x \($0.name)" }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.70))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(entry.bartender)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.45))
                    Spacer()
                    Text(timeAgo(entry.placedAt))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.45))
                }
            }

            Spacer(minLength: 0)

            if showReturn {
                Button(action: onReturn) {
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white) // ✅ white rows on slot
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m"
    }
}

// MARK: - Preview

#Preview {
    BarKDSBoardView()
}

import SwiftUI

struct CustomerSpot: Identifiable {
    let id: Int          // 1...5
    let name: String?    // nil = empty
    let subtitle: String?
}

struct CustomerSpotView: View {

    // Demo data – in real life this comes from WebSocket / shared model
    let spots: [CustomerSpot] = [
        .init(id: 1, name: nil,   subtitle: nil),
        .init(id: 2, name: "YAEL", subtitle: "Latte Oat"),
        .init(id: 3, name: "OMER", subtitle: "Cappuccino"),
        .init(id: 4, name: nil,   subtitle: nil),
        .init(id: 5, name: "TOM",  subtitle: "Americano")
    ]

    var body: some View {
        VStack(spacing: 36) {

            // Header
            Text("READY AT BAR")
                .font(.system(size: 28, weight: .bold))
                
                .opacity(0.85)

            // Spots
            HStack(spacing: 36) {
                ForEach(spots) { spot in
                    SpotTile(spot: spot)
                }
            }

            // Footer hint
            Text("Please wait near your number")
                .font(.system(size: 18, weight: .semibold))
                .opacity(0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Spot Tile

private struct SpotTile: View {
    let spot: CustomerSpot

    var body: some View {
        VStack(spacing: 14) {

            // Big number
            Text("\(spot.id)")
                .font(.system(size: 72, weight: .black))
                .opacity(spot.name == nil ? 0.25 : 0.9)

            // Name (appears only when ready)
            if let name = spot.name {
                Text(name)
                    .font(.system(size: 22, weight: .bold))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .bold))
                    .opacity(0.15)
            }

            // Optional subtitle (drink)
            if let sub = spot.subtitle {
                Text(sub)
                    .font(.system(size: 16, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .frame(width: 160, height: 220)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: spot.name)
    }
}

// MARK: - Preview

#Preview {
    CustomerSpotView()
}
