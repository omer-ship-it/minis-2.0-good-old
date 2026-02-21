import SwiftUI
import Kingfisher

// MARK: - A mutable draft of a product used for editing/creating

struct AdminProductDraft: Identifiable {
    let id = UUID()
    var productId: Int?

    var name: String
    var priceText: String
    var category: String
    var description: String
    var imageURL: String
    var modifierGroups: [AdminModifierGroupDraft]
    var legacyPrinter: String = "Bar"   // Bar / Kitchen / Bakery
    // ✅ PRIMARY (single route)
    var printerId: String

    // ✅ OPTIONAL (multi route) — checkboxes
    var printerIds: Set<String> = []

    // ✅ NEW: ask for phone
    var isPhoneRequired: Bool = false
}

// MARK: - Modifier drafts

struct AdminModifierGroupDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case options
        case additions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .options:   return "Options"
            case .additions: return "Extras"
            }
        }
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var items: [AdminModifierItemDraft]
}

struct AdminModifierItemDraft: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var extraPriceText: String   // text field backing for price
}

struct AdminProductEditorMode {
    enum Mode {
        case create
        case edit
    }
}

// MARK: - Admin Product Editor

struct AdminProductEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl

    @State private var draft: AdminProductDraft
    @State private var lastAddedGroupId: AdminModifierGroupDraft.ID?

    // 👇 keep a live local preview of the picked image
    @State private var pickedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isUploadingImage = false

    private let mode: AdminProductEditorMode.Mode
    private let onSave: (AdminProductDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onChangeImage: (() -> Void)?
    private let categories: [String]
   
    private func applyLegacyStation(_ s: LegacyStation) {
        draft.legacyPrinter = s.rawValue

        guard let id = stationId(for: s) else { return }

        // Make it the primary
        draft.printerId = id

        // Make the multi-select match the quick pick (single-route)
        draft.printerIds = [id]

        ensurePrinterSelectionNotEmpty()
        syncLegacySegmentFromCurrentSelection()
    }
    // ✅ printers config store (UserDefaults-backed)
    @ObservedObject private var printerStore = PrintersConfigStore.shared

    // ✅ KEEP OLD QUICK PICKER (segment) while testing
    private enum LegacyStation: String, CaseIterable, Identifiable {
        case bar = "Bar"
        case kitchen = "Kitchen"
        case bakery = "Bakery"
        var id: String { rawValue }

        func title(isRtl: Bool) -> String {
            switch self {
            case .bar:     return isRtl ? "בר" : "Bar"
            case .kitchen: return isRtl ? "מטבח" : "Kitchen"
            case .bakery:  return isRtl ? "מאפייה" : "Bakery"
            }
        }
    }

    @State private var legacyStation: LegacyStation = .bar

    init(
        draft: AdminProductDraft,
        mode: AdminProductEditorMode.Mode,
        categories: [String],
        onSave: @escaping (AdminProductDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onChangeImage: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)
        self.categories = categories
        if draft.priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self._draft.wrappedValue.priceText = "0.0"
        }

        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        self.onChangeImage = onChangeImage
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section { headerImageSection }
                    Section { mainFieldsSection }

                    Section(
                        header:
                            HStack {
                                Text(isRtl ? "תוספות / אפשרויות" : "Options & Extras")
                                    .font(.primariesDemi(18))
                                Spacer()
                                Button {
                                    addNewModifierGroup()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                }
                            }
                    ) {
                        if draft.modifierGroups.isEmpty {
                            Text(isRtl ? "אין תוספות" : "No modifiers yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(draft.modifierGroups) { group in
                                AdminModifierGroupEditor(
                                    group: binding(for: group),
                                    onDelete: { removeModifierGroup(group) }
                                )
                                .id(group.id)
                            }
                            .onMove(perform: moveModifierGroups)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .onChange(of: lastAddedGroupId) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(modeTitle)
                        .font(.primariesDemi(18))
                }
                if mode == .edit, let onDelete {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showImagePicker) {
                AdminImagePicker { image in
                    handlePickedImage(image)
                }
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        .onAppear {
            ensureValidPrinterId()
            ensurePrinterSelectionNotEmpty()
            syncLegacySegmentFromCurrentSelection()
        }
        .onChange(of: printerStore.config.stations) { _ in
            ensureValidPrinterId()
            ensurePrinterSelectionNotEmpty()
            syncLegacySegmentFromCurrentSelection()
        }
    }

    private var modeTitle: String {
        switch mode {
        case .create: return isRtl ? "מוצר חדש" : "New Product"
        case .edit:   return isRtl ? "עריכת מוצר" : "Edit Product"
        }
    }

    // MARK: - Printers helpers (ID routing)

    private var activeStations: [PrinterStation] {
        printerStore.config.stations.filter { $0.status != 0 }
    }

    /// Accepts:
    /// - station id (preferred) e.g. "s1"
    /// - legacy strings like "Bar"/"Kitchen"/"Bakery" or Hebrew variants
    /// - label match (if someone stored label instead of id)
    /// Returns a station id.
    private func normalizePrinterId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return activeStations.first?.id ?? "" }

        // already a valid station id?
        if activeStations.contains(where: { $0.id == trimmed }) { return trimmed }

        // If someone stored legacy strings ("Bar"/"Bakery"/"Kitchen"), map them to your forced ids:
        let t = trimmed.lowercased()
        if t.contains("bar") || t.contains("בר") { return "s2" }
        if t.contains("bakery") || t.contains("מאפ") || t.contains("ויטרינה") { return "s3" }
        if t.contains("kitchen") || t.contains("מטבח") { return "s1" } // will still become Bakery by your rule

        // fallback
        return activeStations.first?.id ?? ""
    }

    private func ensureValidPrinterId() {
        let normalized = normalizePrinterId(draft.printerId)
        if draft.printerId != normalized {
            draft.printerId = normalized
        }

        // If still empty (no stations configured), leave empty (UI will show "לא מוגדר")
        if draft.printerId.isEmpty, let first = activeStations.first?.id {
            draft.printerId = first
        }
    }

    private func ensurePrinterSelectionNotEmpty() {
        // If no stations: just keep empty (UI will say "not configured")
        guard !activeStations.isEmpty else { return }

        // If multi set empty -> seed from primary or first station
        if draft.printerIds.isEmpty {
            if !draft.printerId.isEmpty {
                draft.printerIds = [draft.printerId]
            } else if let first = activeStations.first?.id {
                draft.printerId = first
                draft.printerIds = [first]
            }
        }

        // Ensure primary is always in the set
        if !draft.printerId.isEmpty, !draft.printerIds.contains(draft.printerId) {
            draft.printerIds.insert(draft.printerId)
        }

        // Ensure primary isn't empty if set has items
        if draft.printerId.isEmpty, let any = draft.printerIds.first {
            draft.printerId = any
        }
    }

    private func printerLabel(for printerId: String) -> String {
        if let s = activeStations.first(where: { $0.id == printerId }) { return s.label }
        return isRtl ? "לא מוגדר" : "Not set"
    }

    private func stationId(for legacy: LegacyStation) -> String? {
        switch legacy {
        case .bar:
            return activeStations.first(where: {
                $0.label.lowercased().contains("bar") || $0.label.contains("בר")
            })?.id
        case .kitchen:
            return activeStations.first(where: {
                $0.label.lowercased().contains("kitchen") || $0.label.contains("מטבח")
            })?.id
        case .bakery:
            return activeStations.first(where: {
                $0.label.lowercased().contains("bakery") || $0.label.contains("מאפ") || $0.label.contains("ויטרינה")
            })?.id
        }
    }

    private func syncLegacySegmentFromCurrentSelection() {

        // ✅ 1) Prefer the legacy value coming from DB
        let raw = draft.legacyPrinter.trimmingCharacters(in: .whitespacesAndNewlines)

        
        // ✅ 2) Fallback: if legacy is missing, infer from printerId (s1/s2/s3 or labels)
        let pid = draft.printerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if pid == "s1" { legacyStation = .kitchen; return }
        if pid == "s2" { legacyStation = .bar;     return }
        if pid == "s3" { legacyStation = .bakery;  return }

        // If printerId is not sX, try station label (your existing logic)
        guard let st = activeStations.first(where: { $0.id == draft.printerId }) else {
            legacyStation = .bar
            return
        }

        let l = st.label.lowercased()
        if l.contains("kitchen") || st.label.contains("מטבח") {
            legacyStation = .kitchen
        } else if l.contains("bakery") || st.label.contains("מאפ") || st.label.contains("ויטרינה") {
            legacyStation = .bakery
        } else {
            legacyStation = .bar
        }
    }

    private func toggleStation(_ id: String) {
        // Prevent empty selection
        if draft.printerIds.contains(id) {
            if draft.printerIds.count <= 1 {
                Haptics.error()
                return
            }
            draft.printerIds.remove(id)

            // if removing primary, pick a new primary
            if draft.printerId == id {
                draft.printerId = draft.printerIds.first ?? ""
            }
        } else {
            draft.printerIds.insert(id)
            if draft.printerId.isEmpty { draft.printerId = id }
        }

        ensurePrinterSelectionNotEmpty()
        syncLegacySegmentFromCurrentSelection()
        Haptics.light()
    }

    // MARK: - Image header

    private var headerImageSection: some View {
        VStack(spacing: 8) {

            // Resolve a remote URL only when we *don't* have a local preview
            let remoteURL: URL? = {
                let trimmed = draft.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                    return URL(string: trimmed)
                } else {
                    return URL(string: "https://minitel.co.uk/images/\(trimmed).png")
                }
            }()

            ZStack {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 220)
                    .overlay(
                        Group {
                            if let img = pickedImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                            } else if let url = remoteURL {
                                KFImage(url)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                            } else {
                                Text(isRtl ? "הוסף תמונה" : "Add image")
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
                    .clipped()
                    .onTapGesture {
                        showImagePicker = true
                    }

                if isUploadingImage {
                    ZStack {
                        Color.black.opacity(0.25)
                        ProgressView(isRtl ? "מעלה תמונה…" : "Uploading…")
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if onChangeImage == nil {
                HStack {
                    Text(isRtl ? "קישור לתמונה" : "Image URL")
                        .font(.primariesDemi(14))
                    TextField(isRtl ? "shop12_croissant" : "shop12_croissant",
                              text: $draft.imageURL)
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Button { showImagePicker = true } label: {
                    Text(isRtl ? "בחירת תמונה" : "Change Image")
                        .font(.primariesDemi(15))
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Called when the user picks an image from the gallery.
    private func handlePickedImage(_ image: UIImage) {
        self.pickedImage = image
        isUploadingImage = true

        let shopId = UserDefaults.standard.string(forKey: "shopId") ?? "0"
        let productIdPart = draft.productId.map { "prod\($0)" } ?? "new"
        let ts = Int(Date().timeIntervalSince1970)
        let slugName = draft.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        let imageName = "shop\(shopId)_\(productIdPart)_\(ts)_\(slugName)"

        saveImageToServer(image: image, imageName: imageName) { result in
            DispatchQueue.main.async {
                self.isUploadingImage = false
                switch result {
                case .success(let savedName):
                    let encoded = savedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? savedName
                    self.draft.imageURL = "https://minitel.co.uk/images/uploads/\(encoded).png"
                case .failure(let error):
                    print("❌ image upload failed:", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Main fields

    private var mainFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            // NAME
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "שם המוצר" : "Name")
                    .font(.primariesDemi(14))
                TextField("",
                          text: $draft.name,
                          prompt: Text(isRtl ? "שם המוצר" : "Name"))
                    .font(.custom(primariesFontName, size: 18))
                    .textFieldStyle(.roundedBorder)
            }

            // PRICE + CATEGORY (picker + add)
            HStack(spacing: 12) {

                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "מחיר" : "Price")
                        .font(.primariesDemi(14))
                    PriceTextField(text: $draft.priceText)
                        .frame(height: 36)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "קטגוריה" : "Category")
                        .font(.primariesDemi(14))

                    CategoryPickerField(
                        isRtl: isRtl,
                        categories: categories,          // ✅ requires `let categories: [String]` in the view
                        selected: $draft.category
                    )
                }
            }

            // DESCRIPTION
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "תיאור" : "Description")
                    .font(.primariesDemi(14))
                TextField(isRtl ? "תיאור קצר" : "Short description",
                          text: $draft.description,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
            }

            // EXTRA: PHONE REQUIRED
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "פרטים נוספים" : "Extra")
                    .font(.primariesDemi(14))

                Toggle(isRtl ? "טלפון נדרש" : "Phone required", isOn: $draft.isPhoneRequired)
                    .font(.system(size: 16, weight: .semibold))
                    .toggleStyle(.switch)
            }
            .padding(.top, 4)

            // ✅ PRINTERS: keep old segment + new multi-select checkboxes
            VStack(alignment: .leading, spacing: 8) {
                Text(isRtl ? "מדפסות" : "Printers")
                    .font(.primariesDemi(14))

                if activeStations.isEmpty {
                    Text(isRtl ? "לא הוגדרו מדפסות עדיין" : "No printers configured yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                  
                    // ✅ OLD (KEEP): segmented quick route
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isRtl ? "בחירה מהירה" : "Quick route")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $legacyStation) {
                            ForEach(LegacyStation.allCases) { s in
                                Text(s.title(isRtl: isRtl)).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(.primary)
                        .onChange(of: legacyStation) { newValue in
                            switch newValue {
                            case .bar:     draft.printerId = "s2"; draft.printerIds = ["s2"]
                            case .kitchen: draft.printerId = "s1"; draft.printerIds = ["s1"]
                            case .bakery:  draft.printerId = "s3"; draft.printerIds = ["s3"]
                            }
                            draft.legacyPrinter = legacyNameForStationId(draft.printerId) // forced
                            ensurePrinterSelectionNotEmpty()
                            Haptics.light()
                        }
                    }
                    .padding(.bottom, 6)
                  

                    // ✅ NEW: multi-select checkboxes
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isRtl ? "הדפס גם ל…" : "Also print to…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            ForEach(activeStations) { st in
                                let checked = draft.printerIds.contains(st.id)
                                Button {
                                    toggleStation(st.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(checked ? .primary : .secondary)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(st.label)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.primary)

                                            Text("\(printerStore.config.netPrefix)\(st.octet)")
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .offset(y: -2)
                                        }

                                        Spacer()

                                        if draft.printerId == st.id {
                                            Text(isRtl ? "ראשי" : "Primary")
                                                .font(.system(size: 12, weight: .bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color(.systemGray5))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Selected summary
                    let selectedLabels = activeStations
                        .filter { draft.printerIds.contains($0.id) }
                        .map { $0.label }
                    if !selectedLabels.isEmpty {
                        Text((isRtl ? "נבחרו: " : "Selected: ") + selectedLabels.joined(separator: ", "))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: - Category picker + add new
    private struct CategoryPickerField: View {
        let isRtl: Bool
        let categories: [String]
        @Binding var selected: String

        @State private var showAdd = false
        @State private var newCategory = ""

        private var cleanedCategories: [String] {
            // unique + stable order + no blanks
            var seen = Set<String>()
            return categories.compactMap { raw in
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                guard !seen.contains(t) else { return nil }
                seen.insert(t)
                return t
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {

                Menu {
                    ForEach(cleanedCategories, id: \.self) { c in
                        Button(c) { selected = c }
                    }

                    // if draft.category is custom and not in list, keep it visible
                    let current = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !current.isEmpty, !cleanedCategories.contains(current) {
                        Divider()
                        Button(current) { selected = current }
                    }

                    Divider()

                    Button {
                        newCategory = ""
                        showAdd = true
                    } label: {
                        Label(isRtl ? "קטגוריה חדשה" : "Add category", systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? (isRtl ? "בחר קטגוריה" : "Choose category")
                             : selected)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    VStack(spacing: 16) {
                        Text(isRtl ? "קטגוריה חדשה" : "New category")
                            .font(.system(size: 20, weight: .bold))
                            .padding(.top, 10)

                        TextField(isRtl ? "שם קטגוריה" : "Category name", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 16)

                        Button {
                            let t = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            selected = t
                            showAdd = false
                        } label: {
                            Text(isRtl ? "שמור" : "Save")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal, 16)

                        Spacer()
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { showAdd = false } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .padding(8)
                                    .background(Color(.systemGray5))
                                    .clipShape(Circle())
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                let price = Double(draft.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                var cleanDraft = cleanedForSave(draft)
                cleanDraft.priceText = String(format: "%.2f", price)

                // ✅ ensure printer selections are valid + non-empty
                cleanDraft.printerId = normalizePrinterId(cleanDraft.printerId)

                if cleanDraft.printerIds.isEmpty {
                    if !cleanDraft.printerId.isEmpty {
                        cleanDraft.printerIds = [cleanDraft.printerId]
                    }
                } else {
                    cleanDraft.printerIds.insert(cleanDraft.printerId)
                }

                onSave(cleanDraft)
                dismiss()
            } label: {
                Text(mode == .create ? (isRtl ? "הוסף מוצר" : "Create")
                                     : (isRtl ? "שמור שינויים" : "Save"))
                    .font(.primariesDemi(17))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Cleaning + helpers

    private func cleanedForSave(_ draft: AdminProductDraft) -> AdminProductDraft {
        var copy = draft

        // (your existing modifier cleanup stays)

        copy.printerId = normalizePrinterId(copy.printerId)

        if copy.printerIds.isEmpty {
            if !copy.printerId.isEmpty { copy.printerIds = [copy.printerId] }
        } else {
            if !copy.printerId.isEmpty { copy.printerIds.insert(copy.printerId) }
        }

        // ✅ FORCE legacy string from station id (ignore segment)
        copy.legacyPrinter = legacyNameForStationId(copy.printerId)

        return copy
    }

    private func binding(for group: AdminModifierGroupDraft) -> Binding<AdminModifierGroupDraft> {
        Binding(
            get: {
                draft.modifierGroups.first(where: { $0.id == group.id }) ?? group
            },
            set: { newValue in
                if let idx = draft.modifierGroups.firstIndex(where: { $0.id == group.id }) {
                    draft.modifierGroups[idx] = newValue
                }
            }
        )
    }

    private func removeModifierGroup(_ group: AdminModifierGroupDraft) {
        if let idx = draft.modifierGroups.firstIndex(where: { $0.id == group.id }) {
            draft.modifierGroups.remove(at: idx)
        }
    }

    private func moveModifierGroups(from source: IndexSet, to destination: Int) {
        draft.modifierGroups.move(fromOffsets: source, toOffset: destination)
    }

    private func addNewModifierGroup() {
        let new = AdminModifierGroupDraft(
            title: "",
            kind: .options,
            items: []
        )
        draft.modifierGroups.append(new)
        lastAddedGroupId = new.id
    }
}

// MARK: - Modifier Group Editor (unchanged)

struct AdminModifierGroupEditor: View {
    @Environment(\.isRtl) private var isRtl
    @State private var showDeleteAlert = false
    @Binding var group: AdminModifierGroupDraft
    let onDelete: () -> Void

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "",
                        text: $group.title,
                        prompt: Text(isRtl ? "קבוצה חדשה" : "New group")
                    )
                    .font(.primariesDemi(15))
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFocused)

                    Picker("", selection: $group.kind) {
                        Text(isRtl ? "אפשרויות" : "Options")
                            .tag(AdminModifierGroupDraft.Kind.options)
                        Text(isRtl ? "תוספות" : "Additions")
                            .tag(AdminModifierGroupDraft.Kind.additions)
                    }
                    .pickerStyle(.segmented)
                }

                Spacer()

                Button {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(6)
                }
                .buttonStyle(.borderless)
                .alert(isPresented: $showDeleteAlert) {
                    Alert(
                        title: Text(isRtl ? "למחוק קבוצה?" : "Delete group?"),
                        message: Text(isRtl
                                      ? "האם אתה בטוח שברצונך למחוק את קבוצת התוספות הזו?"
                                      : "Are you sure you want to delete this modifier group?"),
                        primaryButton: .destructive(Text(isRtl ? "מחק" : "Delete")) {
                            onDelete()
                        },
                        secondaryButton: .cancel(Text(isRtl ? "ביטול" : "Cancel"))
                    )
                }
            }

            VStack(spacing: 6) {
                ForEach(Array(group.items.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField(
                            group.kind == .options
                            ? (isRtl ? "אפשרות" : "Option")
                            : (isRtl ? "תוספת" : "Extra"),
                            text: $group.items[index].name
                        )
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: group.items[index].name) { newValue in
                            autoAppendRowIfNeeded(currentIndex: index, newValue: newValue)
                        }

                        PriceTextField(text: $group.items[index].extraPriceText)
                            .frame(width: 60)

                        Button {
                            removeItem(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    appendEmptyItem()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(
                            group.kind == .options
                            ? (isRtl ? "הוסף אפשרות" : "Add option")
                            : (isRtl ? "הוסף תוספת" : "Add extra")
                        )
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isTitleFocused = true
                }
            }
            if group.items.isEmpty {
                appendEmptyItem()
            }
        }
    }

    private func appendEmptyItem() {
        group.items.append(
            AdminModifierItemDraft(
                name: "",
                extraPriceText: "0.0"
            )
        )
    }

    private func removeItem(at index: Int) {
        guard group.items.indices.contains(index) else { return }
        group.items.remove(at: index)
        if group.items.isEmpty { appendEmptyItem() }
    }

    private func autoAppendRowIfNeeded(currentIndex: Int, newValue: String) {
        guard currentIndex == group.items.count - 1 else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 1 { appendEmptyItem() }
    }
}

// MARK: - PriceTextField (unchanged)

struct PriceTextField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.keyboardType = .decimalPad
        tf.textAlignment = .right
        tf.borderStyle = .roundedRect
        tf.delegate = context.coordinator
        tf.text = text
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.textChanged(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }
    }
}

// MARK: - Image helpers (unchanged)

extension UIImage {
    func scaled(toMaxDimension maxDimension: CGFloat) -> UIImage? {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return self }
        let scale = maxDimension / maxSide
        if scale >= 1 { return self }
        let newSize = CGSize(width: size.width * scale,
                             height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

func saveImageToServer(
    image: UIImage,
    imageName: String,
    completion: @escaping (Result<String, Error>) -> Void
) {
    let resized = image.scaled(toMaxDimension: 400) ?? image

    guard let imageData = resized.jpegData(compressionQuality: 0.7) else {
        completion(.failure(NSError(domain: "", code: -1)))
        return
    }
    let imageString = imageData.base64EncodedString()
    guard let uploadURL = URL(string: "https://minitel.co.uk/utilities/saveimage.aspx") else {
        completion(.failure(NSError(domain: "", code: -1)))
        return
    }

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let postBody = "\(imageName).pngimage=\(imageString)"
    request.httpBody = postBody.data(using: .utf8)
    request.addValue("\(postBody.count)", forHTTPHeaderField: "Content-Length")

    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error = error {
            completion(.failure(error))
            return
        }
        if let httpResp = response as? HTTPURLResponse,
           httpResp.statusCode == 200 {
            completion(.success(imageName))
        } else {
            completion(.failure(NSError(domain: "", code: -1)))
        }
    }.resume()
}

struct AdminImagePicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            if let img = info[.editedImage] as? UIImage ?? info[ .originalImage ] as? UIImage {
                onImagePicked(img)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}


private func legacyNameForStationId(_ id: String) -> String {
    switch id.lowercased() {
    case "s1": return "Kitchen"
    case "s2": return "Bar"
    case "s3": return "Bakery"
    default:   return "Bar"
    }
}

// MARK: - Payload mapping

// MARK: - Payload mapping

extension AdminProductDraft {

    /// Build the payload for the upsert API.
    /// IMPORTANT: pass `stations` snapshot from MainActor (so we don't touch MainActor state here).
    func toUpsertPayload(shopId: Int, stations: [PrinterStation]) -> MinisProductAPI.UpsertPayload {

        // -----------------------------
        // 1) Build ModifierGroups payload
        // -----------------------------
        let groups: [[String: Any]] = modifierGroups.map { group in
            let items: [[String: Any]] = group.items.map { item in
                let price = Double(item.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                return [
                    "OptionName": item.name,
                    "ExtraPrice": price
                ]
            }

            let selection: [String: Any] = {
                switch group.kind {
                case .options:
                    return ["mode": "single", "min": 1, "max": 1]
                case .additions:
                    return ["mode": "multi", "min": 0, "max": max(items.count, 1)]
                }
            }()

            return [
                "GroupId": group.id.uuidString,
                "Title": group.title,
                "Selection": selection,
                "Items": items
            ]
        }

        let optionsArr: [[String: Any]] = []
        let additionsArr: [[String: Any]] = []
        let removalsArr: [[String: Any]] = []

        // -----------------------------
        // 2) Base JsonData (DICTIONARY) - keeps your existing API shape
        // buildJsonData returns: [String : MinisProductAPI.AnyEncodable]
        // -----------------------------
        let baseJsonDict: [String: MinisProductAPI.AnyEncodable] = buildJsonData(
            description: description,
            printer: printerId,   // temporary value; we overwrite Printer below with legacy string
            optionsArr: optionsArr,
            additionsArr: additionsArr,
            removalsArr: removalsArr,
            groups: groups
        )

        // -----------------------------
        // 3) Inject BOTH systems:
        // - old: "Printer" = "Bar/Kitchen/Bakery"
        // - new: "PrinterId" + "PrinterIds" (station ids like s1/s2)
        // -----------------------------
        var injectedJsonDict = injectPrintersIntoJsonData(
            baseJsonData: baseJsonDict,
            primaryId: printerId,
            printerIds: printerIds,
            stations: stations
        )

        // ✅ NEW: persist phone requirement into JsonData
        injectedJsonDict["isPhone"] = .init(isPhoneRequired ? 1 : 0)

        // -----------------------------
        // 4) Other fields
        // -----------------------------
        let price = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0

        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = cleanCategory.isEmpty ? "General" : cleanCategory

        let rawImage = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanImage = rawImage.isEmpty
            ? "https://beithaam.com/wp-content/uploads/2024/12/share.jpg"
            : rawImage

        return .init(
            Id: productId,
            MiniAppId: shopId,
            Name: name,
            Price: price,
            Category: finalCategory,
            Image: cleanImage,
            Sort: nil,
            Status: true,
            JsonData: injectedJsonDict   // ✅ dictionary (matches your UpsertPayload type)
        )
    }

    /// Injects PrinterIds into JsonData *dictionary* (not String).
    /// Keeps backward compatibility by also setting legacy `Printer` (Bar/Kitchen/Bakery).
    private func injectPrintersIntoJsonData(
        baseJsonData: [String: MinisProductAPI.AnyEncodable],
        primaryId: String,
        printerIds: Set<String>,
        stations: [PrinterStation]
    ) -> [String: MinisProductAPI.AnyEncodable] {

        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleanedPrimary = clean(primaryId)
        let cleanedSet = Set(printerIds.map(clean).filter { !$0.isEmpty })

        let idsArray: [String] = {
            if cleanedSet.isEmpty {
                return cleanedPrimary.isEmpty ? [] : [cleanedPrimary]
            } else {
                var s = cleanedSet
                if !cleanedPrimary.isEmpty { s.insert(cleanedPrimary) }
                return Array(s).sorted()
            }
        }()

        let stationForLegacy = cleanedPrimary.isEmpty ? (idsArray.first ?? "") : cleanedPrimary

        // ✅ FORCE legacy string using the hard rule
        let legacy = legacyNameForStationId(stationForLegacy)

        var dict = baseJsonData

        // ✅ old world (string)
        dict["Printer"] = .init(legacy)

        // ✅ new world (ids)
        dict["PrinterId"]  = .init(stationForLegacy)
        dict["PrinterIds"] = .init(idsArray)

        return dict
    }
}

