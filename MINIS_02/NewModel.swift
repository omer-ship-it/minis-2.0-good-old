import Foundation
import SwiftUI

// MARK: - Mock JSON

enum MockShopJSON {

    // ✅ MiniApp 12 (service)
    static let shop12 = """
    {
      "mini": {
        "miniAppId": 12,
        "defaultLang": "he",
        "rtlLangs": ["he","ar"],
        "title": "Beit HaAm",
        "subtitle": "מהיר · טרי · טעים"
      },

      "highlights": [
        {
          "id": "today",
          "title": { "he": "ספיישלים", "ar": "مختارات", "en": "Highlights" },
          "productIds": [1201],
          "fromHour": 8,
          "toHour": 23,
          "priority": 100
        },
        {
          "id": "morning",
          "title": { "he": "בוקר", "ar": "الصباح", "en": "Morning" },
          "productIds": [1201],
          "fromHour": 7,
          "toHour": 12,
          "priority": 80
        },
        {
          "id": "afternoon",
          "title": { "he": "אחר הצהריים", "ar": "بعد الظهر", "en": "Afternoon" },
          "productIds": [1201],
          "fromHour": 12,
          "toHour": 17,
          "priority": 60
        }
      ],

      "context": {
        "type": "service",
        "title": { "he":"איך?", "ar":"كيف؟", "en":"How?" },
        "requiredOnFirstLaunch": true,
        "storageKey": "mini12.context.selected",
        "options": [
          {
            "id": "sit",
            "label": { "he":"לשבת", "ar":"للجلوس", "en":"Sit" },
            "icon": "chair"
          },
          {
            "id": "takeaway",
            "label": { "he":"לקחת", "ar":"سفري", "en":"Take away" },
            "icon": "bag"
          }
        ]
      },

      "ui": {
        "langDefault": "en",
        "strings": {
          "menu.welcomeTitle": { "he":"ברוכים הבאים", "ar":"أهلاً وسهلاً", "en":"Welcome" },
          "menu.welcomeSubtitle": { "he":"געו במסך כדי להתחיל", "ar":"اضغط على الشاشة للبدء", "en":"Tap the screen to start" },

          "service.dinein": { "he":"לשבת", "ar":"جلوس", "en":"Dine-in" },
          "service.pickup": { "he":"לקחת", "ar":"سفري", "en":"Pickup" },

          "cta.add": { "he":"הוסף", "ar":"أضف", "en":"Add" },
          "cta.update": { "he":"עדכן", "ar":"تحديث", "en":"Update" },
          "cta.remove": { "he":"הסר", "ar":"إزالة", "en":"Remove" },

          "basket.view": { "he":"צפה בהזמנה", "ar":"عرض السلة", "en":"View basket" },
          "basket.title": { "he":"ההזמנה שלך", "ar":"طلبك", "en":"Your order" },
          "basket.clear": { "he":"נקה", "ar":"مسح", "en":"Clear" },
          "basket.total": { "he":"סה\\"כ", "ar":"المجموع", "en":"Total" },
          "basket.checkout": { "he":"המשך לתשלום", "ar":"إلى الدفع", "en":"Checkout" },
          "basket.backToShop": { "he":"חזרה להזמנה", "ar":"العودة", "en":"Back" },
          "basket.upsellTitle": { "he":"אולי תרצו להוסיף", "ar":"قد يعجبك أيضًا", "en":"You may also like" },

          "myitems.title": { "he":"הפריטים שלי", "ar":"عناصري", "en":"My items" },

          "promo.soups": { "he":"היום מרקים", "ar":"شوربات اليوم", "en":"Today soups" },
          "promo.pastries": { "he":"מאפים חמים", "ar":"معجنات ساخنة", "en":"Fresh pastries" },
          "promo.shabbat": { "he":"ספיישלים לשישי", "ar":"عروض الجمعة", "en":"Friday specials" }
        }
      },

      "categories": [
        { "id":"hot_drinks", "emoji":"☕", "titleI18n": { "he":"שתייה חמה", "ar":"مشروبات ساخنة", "en":"Hot drinks" } }
      ],
      "categoryOrder": ["hot_drinks"],

      "products": [
        {
          "ProductId": 1201,
          "Name": "אספרסו",
          "nameI18n": { "he":"אספרסו", "ar":"إسبريسو", "en":"Espresso" },
          "Price": 7.0,
          "CategoryId": "hot_drinks",
          "Image": "https://picsum.photos/seed/1201/800/800",
          "ModifierGroups": []
        }
      ]
    }
    """

