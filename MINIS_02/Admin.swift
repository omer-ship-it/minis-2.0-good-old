import SwiftUI
import Kingfisher

import UniformTypeIdentifiers

extension UTType {
    static let minisModifierGroup = UTType(exportedAs: "com.minis.modifier-group")
    static let minisModifierItem  = UTType(exportedAs: "com.minis.modifier-item")
}

struct AdminProductDraft: Identifiable {
    let id = UUID()
    var productId: Int?

    var name: String
    var priceText: String
    var category: String
    var description: String
    var imageURL: String
    var modifierGroups: [AdminModifierGroupDraft]
    var legacyPrinter: String = "Bar"
    var printerId: String
    var printerIds: Set<String> = []
    var isPhoneRequired: Bool = false
    var isArchived: Bool = false
    // ✅ NEW BUNDLE FIELDS
    var bundleEnabled: Bool = false
    var bundleSetProductIdsText: String = ""   // "834,835"
    var bundleMaxFreeQty: Int = 1
    var bundleStrategy: String = "most_expensive"
}

// MARK: - Modifier drafts

struct AdminModifierGroupDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable, Codable {   // 👈 ADD Codable
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
    var defaultFirst: Bool = false
}

struct AdminModifierItemDraft: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var extraPriceText: String
    var linkedProductId: Int? = nil
    var useLinkedName: Bool = true
    var useLinkedPrice: Bool = false
}

struct AdminProductEditorMode {
    enum Mode {
        case create
        case edit
    }
}

struct ModifierGroupLibraryItem: Identifiable, Hashable {
    let id: String                 // stable dedupe key
    let title: String
    let kind: AdminModifierGroupDraft.Kind
    let items: [AdminModifierItemDraft]
    let sourceProductName: String
}


