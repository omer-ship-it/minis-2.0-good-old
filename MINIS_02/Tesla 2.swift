import SwiftUI

// MARK: - Model

private struct TableModel: Identifiable, Equatable {
    let id: Int
    var isOccupied: Bool
}

private struct TableSpot: Identifiable, Equatable {
    let id: Int                 // tableId
    var x: CGFloat              // 0...1
    var y: CGFloat              // 0...1
}

private struct SpaceModel: Identifiable, Equatable {
    let id: String              // "main" / "balcony" / "garden"
    let title: String
    var tables: [TableModel]
    var layout: [TableSpot]
}

// MARK: - Bar Persistence (per space)

private enum MapBarKeys {
    static let storage = "restaurant.map.bar.v1"
}

private struct SavedBar: Codable, Equatable {
    let x: Double     // 0...1
    let y: Double     // 0...1
    let angle: Double // radians
}

private enum MapBarStore {
    typealias Payload = [String: SavedBar] // spaceId -> bar

    static func load() -> Payload {
        guard let data = UserDefaults.standard.data(forKey: MapBarKeys.storage),
              let obj = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [:] }
        return obj
    }

    static func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: MapBarKeys.storage)
    }

    static func set(spaceId: String, x: CGFloat, y: CGFloat, angle: CGFloat) {
        var payload = load()
        payload[spaceId] = SavedBar(x: Double(x), y: Double(y), angle: Double(angle))
        save(payload)
    }

    static func get(spaceId: String) -> SavedBar? {
        load()[spaceId]
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: MapBarKeys.storage)
    }
}

// MARK: - Layout Persistence (per space)

private enum MapLayoutKeys {
    static let storage = "restaurant.map.layout.v1"
}

private struct SavedSpot: Codable, Equatable {
    let x: Double
    let y: Double
}

private enum MapLayoutStore {
    typealias Payload = [String: [Int: SavedSpot]] // spaceId -> tableId -> spot

    static func load() -> Payload {
        guard let data = UserDefaults.standard.data(forKey: MapLayoutKeys.storage),
              let obj = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [:] }
        return obj
    }

    static func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: MapLayoutKeys.storage)
    }

    static func setSpot(spaceId: String, tableId: Int, x: CGFloat, y: CGFloat) {
        var payload = load()
        var space = payload[spaceId] ?? [:]
        space[tableId] = SavedSpot(x: Double(x), y: Double(y))
        payload[spaceId] = space
        save(payload)
    }

    static func applySavedLayout(to spaces: inout [SpaceModel]) {
        let payload = load()
        guard !payload.isEmpty else { return }

        for sIdx in spaces.indices {
            let spaceId = spaces[sIdx].id
            guard let saved = payload[spaceId], !saved.isEmpty else { continue }

            for lIdx in spaces[sIdx].layout.indices {
                let tableId = spaces[sIdx].layout[lIdx].id
                if let spot = saved[tableId] {
                    spaces[sIdx].layout[lIdx].x = CGFloat(spot.x)
                    spaces[sIdx].layout[lIdx].y = CGFloat(spot.y)
                }
            }
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: MapLayoutKeys.storage)
    }
}

// MARK: - Local Service Requests

private enum ServiceRequestType: String, Codable { case assistance }

private struct ServiceRequest: Codable, Identifiable, Equatable {
    var id: String { "table:\(tableId)" }
    let tableId: Int
    let type: ServiceRequestType
    let createdAt: Date
}

private enum ServiceRequestKeys {
    static let storage = "service.requests.v1"
    static let changed = Notification.Name("service.requests.changed")
}

private enum ServiceRequests {
    static func load() -> [ServiceRequest] {
        guard let data = UserDefaults.standard.data(forKey: ServiceRequestKeys.storage),
              let arr = try? JSONDecoder().decode([ServiceRequest].self, from: data)
        else { return [] }
        return arr
    }

    static func save(_ arr: [ServiceRequest]) {
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: ServiceRequestKeys.storage)
        }
        NotificationCenter.default.post(name: ServiceRequestKeys.changed, object: nil)
    }

    static func clear(tableId: Int) {
        var arr = load()
        arr.removeAll { $0.tableId == tableId }
        save(arr)
    }
}

// MARK: - Main View

struct AppleHomeStyleRestaurantMap: View {