    // ✅ MiniApp 13 (location)
    static let shop13 = """
    {
      "mini": {
        "miniAppId": 13,
        "defaultLang": "he",
        "rtlLangs": ["he","ar"],
        "title": "Vitamin",
        "subtitle": "בריא · מהיר · טבעי"
      },

      "highlights": [
        {
          "id": "today",
          "title": { "he": "ספיישלים", "ar": "مختارات", "en": "Highlights" },
          "productIds": [744, 755, 771, 780, 781],
          "fromHour": 8,
          "toHour": 23,
          "priority": 100
        },
        {
          "id": "morning",
          "title": { "he": "בוקר", "ar": "الصباح", "en": "Morning" },
          "productIds": [744, 771],
          "fromHour": 7,
          "toHour": 12,
          "priority": 80
        },
        {
          "id": "afternoon",
          "title": { "he": "אחר הצהריים", "ar": "بعد الظهر", "en": "Afternoon" },
          "productIds": [755, 780],
          "fromHour": 12,
          "toHour": 17,
          "priority": 60
        }
      ],

      "context": {
        "type": "location",
        "title": { "he":"איפה?", "ar":"أين؟", "en":"Where?" },
        "requiredOnFirstLaunch": true,
        "storageKey": "mini13.context.selected",
        "options": [
          {
            "id": "humanities",
            "label": { "he":"מדעי הרוח", "ar":"العلوم الإنسانية", "en":"Humanities" },
            "icon": "mappin"
          },
          {
            "id": "social",
            "label": { "he":"מדעי החברה", "ar":"العلوم الاجتماعية", "en":"Social Sciences" },
            "icon": "mappin"
          }
        ]
      },

      "ui": {
        "langDefault": "en",
        "strings": {
          "menu.welcomeTitle": { "he":"ברוכים הבאים", "ar":"أهلاً وسهلاً", "en":"Welcome" },
          "menu.welcomeSubtitle": { "he":"געו במסך כדי להתחיל", "ar":"اضغط على الشاشة للبدء", "en":"Tap the screen to start" },

          "service.dinein": { "he":"לשבת", "ar":"جلوس", "en":"Dine-in" },
          "service.pickup": { "he":"לקחת", "ar":"سفري", "en":"Pickup" },

          "cta.add": { "he":"הוסף", "ar":"أضف", "en":"Add" },
          "cta.update": { "he":"עדכן", "ar":"تحديث", "en":"Update" },
          "cta.remove": { "he":"הסר", "ar":"إزالة", "en":"Remove" },

          "basket.view": { "he":"צפה בהזמנה", "ar":"عرض السلة", "en":"View basket" },
          "basket.title": { "he":"ההזמנה שלך", "ar":"طلبك", "en":"Your order" },
          "basket.clear": { "he":"נקה", "ar":"مسح", "en":"Clear" },
          "basket.total": { "he":"סה\\"כ", "ar":"المجموع", "en":"Total" },
          "basket.checkout": { "he":"המשך לתשלום", "ar":"إلى الدفع", "en":"Checkout" },
          "basket.backToShop": { "he":"חזרה להזמנה", "ar":"العودة للمتجر", "en":"Back to shop" },
          "basket.upsellTitle": { "he":"אולי תרצו להוסיף", "ar":"قد يعجبك أيضًا", "en":"You may also like" },

          "myitems.title": { "he":"הפריטים שלי", "ar":"عناصري", "en":"My items" },

          "promo.soups": { "he":"היום מרקים", "ar":"شوربات اليوم", "en":"Today soups" },
          "promo.pastries": { "he":"מאפים חמים", "ar":"معجنات ساخنة", "en":"Fresh pastries" },
          "promo.shabbat": { "he":"ספיישלים לשישי", "ar":"عروض الجمعة", "en":"Friday specials" }
        }
      },

      "categories": [
        { "id":"hot_drinks", "emoji":"☕", "titleI18n": { "he":"שתייה חמה", "ar":"مشروبات ساخنة", "en":"Hot drinks" } },
        { "id":"cold_drinks", "emoji":"🥤", "titleI18n": { "he":"שתייה קרה", "ar":"مشروبات باردة", "en":"Cold drinks" } },
        { "id":"sandwiches", "emoji":"🥪", "titleI18n": { "he":"כריכים", "ar":"سندويشات", "en":"Sandwiches" } },
        { "id":"pastries", "emoji":"🥐", "titleI18n": { "he":"מאפים", "ar":"معجنات", "en":"Pastries" } }
      ],
      "categoryOrder": ["hot_drinks","cold_drinks","sandwiches","pastries"],

      "products": [
        {
          "ProductId": 744,
          "Name": "אספרסו",
          "nameI18n": { "he":"אספרסו", "ar":"إسبريسو", "en":"Espresso" },
          "Price": 7.0,
          "CategoryId": "hot_drinks",
          "Image": "https://picsum.photos/seed/744/800/800",
          "ModifierGroups": [
            {
              "GroupId": "size",
              "TitleI18n": { "he":"גודל", "ar":"الحجم", "en":"Size" },
              "Selection": { "mode":"single", "min":1, "max":1 },
              "Items": [
                { "Id":"small", "NameI18n": { "he":"קטן", "ar":"صغير", "en":"Small" }, "ExtraPrice": 0 },
                { "Id":"large", "NameI18n": { "he":"גדול", "ar":"كبير", "en":"Large" }, "ExtraPrice": 3.5 }
              ]
            }
          ]
        },
        {
          "ProductId": 755,
          "Name": "תפוזים סחוט טרי",
          "nameI18n": { "he":"תפוזים סחוט טרי", "ar":"عصير برتقال طازج", "en":"Fresh Orange Juice" },
          "Price": 14.0,
          "CategoryId": "cold_drinks",
          "Image": "https://picsum.photos/seed/755/800/800",
          "ModifierGroups": []
        },
        {
          "ProductId": 771,
          "Name": "מאפה פרמיום מתוק",
          "nameI18n": { "he":"מאפה פרמיום מתוק", "ar":"معجنات فاخرة حلوة", "en":"Premium Sweet Pastry" },
          "Price": 13.0,
          "CategoryId": "pastries",
          "Image": "https://picsum.photos/seed/771/800/800",
          "ModifierGroups": []
        },
        {
          "ProductId": 780,
          "Name": "סלט קטן בהרכבה",
          "nameI18n": { "he":"סלט קטן בהרכבה", "ar":"سلطة صغيرة حسب الطلب", "en":"Small Build-Your-Own Salad" },
          "Price": 27.0,
          "CategoryId": "sandwiches",
          "Image": "https://picsum.photos/seed/780/800/800",
          "ModifierGroups": []
        },
        {
          "ProductId": 781,
          "Name": "סלט גדול בהרכבה",
          "nameI18n": { "he":"סלט גדול בהרכבה", "ar":"سلطة كبيرة حسب الطلب", "en":"Large Build-Your-Own Salad" },
          "Price": 33.0,
          "CategoryId": "sandwiches",
          "Image": "https://picsum.photos/seed/781/800/800",
          "ModifierGroups": []
        }
      ]
    }
    """
}

