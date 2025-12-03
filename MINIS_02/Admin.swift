import SwiftUI
import Kingfisher

// A mutable draft of a product used for editing/creating
struct AdminProductDraft: Identifiable {
    let id = UUID()          // local ID for SwiftUI

    /// If editing an existing product, store its real ID here.
    var productId: Int?

    var name: String
    var priceText: String    // text field binding, we parse to Double on save
    var category: String
    var description: String
    var imageURL: String
    var modifierGroups: [AdminModifierGroupDraft]
}

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

// Editable modifier item

struct AdminProductEditorMode {
    enum Mode {
        case create
        case edit
    }
}

struct AdminProductEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @State private var draft: AdminProductDraft
    @State private var lastAddedGroupId: AdminModifierGroupDraft.ID?

    private let mode: AdminProductEditorMode.Mode
    private let onSave: (AdminProductDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onChangeImage: (() -> Void)?

    init(
        draft: AdminProductDraft,
        mode: AdminProductEditorMode.Mode,
        onSave: @escaping (AdminProductDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onChangeImage: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)

        // 💡 Ensure new product starts with "0.0"
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
                    // IMAGE
                    Section {
                        headerImageSection
                    }

                    // MAIN FIELDS
                    Section {
                        mainFieldsSection
                    }

                    // MODIFIER GROUPS (DRAG & DROP)
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
                                    onDelete: {
                                        removeModifierGroup(group)
                                    }
                                )
                                .id(group.id)   // for scroll-to-new-group
                            }
                            .onMove(perform: moveModifierGroups)
                        }
                    }
                }
                .listStyle(.insetGrouped)
             //   .environment(\.editMode, .constant(.active))   // always show drag handles
                .onChange(of: lastAddedGroupId) { id in
                    guard let id else { return }
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
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
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    private var modeTitle: String {
        switch mode {
        case .create:
            return isRtl ? "מוצר חדש" : "New Product"
        case .edit:
            return isRtl ? "עריכת מוצר" : "Edit Product"
        }
    }

    // MARK: - Sections

    private var headerImageSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 220)
                    .overlay(
                        Group {
                            if let url = URL(string: draft.imageURL), !draft.imageURL.isEmpty {
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if let onChangeImage {
                Button {
                    onChangeImage()
                } label: {
                    Text(isRtl ? "בחירת תמונה" : "Change Image")
                        .font(.primariesDemi(15))
                }
            } else {
                HStack {
                    Text(isRtl ? "קישור לתמונה" : "Image URL")
                        .font(.primariesDemi(14))
                    TextField(isRtl ? "https://..." : "https://...", text: $draft.imageURL)
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var mainFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "שם המוצר" : "Name")
                    .font(.primariesDemi(14))
                TextField(
                    "",
                    text: $draft.name,
                    prompt: Text(isRtl ? "שם המוצר" : "Name")
                )
                .font(.custom(primariesFontName, size: 18))
                .textFieldStyle(.roundedBorder)
            }

            // Price + Category
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "מחיר" : "Price")
                        .font(.primariesDemi(14))

                    // Use PriceTextField so tapping selects all text
                    PriceTextField(text: $draft.priceText)
                        .frame(height: 36)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "קטגוריה" : "Category")
                        .font(.primariesDemi(14))
                    TextField(isRtl ? "קטגוריה" : "Category", text: $draft.category)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Description
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "תיאור" : "Description")
                    .font(.primariesDemi(14))
                TextField(isRtl ? "תיאור קצר" : "Short description",
                          text: $draft.description,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                let price = Double(draft.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0

                // Clean out empty options/groups before saving
                var cleanDraft = cleanedForSave(draft)
                cleanDraft.priceText = String(format: "%.2f", price)

                onSave(cleanDraft)
                dismiss()
            } label: {
                Text(mode == .create ? (isRtl ? "הוסף מוצר" : "Create") :
                                       (isRtl ? "שמור שינויים" : "Save"))
                    .font(.primariesDemi(17))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Save cleaning (no empty options)

    private func cleanedForSave(_ draft: AdminProductDraft) -> AdminProductDraft {
        var copy = draft

        copy.modifierGroups = copy.modifierGroups.map { group in
            var g = group
            g.items = g.items.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return g
        }

        copy.modifierGroups = copy.modifierGroups.filter { group in
            let hasTitle = !group.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return hasTitle || !group.items.isEmpty
        }

        return copy
    }

    // MARK: - Helper for groups

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
        var new = AdminModifierGroupDraft(
            title: "",
            kind: .options,
            items: []
        )
        draft.modifierGroups.append(new)
        lastAddedGroupId = new.id
    }
}
struct AdminModifierGroupEditor: View {
    @Environment(\.isRtl) private var isRtl
    @State private var showDeleteAlert = false
    @Binding var group: AdminModifierGroupDraft
    let onDelete: () -> Void

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // HEADER: title + type + delete
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
                    showDeleteAlert = true   // just open confirm
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(6)          // small tap target, not the whole box
                }
                .buttonStyle(.borderless)    // don’t let List expand the tap area
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

            // OPTIONS / ADDITIONS LIST
            VStack(spacing: 6) {
                ForEach(Array(group.items.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        // Name
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

                        // Extra price – with auto-select on focus
                        PriceTextField(text: $group.items[index].extraPriceText)
                            .frame(width: 60)

                        // Delete row
                        Button {
                            removeItem(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                    }
                }

                // Manual "Add option" button
               
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            // Focus title for new groups (empty title) with a short delay
            if group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isTitleFocused = true
                }
            }

            // Ensure at least one empty item
            if group.items.isEmpty {
                appendEmptyItem()
            }
        }
    }

    // MARK: - Helpers

    private func appendEmptyItem() {
        group.items.append(
            AdminModifierItemDraft(
                name: "",
                extraPriceText: "0.0"   // 👈 default 0.0 instead of 0
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

    /// When user starts typing into the *last* option row, auto-append a new empty row.
    private func autoAppendRowIfNeeded(currentIndex: Int, newValue: String) {
        guard currentIndex == group.items.count - 1 else { return }

        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        // Only when they type the *first* non-empty character in the last row
        if trimmed.count == 1 {
            appendEmptyItem()
        }
    }
}

struct PriceTextField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.keyboardType = .decimalPad

        // 👇 Leading alignment instead of center
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
            // 👇 Automatically select all text on focus
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }
    }
}