    @State private var spaceIndex: Int = 0
    @State private var spaces: [SpaceModel] = [
        SpaceModel(
            id: "main",
            title: "Main",
            tables: [
                .init(id: 1, isOccupied: true),
                .init(id: 2, isOccupied: false),
                .init(id: 3, isOccupied: true),
                .init(id: 4, isOccupied: false),
                .init(id: 5, isOccupied: false),
                .init(id: 6, isOccupied: true),
                .init(id: 7, isOccupied: true),
                .init(id: 8, isOccupied: true),
            ],
            layout: [
                .init(id: 1, x: 0.18, y: 0.45),
                .init(id: 2, x: 0.38, y: 0.45),
                .init(id: 3, x: 0.58, y: 0.45),
                .init(id: 4, x: 0.78, y: 0.45),
                .init(id: 5, x: 0.18, y: 0.74),
                .init(id: 6, x: 0.38, y: 0.74),
                .init(id: 7, x: 0.58, y: 0.74),
                .init(id: 8, x: 0.78, y: 0.74),
            ]
        ),
        SpaceModel(
            id: "balcony",
            title: "Balcony",
            tables: [
                .init(id: 101, isOccupied: false),
                .init(id: 102, isOccupied: true),
                .init(id: 103, isOccupied: false),
                .init(id: 104, isOccupied: true),
                .init(id: 105, isOccupied: false),
                .init(id: 106, isOccupied: false),
            ],
            layout: [
                .init(id: 101, x: 0.20, y: 0.40),
                .init(id: 102, x: 0.50, y: 0.36),
                .init(id: 103, x: 0.80, y: 0.40),
                .init(id: 104, x: 0.28, y: 0.74),
                .init(id: 105, x: 0.55, y: 0.80),
                .init(id: 106, x: 0.80, y: 0.74),
            ]
        ),
        SpaceModel(
            id: "garden",
            title: "Garden",
            tables: [
                .init(id: 201, isOccupied: true),
                .init(id: 202, isOccupied: true),
                .init(id: 203, isOccupied: false),
                .init(id: 204, isOccupied: false),
                .init(id: 205, isOccupied: false),
                .init(id: 206, isOccupied: true),
                .init(id: 207, isOccupied: false),
                .init(id: 208, isOccupied: false),
                .init(id: 209, isOccupied: true),
            ],
            layout: [
                .init(id: 201, x: 0.18, y: 0.35),
                .init(id: 202, x: 0.40, y: 0.30),
                .init(id: 203, x: 0.62, y: 0.35),
                .init(id: 204, x: 0.82, y: 0.30),
                .init(id: 205, x: 0.15, y: 0.70),
                .init(id: 206, x: 0.35, y: 0.78),
                .init(id: 207, x: 0.55, y: 0.70),
                .init(id: 208, x: 0.75, y: 0.78),
                .init(id: 209, x: 0.88, y: 0.68),
            ]
        )
    ]

    @State private var isEditingLayout: Bool = false
    @State private var barBySpace: [String: SavedBar] = [:]

    @State private var selectedTableId: Int? = nil
    @State private var pendingCovers: Int = 2
    @State private var showCoversSheet: Bool = false
    @State private var goToMenu: Bool = false

    @State private var serviceRequests: [ServiceRequest] = ServiceRequests.load()