// MARK: - i18n

struct I18nText: Codable, Equatable {
    let dict: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        dict = (try? c.decode([String:String].self)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(dict)
    }

    func resolve(lang: String, fallback: String?, legacy: String? = nil) -> String {
        let l = lang.lowercased()
        if let v = dict[l]?.trimmedNonEmpty { return v }
        if let fb = fallback?.lowercased(), let v = dict[fb]?.trimmedNonEmpty { return v }
        if let v = dict.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return v }
        return legacy?.trimmedNonEmpty ?? ""
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Models

struct Highlight: Decodable, Identifiable {
    let id: String
    let title: I18nText?      // ✅ matches JSON
    let productIds: [Int]
    let fromHour: Int?
    let toHour: Int?
    let priority: Int
}

struct ShopPayloadV2: Decodable {
    struct Mini: Decodable {
        let miniAppId: Int
        let defaultLang: String?
        let rtlLangs: [String]?
        let title: String?
        let subtitle: String?
    }

    struct Category: Decodable, Identifiable {
        let id: String
        let emoji: String?
        let titleI18n: I18nText?
    }

    struct UIBlock: Decodable {
        let langDefault: String?
        let strings: [String: I18nText]
    }

    struct Context: Decodable {
        let type: String
        let title: I18nText?
        let requiredOnFirstLaunch: Bool
        let storageKey: String?
        let options: [Option]

        struct Option: Decodable, Identifiable {
            let id: String
            let icon: String?
            let label: I18nText
        }
    }

    let mini: Mini
    let highlights: [Highlight]?   // ✅ ADD
    let context: Context?
    let ui: UIBlock?

