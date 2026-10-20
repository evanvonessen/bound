//
//  PlayerControllerView.swift
//  Delta
//
//  Created by Caroline Moore on 7/1/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI
import CoreData

import DeltaCore

// Assigns a controller to a player and, for external controllers, lists each system's controls to customize.
struct PlayerControllerView: View
{
    let playerIndex: Int
    
    private var connectedControllers: [GameController] { ExternalGameControllerManager.shared.connectedControllers }
    
    @SwiftUI.State
    private var selectedController: GameController?
    
    @FetchRequest
    private var customMappings: FetchedResults<GameControllerInputMapping>
    
    init(playerIndex: Int)
    {
        self.playerIndex = playerIndex
        
        let fetchRequest: NSFetchRequest<GameControllerInputMapping> = GameControllerInputMapping.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "%K == %d", #keyPath(GameControllerInputMapping.playerIndex), playerIndex)
        fetchRequest.sortDescriptors = []
        self._customMappings = FetchRequest(fetchRequest: fetchRequest)
    }
    
    var body: some View {
        Form {
            if playerIndex != 0
            {
                Section {
                    SelectionRow(title: String(localized: "None"), isSelected: selectedController == nil) { select(nil) }
                }
            }
            
            Section {
                SelectionRow(title: LocalDeviceController().name, isSelected: selectedController?.isLocalDevice == true) { select(LocalDeviceController()) }
            } header: {
                Text("This Device")
            }
            
            Section {
                if connectedControllers.isEmpty
                {
                    Text("No controllers connected.")
                        .foregroundStyle(.secondary)
                }
                else
                {
                    // Using offset to identify controller is ok here: rows have no state and the controller list is observed.
                    ForEach(Array(connectedControllers.enumerated()), id: \.offset) { _, controller in
                        SelectionRow(title: controller.name, isSelected: selectedController === controller) {
                            select(controller)
                        }
                    }
                }
            } header: {
                Text("Game Controllers")
            }
            
            if let controller = selectedController, !controller.isLocalDevice
            {
                Section {
                    ForEach(System.registeredSystems, id: \.self) { system in
                        let isCustomized = customMappings.contains { $0.gameType == system.gameType && $0.gameControllerInputType == controller.inputType }
                        
                        NavigationLink {
                            ControlsEditorView(controller: controller, system: system, playerIndex: playerIndex)
                        } label: {
                            LabeledContent(system.localizedDisplayName) {
                                Text(isCustomized ? "Custom" : "Default")
                                    .foregroundStyle(isCustomized ? Color.accentColor : Color.secondary)
                            }
                            .contentShape(.rect) // Makes entire row tappable
                        }
                    }
                } header: {
                    Text("Customize Controls")
                }
            }
        }
        .tint(.accentColor)
        .navigationTitle("Player \(playerIndex + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: selectedController?.isLocalDevice)
        .onAppear(perform: updateSelectedController)
        .onChange(of: connectedControllers as NSArray) { updateSelectedController() } // Cast to NSArray which is equatable
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .localControllerPlayerIndex else { return }
            updateSelectedController()
        }
    }
}

private struct SelectionRow: View
{
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                
                Spacer()
                
                if isSelected
                {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private extension PlayerControllerView
{
    func select(_ controller: GameController?)
    {
        // Ensure it's still a discovered controller, or else it might crash when setting player index.
        if let selectedController, selectedController.isLocalDevice || connectedControllers.contains(where: { $0 === selectedController })
        {
            selectedController.playerIndex = nil
        }
        
        controller?.playerIndex = playerIndex
        
        updateSelectedController()
    }
    
    func updateSelectedController()
    {
        // If no external controller is assigned to any player, touch will control gameplay.
        // So if touch is unassigned, assign it to Player 1. (Mirrors GameViewController.updateControllers().)
        if !connectedControllers.contains(where: { $0.playerIndex != nil }) && Settings.localControllerPlayerIndex == nil
        {
            Settings.localControllerPlayerIndex = 0
        }
        
        if let controller = connectedControllers.first(where: { $0.playerIndex == playerIndex })
        {
            selectedController = controller
        }
        else if Settings.localControllerPlayerIndex == playerIndex
        {
            selectedController = LocalDeviceController()
        }
        else
        {
            selectedController = nil
        }
    }
}

private extension GameController
{
    var isLocalDevice: Bool { self is LocalDeviceController }
}
