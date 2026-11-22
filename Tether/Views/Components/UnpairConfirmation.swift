//
//  UnpairConfirmation.swift
//  Tether
//

import SwiftUI

extension View {
    /// Asks before unpairing the device in `item`, the same way everywhere.
    func unpairConfirmation<Item>(
        for item: Binding<Item?>,
        name: @escaping (Item) -> String,
        unpair: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            "Unpair \(item.wrappedValue.map(name) ?? "device")?",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { device in
            Button("Unpair", role: .destructive) { unpair(device) }
        } message: { device in
            Text("You'll need to pair again from \(name(device)) to reconnect.")
        }
    }
}
