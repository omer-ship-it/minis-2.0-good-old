//
//  App_clipApp.swift
//  App clip
//
//  Created by Studio Native on 25/11/2025.
//

import SwiftUI
import UserNotifications
import UIKit

@main
struct App_clipApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State var isRtl = true

    init() {
        // Match full app tint behavior
        UIView.appearance().tintColor = UIColor.label

        // Optional: default shopId for the clip (e.g. Beit Ha'am = 12)
        if UserDefaults.standard.string(forKey: "shopId") == nil {
            UserDefaults.standard.set("12", forKey: "shopId")
        }

        // Debug: see that UNUserNotificationCenter delegate is set in the clip too
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let delegate = UNUserNotificationCenter.current().delegate
            print("🔎 [AppClip] UNUserNotificationCenter.delegate at app init:", String(describing: delegate))
        }
    }

    var body: some Scene {
        WindowGroup {
            // App Clip goes straight into the menu
            menuView()
                .environment(\.isRtl, isRtl)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                
                .accentColor(.primary)
        }
    }
}