    private var currentSpace: SpaceModel {
        spaces[min(max(spaceIndex, 0), max(spaces.count - 1, 0))]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 0) {
                    topBar

                    spaceSwitcher
                        .frame(height: 360)
                        .padding(.top, 6)

                    serviceRequestList
                        .padding(.top, 12)

                    Spacer()
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                serviceRequests = ServiceRequests.load()

                var copy = spaces
                MapLayoutStore.applySavedLayout(to: &copy)
                spaces = copy

                barBySpace = MapBarStore.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: ServiceRequestKeys.changed)) { _ in
                serviceRequests = ServiceRequests.load()
            }
            .navigationDestination(isPresented: $goToMenu) {
                menuView()
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showCoversSheet) {
                CoversPickerSheet(
                    defaultCovers: pendingCovers,
                    onPick: { covers in
                        pendingCovers = covers
                        if let tid = selectedTableId {
                            // Your existing waiter-mode bridge:
                            enterWaiterMode(tableId: tid, covers: covers)

                            if let sIdx = spaces.firstIndex(where: { $0.tables.contains(where: { $0.id == tid }) }),
                               let tIdx = spaces[sIdx].tables.firstIndex(where: { $0.id == tid }) {
                                spaces[sIdx].tables[tIdx].isOccupied = true
                            }
                        }

                        showCoversSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            goToMenu = true
                        }
                    },
                    onCancel: { showCoversSheet = false }
                )
                // ✅ Removed presentationDetents / dragIndicator to avoid build errors across targets
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        Color(red: 0.13, green: 0.13, blue: 0.14).ignoresSafeArea()
    }

    // MARK: - Top Bar

    private var topBar: some View {
        let pct = occupancyPercent(tables: currentSpace.tables)

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Beit Haam")
                        .font(.system(size: 22, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }

                Text("\(currentSpace.title) • Occupied \(pct)%")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        isEditingLayout.toggle()
                    }
                } label: {
                    topIcon(isEditingLayout ? "checkmark.circle.fill" : "square.and.pencil")
                }
                .buttonStyle(.plain)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    MapLayoutStore.reset()
                    MapBarStore.reset()
                    barBySpace.removeAll()
                    isEditingLayout = false
                } label: {
                    topIcon("arrow.counterclockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func topIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    // MARK: - Space switcher + swipe maps

    private var spaceSwitcher: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(spaces.enumerated()), id: \.offset) { idx, sp in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                spaceIndex = idx
                            }
                        } label: {
                            Text(sp.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(spaceIndex == idx ? .black : .white.opacity(0.9))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule()
                                        .fill(spaceIndex == idx ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(spaceIndex == idx ? 0.12 : 0.10), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
            }

            TabView(selection: $spaceIndex) {
                ForEach(Array(spaces.enumerated()), id: \.offset) { idx, _ in
                    mapForSpace(spaceIdx: idx)
                        .tag(idx)
                        .padding(.horizontal, 12)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    // MARK: - Map

    private func mapForSpace(spaceIdx: Int) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                draggableBar(spaceIdx: spaceIdx, w: w, h: h)

                ForEach(spaces[spaceIdx].layout) { spot in
                    draggableTable(tableId: spot.id, spaceIdx: spaceIdx, w: w, h: h)
                }
            }
        }
    }

    // MARK: - Drag Helpers

    private func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    private func updateSpot(spaceIdx: Int, tableId: Int, normX: CGFloat, normY: CGFloat) {
        guard let spotIdx = spaces[spaceIdx].layout.firstIndex(where: { $0.id == tableId }) else { return }
        spaces[spaceIdx].layout[spotIdx].x = clamp01(normX)
        spaces[spaceIdx].layout[spotIdx].y = clamp01(normY)

        MapLayoutStore.setSpot(
            spaceId: spaces[spaceIdx].id,
            tableId: tableId,
            x: spaces[spaceIdx].layout[spotIdx].x,
            y: spaces[spaceIdx].layout[spotIdx].y
        )
    }
    // MARK: - Draggable Table Node

    private struct DraggableTableNode: View {
        let tableId: Int
        let occupied: Bool
        let hasCall: Bool

        let w: CGFloat
        let h: CGFloat

        let normX: CGFloat
        let normY: CGFloat

        let isEditing: Bool                // ✅ new
        let onTap: () -> Void
        let onMove: (CGFloat, CGFloat) -> Void

        @State private var dragStart: CGPoint? = nil
        @State private var didDrag: Bool = false

        var body: some View {
            let x = w * normX
            let y = h * normY

            let drag = DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard isEditing else { return }   // ✅ only drag in edit mode

                    if dragStart == nil {
                        dragStart = CGPoint(x: normX, y: normY)
                        didDrag = false
                    }

                    guard let start = dragStart else { return }
                    didDrag = true

                    let newNormX = clamp01(start.x + (value.translation.width / w))
                    let newNormY = clamp01(start.y + (value.translation.height / h))

                    onMove(newNormX, newNormY)
                }
                .onEnded { _ in
                    dragStart = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        didDrag = false
                    }
                }

            TableTile(isOccupied: occupied, seed: tableId, hasCall: hasCall)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
                .position(x: x, y: y)
                .highPriorityGesture(drag)            // beat TabView swipe
                .onTapGesture {
                    if !didDrag { onTap() }           // prevent tap after drag
                }
        }

        private func clamp01(_ v: CGFloat) -> CGFloat {
            min(max(v, 0), 1)
        }
    }

    @ViewBuilder
    private func draggableTable(tableId: Int, spaceIdx: Int, w: CGFloat, h: CGFloat) -> some View {
        if let tIdx = spaces[spaceIdx].tables.firstIndex(where: { $0.id == tableId }),
           let sIdx = spaces[spaceIdx].layout.firstIndex(where: { $0.id == tableId }) {

            let occupied = spaces[spaceIdx].tables[tIdx].isOccupied
            let hasCall = serviceRequests.contains { $0.tableId == tableId && $0.type == .assistance }

            let normX = spaces[spaceIdx].layout[sIdx].x
            let normY = spaces[spaceIdx].layout[sIdx].y

            DraggableTableNode(
                tableId: tableId,
                occupied: occupied,
                hasCall: hasCall,
                w: w,
                h: h,
                normX: normX,
                normY: normY,
                isEditing: isEditingLayout,
                onTap: {
                    guard !isEditingLayout else { return }

                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedTableId = tableId

                    if occupied {
                        enterWaiterMode(tableId: tableId, covers: nil)
                        goToMenu = true
                    } else {
                        pendingCovers = 2
                        showCoversSheet = true
                    }
                },
                onMove: { newNormX, newNormY in
                    guard isEditingLayout else { return }
                    updateSpot(spaceIdx: spaceIdx, tableId: tableId, normX: newNormX, normY: newNormY)
                }
            )
        } else {
            EmptyView()
        }
    }

    // MARK: - Bar drag + rotate

    @ViewBuilder
    private func draggableBar(spaceIdx: Int, w: CGFloat, h: CGFloat) -> some View {
        let spaceId = spaces[spaceIdx].id

        let defaultX: CGFloat = 0.50
        let defaultY: CGFloat = clamp01((h * 0.12 + 28) / max(h, 1)) // old padding vibe
        let saved = barBySpace[spaceId] ?? MapBarStore.get(spaceId: spaceId)

        let normX = CGFloat(saved?.x ?? Double(defaultX))
        let normY = CGFloat(saved?.y ?? Double(defaultY))
        let angle = CGFloat(saved?.angle ?? 0)

        DraggableBarNode(
            seed: 99 + spaceIdx * 7,
            w: w,
            h: h,
            normX: normX,
            normY: normY,
            angle: angle,
            isEditing: isEditingLayout,
            onUpdate: { newX, newY, newAngle in
                let clampedX = clamp01(newX)
                let clampedY = clamp01(newY)

                let bar = SavedBar(x: Double(clampedX), y: Double(clampedY), angle: Double(newAngle))
                barBySpace[spaceId] = bar
                MapBarStore.set(spaceId: spaceId, x: clampedX, y: clampedY, angle: newAngle)
            }
        )
    }

    // MARK: - Service List

    private var serviceRequestList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tasks")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()

                if !serviceRequests.isEmpty {
                    Text("\(serviceRequests.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 20)

            if serviceRequests.isEmpty {
                Text("No active requests")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(serviceRequests.sorted(by: { $0.createdAt < $1.createdAt })) { req in
                        serviceRow(req)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func serviceRow(_ req: ServiceRequest) -> some View {
        let tableLabel = "Table \(req.tableId)"

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            enterWaiterMode(tableId: req.tableId, covers: nil)
            ServiceRequests.clear(tableId: req.tableId)
            serviceRequests = ServiceRequests.load()

            goToMenu = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tableLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)

                    Text("Assistance requested")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.25))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func occupancyPercent(tables: [TableModel]) -> Int {
        guard !tables.isEmpty else { return 0 }
        let occ = tables.filter { $0.isOccupied }.count
        return Int((Double(occ) / Double(tables.count) * 100).rounded())
    }

    // MARK: - Hook points (project-specific)

    private func enterWaiterMode(tableId: Int, covers: Int?) {
        // Your existing keys/types live in your project:
        UserDefaults.standard.set(ExperienceMode.waiter.rawValue, forKey: ExperienceModeKeys.mode)
        UserDefaults.standard.set(tableId, forKey: WaiterOrderKeys.tableId)

        if let covers, covers > 0 {
            UserDefaults.standard.set(covers, forKey: WaiterOrderKeys.covers)
        } else if UserDefaults.standard.integer(forKey: WaiterOrderKeys.covers) == 0 {
            UserDefaults.standard.set(2, forKey: WaiterOrderKeys.covers)
        }
    }
}

// MARK: - Draggable Table Node

private struct DraggableBarNode: View {
    let seed: Int

    let w: CGFloat
    let h: CGFloat

    let normX: CGFloat
    let normY: CGFloat
    let angle: CGFloat          // ✅ radians

    // If you want "edit mode only", keep isEditing and gate hit testing/gestures.
    // If you want it ALWAYS draggable, set isEditing = true when you call it,
    // or remove the guards below.
    let isEditing: Bool

    // ✅ callback to persist updates
    let onUpdate: (CGFloat, CGFloat, CGFloat) -> Void

    @State private var dragStart: CGPoint? = nil
    @State private var rotStart: CGFloat? = nil

    var body: some View {
        let barW = w * 0.72
        let barH: CGFloat = 56

        let x = w * normX
        let y = h * normY

        let drag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard isEditing else { return }

                if dragStart == nil {
                    dragStart = CGPoint(x: normX, y: normY)
                }
                guard let start = dragStart else { return }

                let newX = clamp01(start.x + (value.translation.width / w))
                let newY = clamp01(start.y + (value.translation.height / h))

                onUpdate(newX, newY, angle)
            }
            .onEnded { _ in
                dragStart = nil
            }

        let rotate = RotationGesture()
            .onChanged { r in
                guard isEditing else { return }

                if rotStart == nil { rotStart = angle }
                let base = rotStart ?? angle

                // ✅ r is Angle, convert to radians
                onUpdate(normX, normY, base + CGFloat(r.radians))
            }
            .onEnded { _ in
                rotStart = nil
            }

        PlainWoodBar(seed: seed)
            .frame(width: barW, height: barH)
            .rotationEffect(.radians(angle))
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .allowsHitTesting(isEditing)      // edit-mode only
            .highPriorityGesture(drag)        // beat TabView swipe
            .simultaneousGesture(rotate)      // allow rotate + drag
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
}
// MARK: - Draggable Bar Node


// MARK: - Table Tile

private struct TableTile: View {
    let isOccupied: Bool
    let seed: Int
    let hasCall: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isOccupied {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(woodBase)
                    .overlay(
                        RealWoodGrain(seed: seed)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    )
                    .overlay(torchGlow.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1.2)
                    )
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            }

            if hasCall {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
            }
        }
        .frame(width: 72, height: 72)
    }

    private var torchGlow: some View {
        RadialGradient(
            colors: [
                Color(red: 1.0, green: 0.72, blue: 0.35).opacity(0.55),
                Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.22),
                Color.clear
            ],
            center: .top,
            startRadius: 6,
            endRadius: 70
        )
        .blendMode(.screen)
    }

    private var woodBase: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.64, green: 0.48, blue: 0.30),
                Color(red: 0.44, green: 0.33, blue: 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Plain Wood Bar

private struct PlainWoodBar: View {
    let seed: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.58, green: 0.44, blue: 0.30),
                        Color(red: 0.42, green: 0.32, blue: 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RealWoodGrain(seed: seed, horizontal: true)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .opacity(0.55)
            )
    }
}