extension AdminProductDraft {
    func toUpsertPayload(shopId: Int) -> MinisProductAPI.UpsertPayload {
        // 1) Build groups array for ModifierGroups
        //    We use group.title as the Title, and map Kind → mode/min/max
        let groups: [[String: Any]] = modifierGroups.map { group in
            let items: [[String: Any]] = group.items.map { item in
                let price = Double(item.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                return [
                    "OptionName": item.name,
                    "ExtraPrice": price
                ]
            }

            // Selection rules: options = single; additions = multi
            let selection: [String: Any] = {
                switch group.kind {
                case .options:
                    return [
                        "mode": "single",
                        "min": 1,
                        "max": 1
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
                // you can keep GroupId stable by using the UUID or a slug
                "GroupId": group.id.uuidString,
                "Title": group.title,       // 👈 THIS is your custom title
                "Selection": selection,
                "Items": items
            ]
        }

        // 2) Legacy flat modifiers – you can keep them or drop them.
        //    Since buildJsonData prefers groups when non-empty,
        //    it’s safe to leave these empty now.
        let optionsArr: [[String: Any]] = []
        let additionsArr: [[String: Any]] = []
        let removalsArr: [[String: Any]] = []

        // 3) Build jsonData with your helper (now groups is NON-empty)
        let jsonData = buildJsonData(
            description: description,
            optionsArr: optionsArr,
            additionsArr: additionsArr,
            removalsArr: removalsArr,
            groups: groups
        )

        // 4) Normalise the rest of the fields
        let price = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = cleanCategory.isEmpty ? "General" : cleanCategory

        let cleanImage = imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://beithaam.com/wp-content/uploads/2024/12/share.jpg"
            : imageURL.trimmingCharacters(in: .whitespacesAndNewlines)

        return .init(
            Id: productId,            // existing DB id or nil for new
            MiniAppId: shopId,
            Name: name,
            Price: price,
            Category: finalCategory,
            Image: cleanImage,
            Sort: nil,
            Status: true,
            JsonData: jsonData
        )
    }
}
