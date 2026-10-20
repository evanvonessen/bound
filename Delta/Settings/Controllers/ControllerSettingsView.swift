//
//  ControllerSettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/30/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI
import DeltaCore

struct ControllerSettingsView: View
{
    private var connectedControllers: [GameController] { ExternalGameControllerManager.shared.connectedControllers }
    
    @SwiftUI.State
    private var controllerNames = [Int: String]() // Player index → assigned controller name
    
    var body: some View {
        Form {
            ForEach(0..<4) { playerIndex in
                NavigationLink {
                    PlayerControllerView(playerIndex: playerIndex)
                        .environment(\.managedObjectContext, DatabaseManager.shared.viewContext)
                } label: {
                    LabeledContent("Player \(playerIndex + 1)", value: controllerNames[playerIndex] ?? "")
                }
            }
        }
        .tint(.accentColor)
        .navigationTitle("Controllers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: updateControllerNames)
        .onChange(of: connectedControllers as NSArray) { updateControllerNames() } // Cast to NSArray which is equatable
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .localControllerPlayerIndex else { return }
            updateControllerNames()
        }
    }
    
    private func updateControllerNames()
    {
        // If no external controller is assigned to any player, touch will control gameplay.
        // So if touch is unassigned, assign it to Player 1. (Mirrors GameViewController.updateControllers().)
        if !connectedControllers.contains(where: { $0.playerIndex != nil }) && Settings.localControllerPlayerIndex == nil
        {
            Settings.localControllerPlayerIndex = 0
        }
        
        var names = [Int: String]()
        
        for playerIndex in 0..<4
        {
            if Settings.localControllerPlayerIndex == playerIndex
            {
                names[playerIndex] = LocalDeviceController().name
            }
            else if let controller = connectedControllers.first(where: { $0.playerIndex == playerIndex })
            {
                names[playerIndex] = controller.name
            }
        }
        
        controllerNames = names
    }
}
