//
//  GlassDemoApp.swift
//  GlassDemo
//
//  Created by dongchankim on 10/21/26.
//

import MWDATCore
import SwiftUI

@main
struct GlassDemoApp: App {
    private let configureError: String?

    init() {
        do {
            try Wearables.configure()
            configureError = nil
        } catch {
            configureError = "\(error)"
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(configureError: configureError)
        }
    }
}