    let categories: [Category]
    let categoryOrder: [String]?
    let products: [Product]
}

// MARK: - Product

struct Product: Decodable, Identifiable {
    let id: Int
    let name: String
    let nameI18n: I18nText?
    let price: Double
    let categoryId: String
    let image: String?
    let modifierGroups: [ModifierGroupV2]?

    enum CodingKeys: String, CodingKey {
        case id = "ProductId"
        case name = "Name"
        case nameI18n = "nameI18n"
        case price = "Price"
        case categoryId = "CategoryId"
        case image = "Image"
        case modifierGroups = "ModifierGroups"
    }

    func displayName(lang: String, fallback: String?) -> String {
        nameI18n?.resolve(lang: lang, fallback: fallback, legacy: name) ?? name
    }
}

// MARK: - Modifiers (V2)

struct ModifierGroupV2: Decodable, Identifiable {
    let id: String
    let titleI18n: I18nText?
    let selection: SelectionV2?
    let items: [ModifierItemV2]

    struct SelectionV2: Decodable {
        let mode: String?
        let min: Int?
        let max: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id = "GroupId"
        case titleI18n = "TitleI18n"
        case selection = "Selection"
        case items = "Items"
    }
}

struct ModifierItemV2: Decodable, Identifiable {
    let id: String
    let nameI18n: I18nText?
    let extraPrice: Double

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case nameI18n = "NameI18n"
        case extraPrice = "ExtraPrice"
    }

    func displayName(lang: String, fallback: String?) -> String {
        nameI18n?.resolve(lang: lang, fallback: fallback, legacy: id) ?? id
    }
}

// MARK: - Store

@MainActor
final class MockShopStore: ObservableObject {
    @Published private(set) var shop: ShopPayloadV2?

    @AppStorage("app.lang") var lang: String = "he"

    var context: ShopPayloadV2.Context? { shop?.context }

    private var selectedContextDefaultsKey: String {
        shop?.context?.storageKey?.trimmedNonEmpty ?? "mini.context.selected"
    }

    var selectedContextId: String {
        get { UserDefaults.standard.string(forKey: selectedContextDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: selectedContextDefaultsKey) }
    }

    var needsContextSelection: Bool {
        guard let ctx = context else { return false }
        return ctx.requiredOnFirstLaunch && selectedContextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadMock(miniAppId: Int = 13) {
        let raw = (miniAppId == 12) ? MockShopJSON.shop12 : MockShopJSON.shop13
        let data = Data(raw.utf8)

        do {
            self.shop = try JSONDecoder().decode(ShopPayloadV2.self, from: data)
            normalizeLangAfterLoad()
        } catch {
            self.shop = nil
        }
    }

    private func normalizeLangAfterLoad() {
        let current = lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if current.isEmpty {
            lang = (shop?.mini.defaultLang?.trimmedNonEmpty ?? "he").lowercased()
            return
        }

        let allowed: Set<String> = ["he", "ar", "en", "it"]
        if !allowed.contains(current) {
            lang = (shop?.mini.defaultLang?.trimmedNonEmpty ?? "he").lowercased()
        }
    }

    var defaultLang: String { shop?.mini.defaultLang ?? "en" }

    var isRtl: Bool {
        let rtl = shop?.mini.rtlLangs?.map { $0.lowercased() } ?? ["he","ar"]
        return rtl.contains(lang.lowercased())
    }

    // ✅ Expose highlights
    var highlights: [Highlight] {
        shop?.highlights ?? []
    }

    func categoryTitle(for id: String) -> String {
        guard let c = shop?.categories.first(where: { $0.id == id }) else { return id }
        let title = c.titleI18n?.resolve(lang: lang, fallback: defaultLang, legacy: id) ?? id
        if let e = c.emoji?.trimmedNonEmpty { return "\(e) \(title)" }
        return title
    }

    func t(_ key: String) -> String {
        guard let shop else { return key }
        return shop.ui?.strings[key]?.resolve(lang: lang, fallback: shop.ui?.langDefault ?? defaultLang) ?? key
    }

    func setSelectedContext(_ id: String?) {
        selectedContextId = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearSelectedContext() {
        selectedContextId = ""
    }

    var contextTitleText: String {
        context?.title?.resolve(lang: lang, fallback: defaultLang) ?? ""
    }

    var contextOptions: [ShopPayloadV2.Context.Option] {
        context?.options ?? []
    }
}
