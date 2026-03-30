//
//  SpelllineApp.swift
//  Spellline
//
//  Created by Florian Ritzmaier on 29.03.26.
//

import SwiftUI
import CoreData

@main
struct SpelllineApp: App {
    private let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