// MARK: - Covers Picker Sheet (kept simple + compile-safe)

private struct CoversPickerSheet: View {
    let defaultCovers: Int
    let onPick: (Int) -> Void
    let onCancel: () -> Void

    @State private var selected: Int

    init(defaultCovers: Int, onPick: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.defaultCovers = defaultCovers
        self.onPick = onPick
        self.onCancel = onCancel
        _selected = State(initialValue: defaultCovers)
    }

    var body: some View {
        ZStack {
            Color(red: 0.13, green: 0.13, blue: 0.14).ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Text("Start order")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                Text("How many guests?")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)

                LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(1...10, id: \.self) { n in
                        Button {
                            selected = n
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text("\(n)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(selected == n ? .black : .white.opacity(0.9))
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(selected == n ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(selected == n ? 0.12 : 0.10), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)

                Spacer(minLength: 4)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onPick(selected)
                } label: {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.95))
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Wood Grain

private struct RealWoodGrain: View {
    let seed: Int
    var horizontal: Bool = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, _ in
                srand48(seed)
                let size = geo.size
                for i in 0..<12 {
                    let t = CGFloat(i) / 12
                    let rect = horizontal
                        ? CGRect(x: 0, y: t * size.height, width: size.width, height: 2)
                        : CGRect(x: t * size.width, y: 0, width: 2, height: size.height)
                    ctx.fill(Path(rect), with: .color(Color.white.opacity(0.04)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