struct AdminProductEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl
    @State private var showDeleteAlert = false
    @State private var showArchiveAlert = false
    @State private var showRemoveAlert = false
    @State private var draft: AdminProductDraft
    @State private var lastAddedGroupId: AdminModifierGroupDraft.ID?
    @State private var draggingGroupId: UUID? = nil
    @State private var showTemplatesAdmin = false
    @State private var pickedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isUploadingImage = false
    @State private var pendingModifierLink: (groupId: UUID, itemId: UUID)? = nil
    @State private var showModifierProductPicker = false
    @State private var modifierProductSearchText: String = ""
    @StateObject private var templatesStore = ModifierTemplatesStore.shared
    @State private var showTemplatesPicker = false
    
    // ✅ NEW: bundle picker
    @State private var showBundlePicker = false
    @State private var bundleSearchText: String = ""

    // ✅ NEW: all products for bundle search (pass api.items from CashPointView)
    let allProducts: [ShellMenuItem]
    @State private var showModifierLibraryPicker = false
    @State private var modifierLibrarySearchText: String = ""
    private let mode: AdminProductEditorMode.Mode
    private let onSave: (AdminProductDraft) -> Void
    private let onArchive: (() -> Void)?
    private let onRemoveFromMini: (() -> Void)?
    private let onRestore: (() -> Void)?
    private let onChangeImage: (() -> Void)?

    private let categories: [String]

    
    private func normalizeModifierTitle(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizeModifierItemName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func modifierLibraryKey(
        title: String,
        kind: AdminModifierGroupDraft.Kind,
        items: [AdminModifierItemDraft]
    ) -> String {
        let itemKey = items
            .map {
                let price = Double($0.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                return "\(normalizeModifierItemName($0.name)):\(String(format: "%.2f", price))"
            }
            .joined(separator: "|")

        return "\(normalizeModifierTitle(title))__\(kind.rawValue)__\(itemKey)"
    }

    private var modifierLibraryGroups: [ModifierGroupLibraryItem] {
        var seen = Set<String>()
        var out: [ModifierGroupLibraryItem] = []

        for product in allProducts {
            guard let groups = product.modifiers, !groups.isEmpty else { continue }

            for g in groups {
                let kind: AdminModifierGroupDraft.Kind = (g.type == .options) ? .options : .additions

                let items: [AdminModifierItemDraft] = g.items.map { opt in
                    AdminModifierItemDraft(
                        name: opt.name,
                        extraPriceText: String(format: "%.2f", opt.extraPrice)
                    )
                }

                let cleanTitle = g.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleanTitle.count >= 2 else { continue }
                guard !items.isEmpty else { continue }

                let key = modifierLibraryKey(title: cleanTitle, kind: kind, items: items)
                guard seen.insert(key).inserted else { continue }

                out.append(
                    ModifierGroupLibraryItem(
                        id: key,
                        title: cleanTitle,
                        kind: kind,
                        items: items,
                        sourceProductName: product.name
                    )
                )
            }
        }

        return out.sorted {
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.sourceProductName < $1.sourceProductName
        }
    }
    
    private func addLibraryModifierGroup(_ item: ModifierGroupLibraryItem) {
        let copied = AdminModifierGroupDraft(
            id: UUID(),
            title: item.title,
            kind: item.kind,
            items: item.items.map {
                AdminModifierItemDraft(
                    id: UUID(),
                    name: $0.name,
                    extraPriceText: $0.extraPriceText
                )
            }
        )

        draft.modifierGroups.append(copied)
        lastAddedGroupId = copied.id
        Haptics.light()
    }
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

    private var mainFieldsSectionWithoutBundle: some View {
        VStack(alignment: .leading, spacing: 12) {

            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "שם המוצר" : "Name")
                    .font(.primariesDemi(14))
                TextField("",
                          text: $draft.name,
                          prompt: Text(isRtl ? "שם המוצר" : "Name"))
                    .font(.custom(primariesFontName, size: 18))
                    .textFieldStyle(.roundedBorder)
            }

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
                        categories: categories,
                        selected: $draft.category
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "תיאור" : "Description")
                    .font(.primariesDemi(14))
                TextField(isRtl ? "תיאור קצר" : "Short description",
                          text: $draft.description,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "פרטים נוספים" : "Extra")
                    .font(.primariesDemi(14))

                Toggle(isRtl ? "טלפון נדרש" : "Phone required", isOn: $draft.isPhoneRequired)
                    .font(.system(size: 16, weight: .semibold))
                    .toggleStyle(.switch)
                    .tint(.blue)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(isRtl ? "מדפסות" : "Printers")
                    .font(.primariesDemi(14))

                if activeStations.isEmpty {
                    Text(isRtl ? "לא הוגדרו מדפסות עדיין" : "No printers configured yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
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
                            case .none:
                                draft.printerId = ""
                                draft.printerIds = []
                                draft.legacyPrinter = ""

                            case .bar:
                                draft.printerId = "s2"
                                draft.printerIds = ["s2"]
                                draft.legacyPrinter = "Bar"

                            case .kitchen:
                                draft.printerId = "s1"
                                draft.printerIds = ["s1"]
                                draft.legacyPrinter = "Kitchen"

                            case .bakery:
                                draft.printerId = "s3"
                                draft.printerIds = ["s3"]
                                draft.legacyPrinter = "Bakery"
                            }

                            Haptics.light()
                        }
                    }
                    .padding(.bottom, 6)

                    if draft.printerId.isEmpty {
                        Text(isRtl ? "נבחרו: ללא מדפסת" : "Selected: No printer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    } else {
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
    }
    
    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRtl ? "עסקית" : "Bundle")
                .font(.primariesDemi(14))

           
            // ✅ ALWAYS SHOW THE BUTTON
            Button {
                draft.bundleEnabled = true
                bundleSearchText = ""
                showBundlePicker = true
                Haptics.light()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text(isRtl ? "הוסף מוצר לעסקית" : "Add product to bundle")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if draft.bundleEnabled {
                let ids = bundleSelectedIds

                if ids.isEmpty {
                    Text(isRtl ? "לא נבחרו מוצרים עדיין" : "No products selected yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(ids, id: \.self) { pid in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bundleDisplayName(for: pid))
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("#\(pid)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button {
                                    removeBundleProduct(id: pid)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                HStack(spacing: 12) {
                    Stepper(value: $draft.bundleMaxFreeQty, in: 1...9) {
                        Text(isRtl ? "כמות חינם: \(draft.bundleMaxFreeQty)" : "Free qty: \(draft.bundleMaxFreeQty)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "אסטרטגיה" : "Strategy")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    Picker("", selection: $draft.bundleStrategy) {
                        Text(isRtl ? "הכי יקר" : "Most expensive").tag("most_expensive")
                        Text(isRtl ? "הכי זול" : "Cheapest").tag("cheapest")
                        Text(isRtl ? "ראשון" : "First added").tag("first_added")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .padding(.vertical, 4)
    }
    // ✅ KEEP OLD QUICK PICKER (segment) while testing
    private enum LegacyStation: String, CaseIterable, Identifiable {
        case none = ""
        case bar = "Bar"
        case kitchen = "Kitchen"
        case bakery = "Bakery"

        var id: String { rawValue + "_\(self.hashValue)" }

        func title(isRtl: Bool) -> String {
            switch self {
            case .none:    return isRtl ? "ללא מדפסת" : "No printer"
            case .bar:     return isRtl ? "בר" : "Bar"
            case .kitchen: return isRtl ? "מטבח" : "Kitchen"
            case .bakery:  return isRtl ? "מאפייה" : "Bakery"
            }
        }
    }

    private func openModifierProductLink(groupId: UUID, itemId: UUID) {
        pendingModifierLink = (groupId: groupId, itemId: itemId)
        modifierProductSearchText = ""
        showModifierProductPicker = true
    }
    
    private struct ModifierGroupDropDelegate: DropDelegate {
        let targetId: UUID
        @Binding var groups: [AdminModifierGroupDraft]
        @Binding var draggingGroupId: UUID?

        func dropEntered(info: DropInfo) {
            guard info.hasItemsConforming(to: [UTType.minisModifierGroup]) else { return }
            guard let dragging = draggingGroupId, dragging != targetId else { return }

            guard let from = groups.firstIndex(where: { $0.id == dragging }),
                  let to   = groups.firstIndex(where: { $0.id == targetId })
            else { return }

            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                let moved = groups.remove(at: from)
                groups.insert(moved, at: to)
            }
        }

        func performDrop(info: DropInfo) -> Bool {
            draggingGroupId = nil
            return true
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }
    }
    
    @State private var legacyStation: LegacyStation = .bar

    init(
        draft: AdminProductDraft,
        mode: AdminProductEditorMode.Mode,
        categories: [String],
        allProducts: [ShellMenuItem] = [],
        onSave: @escaping (AdminProductDraft) -> Void,
        onArchive: (() -> Void)? = nil,
        onRemoveFromMini: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil,
        onChangeImage: (() -> Void)? = nil
    ) {
        var normalizedDraft = draft

        // ✅ Normalize incoming modifier toggle state from existing saved data
        normalizedDraft.modifierGroups = normalizedDraft.modifierGroups.map { group in
            var g = group

            // options only; additions never use this toggle
            if g.kind == .options {
                // If the draft was built from DB correctly this will already be right,
                // but this makes sure the editor state is always consistent.
                //
                // TEMP RULE:
                // required = 0  => toggle ON  => defaultFirst = true
                // required = 1  => toggle OFF => defaultFirst = false
                //
                // Since AdminModifierGroupDraft currently only stores Bool,
                // we keep whatever came in unless you explicitly want a fallback.
                // If missing, default to ON.
                if g.defaultFirst != true && g.defaultFirst != false {
                    g.defaultFirst = true
                }
            } else {
                g.defaultFirst = false
            }

            return g
        }

        _draft = State(initialValue: normalizedDraft)
        self.categories = categories
        self.allProducts = allProducts

        if normalizedDraft.priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self._draft.wrappedValue.priceText = "0.0"
        }

        self.mode = mode
        self.onSave = onSave
        self.onArchive = onArchive
        self.onRemoveFromMini = onRemoveFromMini
        self.onRestore = onRestore
        self.onChangeImage = onChangeImage
    }
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section { headerImageSection }
                        Section { mainFieldsSectionWithoutBundle }
                        Section { bundleSection }


                    Section(
                        header:
                            Text(isRtl ? "תוספות / אפשרויות" : "Options & Extras")
                                .font(.primariesDemi(18))
                    ) {

                        if draft.modifierGroups.isEmpty {
                            Text(isRtl ? "אין תוספות" : "No modifiers yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(draft.modifierGroups) { group in
                                HStack(spacing: 10) {

                                    // ✅ GROUP DRAG HANDLE (one per group)
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                        .onDrag {
                                            draggingGroupId = group.id
                                            return NSItemProvider(item: group.id.uuidString as NSString,
                                                                  typeIdentifier: UTType.minisModifierGroup.identifier)
                                        }

                                    // Your editor (no drag here)
                                    AdminModifierGroupEditor(
                                        group: binding(for: group),
                                        allProducts: allProducts,
                                        onDelete: { removeModifierGroup(group) },
                                        onLinkProduct: { itemId in
                                            openModifierProductLink(groupId: group.id, itemId: itemId)
                                        },
                                        onPickTemplate: { template in
                                            let newGroup = template.toAdminModifierGroupDraft()
                                            draft.modifierGroups.append(newGroup)
                                            lastAddedGroupId = newGroup.id
                                        }
                                    )
                                    .id(group.id)
                                }
                                .onDrop(
                                    of: [UTType.minisModifierGroup],
                                    delegate: ModifierGroupDropDelegate(
                                        targetId: group.id,
                                        groups: $draft.modifierGroups,
                                        draggingGroupId: $draggingGroupId
                                    )
                                )
                            }
                            .onMove(perform: moveModifierGroups)
                        }

                        // ✅ NEW BOTTOM BUTTON
                        // ✅ PRIMARY ADD GROUP BUTTON
                        Button {
                            addNewModifierGroup()
                            Haptics.medium()
                        } label: {
                            Text(isRtl ? "הוסף קבוצת אפשרויות" : "Add option group")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        
                        Button {
                            showTemplatesPicker = true
                            Haptics.light()
                        } label: {
                            Text(isRtl ? "הוסף מתבניות מוכנות" : "Add from templates")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
                .onChange(of: lastAddedGroupId) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .alert(
                isRtl ? "להעביר לארכיון?" : "Archive product?",
                isPresented: $showArchiveAlert
            ) {
                Button(isRtl ? "ביטול" : "Cancel", role: .cancel) { }

                Button(isRtl ? "העבר לארכיון" : "Archive", role: .destructive) {
                    onArchive?()
                    dismiss()
                }
            } message: {
                Text(isRtl ? "המוצר יועבר לארכיון." : "The product will be moved to archive.")
            }
            .alert(
                isRtl ? "להסיר מהמיני?" : "Remove from mini?",
                isPresented: $showRemoveAlert
            ) {
                Button(isRtl ? "ביטול" : "Cancel", role: .cancel) { }

                Button(isRtl ? "הסר" : "Remove", role: .destructive) {
                    onRemoveFromMini?()
                    dismiss()
                }
            } message: {
                Text(
                    isRtl
                    ? "המוצר יוסר מהמיני אבל יישאר במסד הנתונים, וניתן יהיה להחזיר אותו בהמשך."
                    : "The product will be removed from this mini but kept in the database so it can be restored later."
                )
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
                if mode == .edit {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if draft.isArchived {
                            if let onRestore {
                                Button {
                                    onRestore()
                                    dismiss()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                }
                            }

                            if onRemoveFromMini != nil {
                                Button(role: .destructive) {
                                    showRemoveAlert = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        } else {
                            if onArchive != nil {
                                Button(role: .destructive) {
                                    showArchiveAlert = true
                                } label: {
                                    Image(systemName: "archivebox")
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showTemplatesPicker) {
                ModifierTemplatesAdminView(
                    allProducts: allProducts,
                    onPick: { template in
                        let newGroup = template.toAdminModifierGroupDraft()
                        draft.modifierGroups.append(newGroup)
                        lastAddedGroupId = newGroup.id
                        showTemplatesPicker = false
                        Haptics.light()
                    }
                )
                .navigationBarHidden(true)
            }
        
            .sheet(isPresented: $showModifierProductPicker) {
                ModifierProductPickerSheet(
                    isRtl: isRtl,
                    currency: UserDefaults.standard.string(forKey: "currency") ?? "₪",
                    products: allProducts,
                    searchText: $modifierProductSearchText,
                    onPick: { product in
                        guard let pending = pendingModifierLink else { return }

                        if let groupIndex = draft.modifierGroups.firstIndex(where: { $0.id == pending.groupId }),
                           let itemIndex = draft.modifierGroups[groupIndex].items.firstIndex(where: { $0.id == pending.itemId }) {

                            draft.modifierGroups[groupIndex].items[itemIndex].linkedProductId = product.id
                            draft.modifierGroups[groupIndex].items[itemIndex].name = product.name
                        }

                        pendingModifierLink = nil
                        showModifierProductPicker = false
                    },
                    onUnlink: {
                        guard let pending = pendingModifierLink else { return }

                        if let groupIndex = draft.modifierGroups.firstIndex(where: { $0.id == pending.groupId }),
                           let itemIndex = draft.modifierGroups[groupIndex].items.firstIndex(where: { $0.id == pending.itemId }) {
                            draft.modifierGroups[groupIndex].items[itemIndex].linkedProductId = nil
                        }

                        pendingModifierLink = nil
                        showModifierProductPicker = false
                    },
                    onClose: {
                        pendingModifierLink = nil
                        showModifierProductPicker = false
                    }
                )
            }
            .sheet(isPresented: $showImagePicker) {
                AdminImagePicker { image in
                    handlePickedImage(image)
                }
            }
            .sheet(isPresented: $showBundlePicker) {
                BundlePickerSheet(
                    isRtl: isRtl,
                    currency: UserDefaults.standard.string(forKey: "currency") ?? "₪",
                    products: allProducts,
                    selectedIds: Set(bundleSelectedIds),
                    searchText: $bundleSearchText,
                    onPick: { item in
                        addBundleProduct(id: item.id)
                        showBundlePicker = false
                    },
                    onClose: { showBundlePicker = false }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
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

    private struct ModifierGroupLibraryPickerSheet: View {
        let isRtl: Bool
        let groups: [ModifierGroupLibraryItem]
        @Binding var searchText: String
        let onPick: (ModifierGroupLibraryItem) -> Void
        let onClose: () -> Void

        private var filtered: [ModifierGroupLibraryItem] {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return groups }

            return groups.filter { g in
                g.title.lowercased().contains(q)
                || g.sourceProductName.lowercased().contains(q)
                || g.items.contains(where: { $0.name.lowercased().contains(q) })
            }
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 10) {

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField(
                            isRtl ? "חפש קבוצת תוספות…" : "Search modifier group…",
                            text: $searchText
                        )
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled()

                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    List {
                        ForEach(filtered) { group in
                            Button {
                                onPick(group)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(group.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)

                                        Spacer()

                                        Text(group.kind == .options
                                             ? (isRtl ? "אפשרויות" : "Options")
                                             : (isRtl ? "תוספות" : "Extras"))
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.secondary)
                                    }

                                    Text(group.items.map(\.name).joined(separator: " • "))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)

                                    Text((isRtl ? "מוצר מקור: " : "Source: ") + group.sourceProductName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if filtered.isEmpty {
                            Text(isRtl ? "לא נמצאו קבוצות" : "No groups found")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle(isRtl ? "ספריית קבוצות" : "Groups library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) {
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
    
    private struct ModifierProductPickerSheet: View {
        let isRtl: Bool
        let currency: String
        let products: [ShellMenuItem]
        @Binding var searchText: String
        let onPick: (ShellMenuItem) -> Void
        let onUnlink: () -> Void
        let onClose: () -> Void

        private var filtered: [ShellMenuItem] {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty {
                return products.sorted { $0.name < $1.name }
            }

            return products.filter { product in
                product.name.lowercased().contains(q) ||
                String(product.id).contains(q) ||
                product.category.lowercased().contains(q)
            }
            .sorted { $0.name < $1.name }
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField(
                            isRtl ? "Search product…" : "Search product…",
                            text: $searchText
                        )
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled()

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    List {
                        Section {
                            Button(role: .destructive) {
                                onUnlink()
                            } label: {
                                HStack {
                                    Image(systemName: "link.badge.minus")
                                    Text(isRtl ? "Remove link" : "Remove link")
                                }
                            }
                        }

                        ForEach(filtered) { product in
                            Button {
                                onPick(product)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(product.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)

                                        Text("#\(product.id) • \(product.category) • \(String(format: "\(currency)%.2f", product.price))")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationTitle(isRtl ? "Link to product" : "Link to product")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) {
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
    
  
    
    private var hasValidBundleItems: Bool {
        !parseIds(draft.bundleSetProductIdsText).isEmpty
    }
    
    private var modeTitle: String {
        switch mode {

        case .create:
            let trimmed = draft.name
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                return isRtl ? "מוצר חדש" : "New Product"
            } else {
                return trimmed
            }

        case .edit:
            let trimmed = draft.name
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                return isRtl ? "עריכת מוצר" : "Edit Product"
            } else {
                return trimmed
            }
        }
    }
    // MARK: - Bundle helpers (store as text, edit as list)

    private func parseIds(_ s: String) -> [Int] {
        s.split { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" || $0 == "\t" }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func setIdsText(_ ids: [Int]) {
        let uniqueSorted = Array(Set(ids)).sorted()
        draft.bundleSetProductIdsText = uniqueSorted.map(String.init).joined(separator: ",")
    }

    private var bundleSelectedIds: [Int] {
        get { parseIds(draft.bundleSetProductIdsText) }
        set { setIdsText(newValue) }
    }
    private func parseBundleIds(_ s: String) -> [Int] {
        s.split { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" || $0 == "\t" }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func writeBundleIds(_ ids: [Int]) {
        let uniqueSorted = Array(Set(ids)).sorted()
        draft.bundleSetProductIdsText = uniqueSorted.map(String.init).joined(separator: ",")
    }
    private func addBundleProduct(id: Int) {
        var ids = parseBundleIds(draft.bundleSetProductIdsText)
        guard !ids.contains(id) else { return }
        ids.append(id)
        writeBundleIds(ids)
        Haptics.light()
    }

    private func removeBundleProduct(id: Int) {
        var ids = parseBundleIds(draft.bundleSetProductIdsText)
        ids.removeAll { $0 == id }
        writeBundleIds(ids)
        Haptics.light()
    }

    private func bundleDisplayName(for productId: Int) -> String {
        if let p = allProducts.first(where: { $0.id == productId }) {
            return p.name
        }
        return "#\(productId)"
    }

    // MARK: - Printers helpers (ID routing)

    private var activeStations: [PrinterStation] {
        printerStore.config.stations.filter { $0.status != 0 }
    }

    private func normalizePrinterId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // ✅ allow empty = No printer
        if trimmed.isEmpty { return "" }

        if activeStations.contains(where: { $0.id == trimmed }) { return trimmed }

        let t = trimmed.lowercased()
        if t.contains("bar") || t.contains("בר") { return "s2" }
        if t.contains("bakery") || t.contains("מאפ") || t.contains("ויטרינה") { return "s3" }
        if t.contains("kitchen") || t.contains("מטבח") { return "s1" }

        // ✅ unknown value -> empty, not fallback
        return ""
    }

    private func ensureValidPrinterId() {
        let normalized = normalizePrinterId(draft.printerId)
        if draft.printerId != normalized {
            draft.printerId = normalized
        }
    }

    private func ensurePrinterSelectionNotEmpty() {
        // ✅ No printer is valid
        if draft.printerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.printerId = ""
            draft.printerIds = []
            return
        }

        if !draft.printerId.isEmpty, !draft.printerIds.contains(draft.printerId) {
            draft.printerIds.insert(draft.printerId)
        }

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

        case .none:
            return nil

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
                $0.label.lowercased().contains("bakery")
                || $0.label.contains("מאפ")
                || $0.label.contains("ויטרינה")
            })?.id
        }
    }

    private func syncLegacySegmentFromCurrentSelection() {
        let pid = draft.printerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if pid.isEmpty {
            legacyStation = .none
            return
        }

        if pid == "s1" { legacyStation = .kitchen; return }
        if pid == "s2" { legacyStation = .bar; return }
        if pid == "s3" { legacyStation = .bakery; return }

        guard let st = activeStations.first(where: { $0.id == draft.printerId }) else {
            legacyStation = .none
            return
        }

        let l = st.label.lowercased()
        if l.contains("kitchen") || st.label.contains("מטבח") {
            legacyStation = .kitchen
        } else if l.contains("bakery") || st.label.contains("מאפ") || st.label.contains("ויטרינה") {
            legacyStation = .bakery
        } else if l.contains("bar") || st.label.contains("בר") {
            legacyStation = .bar
        } else {
            legacyStation = .none
        }
    }

    private func toggleStation(_ id: String) {
        if draft.printerIds.contains(id) {
            if draft.printerIds.count <= 1 {
                Haptics.error()
                return
            }
            draft.printerIds.remove(id)
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

            // PRICE + CATEGORY
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
                        categories: categories,
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

            // PHONE REQUIRED
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "פרטים נוספים" : "Extra")
                    .font(.primariesDemi(14))

                Toggle(isRtl ? "טלפון נדרש" : "Phone required", isOn: $draft.isPhoneRequired)
                    .font(.system(size: 16, weight: .semibold))
                    .toggleStyle(.switch)
            }
            .padding(.top, 4)

            // ✅ BUNDLE UI (friendly)
            VStack(alignment: .leading, spacing: 10) {
                Text(isRtl ? "עסקית" : "Bundle")
                    .font(.primariesDemi(14))

                Toggle(isRtl ? "הפעל עסקית" : "Enable bundle", isOn: $draft.bundleEnabled)
                    .font(.system(size: 16, weight: .semibold))
                    .toggleStyle(.switch)

                if draft.bundleEnabled {
                    let ids = bundleSelectedIds

                    if ids.isEmpty {
                        Text(isRtl ? "לא נבחרו מוצרים עדיין" : "No products selected yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(ids, id: \.self) { pid in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bundleDisplayName(for: pid))
                                            .font(.system(size: 15, weight: .semibold))
                                        Text("#\(pid)")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button {
                                        removeBundleProduct(id: pid)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    Button {
                        bundleSearchText = ""
                        showBundlePicker = true
                        Haptics.light()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text(isRtl ? "הוסף מוצר לעסקית" : "Add product to bundle")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        Stepper(value: $draft.bundleMaxFreeQty, in: 1...9) {
                            Text(isRtl ? "כמות חינם: \(draft.bundleMaxFreeQty)" : "Free qty: \(draft.bundleMaxFreeQty)")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(isRtl ? "אסטרטגיה" : "Strategy")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $draft.bundleStrategy) {
                            Text(isRtl ? "הכי יקר" : "Most expensive").tag("most_expensive")
                            Text(isRtl ? "הכי זול" : "Cheapest").tag("cheapest")
                            Text(isRtl ? "ראשון" : "First added").tag("first_added")
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.top, 4)

            // PRINTERS
            VStack(alignment: .leading, spacing: 8) {
                Text(isRtl ? "מדפסות" : "Printers")
                    .font(.primariesDemi(14))

                if activeStations.isEmpty {
                    Text(isRtl ? "לא הוגדרו מדפסות עדיין" : "No printers configured yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isRtl ? "בחירה מהירה" : "Quick route")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $legacyStation) {
                            ForEach(
                                isRtl
                                ? ([.none] + LegacyStation.allCases.filter { $0 != .none })
                                : (LegacyStation.allCases.filter { $0 != .none } + [.none]),
                                id: \.self
                            ) { s in
                                Text(s.title(isRtl: isRtl)).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(.primary)
                        .onChange(of: legacyStation) { newValue in
                            switch newValue {
                            case .none:
                                draft.printerId = ""
                                draft.printerIds = []
                                draft.legacyPrinter = ""

                            case .bar:
                                draft.printerId = "s2"
                                draft.printerIds = ["s2"]
                                draft.legacyPrinter = "Bar"

                            case .kitchen:
                                draft.printerId = "s1"
                                draft.printerIds = ["s1"]
                                draft.legacyPrinter = "Kitchen"

                            case .bakery:
                                draft.printerId = "s3"
                                draft.printerIds = ["s3"]
                                draft.legacyPrinter = "Bakery"
                            }

                            Haptics.light()
                        }
                    }
                    .padding(.bottom, 6)
                    /*
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
                    */
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

    private struct CategoryPickerField: View {
        let isRtl: Bool
        let categories: [String]
        @Binding var selected: String

        @State private var showAdd = false
        @State private var newCategory = ""

        private var cleanedCategories: [String] {
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

                    // keep current value selectable even if not in list
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

                cleanDraft.printerId = normalizePrinterId(cleanDraft.printerId)

                if cleanDraft.printerId.isEmpty {
                    cleanDraft.printerIds = []
                    cleanDraft.legacyPrinter = ""
                } else {
                    if cleanDraft.printerIds.isEmpty {
                        cleanDraft.printerIds = [cleanDraft.printerId]
                    } else {
                        cleanDraft.printerIds.insert(cleanDraft.printerId)
                    }
                }

                onSave(cleanDraft)
                dismiss()
            } label: {
                Text(mode == .create ? (isRtl ? "הוסף מוצר" : "Create")
                                     : (isRtl ? "שמור שינויים" : "Save"))
                .font(.system(size: 16, weight: .bold))
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

        copy.printerId = normalizePrinterId(copy.printerId)

        if copy.printerId.isEmpty {
            copy.printerIds = []
            copy.legacyPrinter = ""
        } else {
            if copy.printerIds.isEmpty {
                copy.printerIds = [copy.printerId]
            } else {
                copy.printerIds.insert(copy.printerId)
            }
            copy.legacyPrinter = legacyNameForStationId(copy.printerId)
        }
        
        copy.legacyPrinter = legacyNameForStationId(copy.printerId)

        // ✅ Clean modifier groups/items before save
        copy.modifierGroups = copy.modifierGroups.compactMap { group in
            let cleanTitle = group.title.trimmingCharacters(in: .whitespacesAndNewlines)

            let cleanItems = group.items.compactMap { item -> AdminModifierItemDraft? in
                let cleanName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)

                guard cleanName.count >= 2 else { return nil }

                var cleanedItem = item
                cleanedItem.name = cleanName

                let raw = item.extraPriceText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ".")

                let price = Double(raw) ?? 0
                cleanedItem.extraPriceText = String(format: "%.2f", price)

                return cleanedItem
            }

            // ✅ remove groups with empty title or no valid items
            guard cleanTitle.count >= 2 else { return nil }
            guard !cleanItems.isEmpty else { return nil }

            var cleanedGroup = group
            cleanedGroup.title = cleanTitle
            cleanedGroup.items = cleanItems
            return cleanedGroup
        }

        // ✅ keep bundle ids clean
        let ids = parseIds(copy.bundleSetProductIdsText)
        copy.bundleSetProductIdsText = Array(Set(ids)).sorted().map(String.init).joined(separator: ",")

        // ✅ if empty, keep toggle visually allowed but do not treat as real active bundle
          return copy
    }

    private func binding(for group: AdminModifierGroupDraft) -> Binding<AdminModifierGroupDraft> {
        Binding(
            get: { draft.modifierGroups.first(where: { $0.id == group.id }) ?? group },
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
        let new = AdminModifierGroupDraft(title: "", kind: .options, items: [])
        draft.modifierGroups.append(new)
        lastAddedGroupId = new.id
    }

    // MARK: - Bundle picker sheet

    private struct BundlePickerSheet: View {
        let isRtl: Bool
        let currency: String
        let products: [ShellMenuItem]
        let selectedIds: Set<Int>
        @Binding var searchText: String
        let onPick: (ShellMenuItem) -> Void
        let onClose: () -> Void

        private var filtered: [ShellMenuItem] {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return products.sorted { $0.id < $1.id } }

            return products.filter { p in
                p.name.lowercased().contains(q)
                || p.displayName.lowercased().contains(q)
                || String(p.id).contains(q)
            }
            .sorted { $0.id < $1.id }
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 10) {

                    // Search
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField(isRtl ? "חפש מוצר…" : "Search product…", text: $searchText)
                            .textInputAutocapitalization(.none)
                            .autocorrectionDisabled()

                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    List {
                        ForEach(filtered) { item in
                            let already = selectedIds.contains(item.id)

                            Button {
                                guard !already else { return }
                                onPick(item)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text("#\(item.id)  •  \(String(format: "\(currency)%.2f", item.price))")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: already ? "checkmark.circle.fill" : "plus.circle.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(already ? .secondary : .primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(already)
                        }

                        if products.isEmpty {
                            Text(isRtl ? "לא נטענו מוצרים (pass api.items)" : "No products loaded (pass api.items)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle(isRtl ? "הוסף מוצר לבאנדל" : "Add bundle product")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) {
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

// MARK: - Modifier Group Editor (unchanged)
private struct ModifierItemDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var items: [AdminModifierItemDraft]
    @Binding var draggingItemId: UUID?

    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [UTType.minisModifierItem]) else { return }
        guard let dragging = draggingItemId,
              dragging != targetId,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to   = items.firstIndex(where: { $0.id == targetId })
        else { return }

        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            let moved = items.remove(at: from)
            items.insert(moved, at: to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct AdminModifierGroupEditor: View {
    @Environment(\.isRtl) private var isRtl
    @State private var showDeleteAlert = false
    @Binding var group: AdminModifierGroupDraft

    let allProducts: [ShellMenuItem]
    let onDelete: () -> Void
    let onLinkProduct: (UUID) -> Void
    let onPickTemplate: (ModifierTemplateDraft) -> Void

    @State private var showTemplatesPicker = false
    @State private var draggingItemId: UUID? = nil
    @FocusState private var isTitleFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            HStack {
                Spacer()

                Button {
                    showTemplatesPicker = true
                    Haptics.light()
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(6)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            HStack{
            
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
                    HStack{
                        Picker("", selection: $group.kind) {
                            Text(isRtl ? "אפשרויות" : "Options")
                                .tag(AdminModifierGroupDraft.Kind.options)
                            Text(isRtl ? "תוספות" : "Additions")
                                .tag(AdminModifierGroupDraft.Kind.additions)
                        }
                        .pickerStyle(.segmented)
                        
                        if group.kind == .options {
                            Toggle("התחל עם ברירת מחדל", isOn: $group.defaultFirst)
                                .font(.system(size: 15, weight: .semibold))
                                .toggleStyle(.switch)
                                .tint(.blue)
                        }
                        
                    }
                }
                }

                Spacer()

                Button {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                }
                .buttonStyle(.borderless)
                .alert(isPresented: $showDeleteAlert) {
                    Alert(
                        title: Text(isRtl ? "למחוק קבוצה?" : "Delete group?"),
                        message: Text(
                            isRtl
                            ? "האם אתה בטוח שברצונך למחוק את קבוצת התוספות הזו?"
                            : "Are you sure you want to delete this modifier group?"
                        ),
                        primaryButton: .destructive(Text(isRtl ? "מחק" : "Delete")) {
                            onDelete()
                        },
                        secondaryButton: .cancel(Text(isRtl ? "ביטול" : "Cancel"))
                    )
                }
            }

            VStack(spacing: 6) {
                ForEach(group.items) { item in
                    let index = group.items.firstIndex(where: { $0.id == item.id }) ?? 0

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                group.kind == .options
                                ? (isRtl ? "אפשרות" : "Option")
                                : (isRtl ? "תוספת" : "Extra"),
                                text: Binding(
                                    get: { group.items[index].name },
                                    set: { newValue in
                                        group.items[index].name = newValue
                                        autoAppendRowIfNeeded(currentIndex: index, newValue: newValue)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            if let linkedId = group.items[index].linkedProductId {
                                Text("#\(linkedId)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                            }
                        }

                        PriceTextField(
                            text: Binding(
                                get: { group.items[index].extraPriceText },
                                set: { group.items[index].extraPriceText = $0 }
                            )
                        )
                        .frame(width: 60)

                        Button {
                            removeItem(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)

                        Button {
                            onLinkProduct(item.id)
                        } label: {
                            Image(systemName: group.items[index].linkedProductId == nil ? "link" : "link.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(group.items[index].linkedProductId == nil ? .secondary : .primary)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.minisModifierItem],
                        delegate: ModifierItemDropDelegate(
                            targetId: item.id,
                            items: $group.items,
                            draggingItemId: $draggingItemId
                        )
                    )
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
        .sheet(isPresented: $showTemplatesPicker) {
            ModifierTemplatesAdminView(
                allProducts: allProducts,
                onPick: { template in
                    onPickTemplate(template)
                    showTemplatesPicker = false
                }
            )
            .navigationBarHidden(true)
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
        if group.items.isEmpty {
            appendEmptyItem()
        }
    }

    private func autoAppendRowIfNeeded(currentIndex: Int, newValue: String) {
        guard currentIndex == group.items.count - 1 else { return }

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 {
            let hasTrailingEmpty = group.items.last?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
            if !hasTrailingEmpty {
                appendEmptyItem()
            }
        }
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
        tf.keyboardType = .numbersAndPunctuation
        tf.textAlignment = .right
        tf.borderStyle = .roundedRect
        tf.delegate = context.coordinator
        tf.text = text
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
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

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }

            let newValue = current.replacingCharacters(in: swiftRange, with: string)

            if newValue.isEmpty { return true }
            if newValue == "-" { return true }
            if newValue == "." { return true }
            if newValue == "-." { return true }

            let allowed = CharacterSet(charactersIn: "-0123456789.,")
            if string.rangeOfCharacter(from: allowed.inverted) != nil {
                return false
            }

            let minusCount = newValue.filter { $0 == "-" }.count
            if minusCount > 1 { return false }
            if let minusIndex = newValue.firstIndex(of: "-"), minusIndex != newValue.startIndex {
                return false
            }

            let normalized = newValue.replacingOccurrences(of: ",", with: ".")
            let dotCount = normalized.filter { $0 == "." }.count
            if dotCount > 1 { return false }

            let test = normalized == "-" || normalized == "." || normalized == "-."
                ? "0"
                : normalized

            return Double(test) != nil
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
    default:   return ""
    }
}

// MARK: - Payload mapping

// MARK: - Payload mapping

extension AdminProductDraft {

    private struct BundleJson: Encodable {
        let SetProductIds: [Int]
        let MaxFreeQty: Int
        let Strategy: String
    }
    
    
    /// Build the payload for the upsert API.
    /// IMPORTANT: pass `stations` snapshot from MainActor (so we don't touch MainActor state here).
    func toUpsertPayload(shopId: Int, stations: [PrinterStation]) -> MinisProductAPI.UpsertPayload {

        // -----------------------------
        // 1) Build ModifierGroups payload
        // -----------------------------
        let groups: [[String: Any]] = modifierGroups.map { group in
            let items: [[String: Any]] = group.items.map { item in
                let price = Double(item.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0

                var dict: [String: Any] = [
                    "OptionName": item.name,
                    "ExtraPrice": price
                ]

                if let linkedProductId = item.linkedProductId, linkedProductId > 0 {
                    dict["LinkedProductId"] = linkedProductId
                }

                return dict
            }

            let selection: [String: Any] = {
                switch group.kind {
                case .options:
                    return [
                        "mode": "single",
                        "min": 1,
                        "max": 1,
                        "required": group.defaultFirst ? 0 : 1
                    ]
                case .additions:
                    return [
                        "mode": "multi",
                        "min": 0,
                        "max": max(items.count, 1)
                    ]
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

        if let modifierGroups = baseJsonDict["ModifierGroups"] {
            print("🧨 baseJsonDict ModifierGroups =", modifierGroups)
        }
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
        let ids: [Int] = self.bundleSetProductIdsText
            .split { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" || $0 == "\t" }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }

        let effectiveBundleEnabled = self.bundleEnabled && !ids.isEmpty

        if effectiveBundleEnabled {
            let strategy = self.bundleStrategy
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let safeStrategy: String = {
                if strategy == "most_expensive" || strategy == "cheapest" || strategy == "first_added" {
                    return strategy
                }
                return "cheapest"
            }()

            let payload = BundleJson(
                SetProductIds: Array(Set(ids)).sorted(),
                MaxFreeQty: max(1, self.bundleMaxFreeQty),
                Strategy: safeStrategy
            )

            injectedJsonDict["Bundle"] = .init(payload)
        } else {
            // ✅ if no ids yet, don't send Bundle at all
            injectedJsonDict.removeValue(forKey: "Bundle")
        }

        // -----------------------------
        // 4) Other fields
        // -----------------------------
        let price = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0

        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = cleanCategory.isEmpty ? "General" : cleanCategory

        let rawImage = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanImage = rawImage.isEmpty
            ? "https://d25t2285lxl5rf.cloudfront.net/images/shops/28596.png"
            : rawImage

        let debugLinkedItems = modifierGroups.flatMap { group in
            group.items.compactMap { item -> String? in
                guard let linkedId = item.linkedProductId else { return nil }
                return "\(group.title) -> \(item.name) [LinkedProductId: \(linkedId)]"
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: groups, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            print("🧩 FINAL GROUPS BEFORE buildJsonData:")
            print(text)
        }
        print("🧩 UPSERT PRODUCT DEBUG")
        print("Name:", name)
        print("ProductId:", productId ?? -1)
        print("PrinterId:", printerId)
        print("PrinterIds:", Array(printerIds).sorted())
        print("ModifierGroups count:", modifierGroups.count)

        for g in modifierGroups {
            print("➡️ GROUP RAW:",
                  "title=\(g.title)",
                  "kind=\(g.kind.rawValue)",
                  "defaultFirstBool=\(g.defaultFirst)")
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: groups, options: [.prettyPrinted]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📦 ModifierGroups payload:")
            print(jsonString)
        }
        
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
        let legacy = legacyNameForStationId(stationForLegacy)

        var dict = baseJsonData

        if stationForLegacy.isEmpty {
            // ✅ No printer
            dict["Printer"] = .init("")
            dict["PrinterId"] = .init("")
            dict["PrinterIds"] = .init([String]())
        } else {
            dict["Printer"] = .init(legacy)
            dict["PrinterId"] = .init(stationForLegacy)
            dict["PrinterIds"] = .init(idsArray)
        }

        return dict
    }
}


struct ModifierTemplatesPickerSheet: View {
    let isRtl: Bool
    let templates: [ModifierTemplateDraft]
    let onPick: (ModifierTemplateDraft) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(templates) { template in
                    Button {
                        onPick(template)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(template.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)

                                Spacer()

                                Text(template.kind == .options
                                     ? (isRtl ? "אפשרויות" : "Options")
                                     : (isRtl ? "תוספות" : "Extras"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                            }

                            Text(template.items.map(\.name).joined(separator: " • "))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                if templates.isEmpty {
                    Text(isRtl ? "אין תבניות שמורות" : "No saved templates")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(isRtl ? "בחר תבנית" : "Choose Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
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
