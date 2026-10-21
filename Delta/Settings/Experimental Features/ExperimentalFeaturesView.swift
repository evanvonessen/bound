//
//  ExperimentalFeaturesView.swift
//  Delta
//
//  Created by Riley Testut on 4/5/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import SwiftUI
import Combine

import DeltaFeatures

extension ExperimentalFeaturesView
{
    private class ViewModel: ObservableObject
    {
        @Published
        var sortedFeatures: [any AnyFeature]
        
        init()
        {
            // Renderer selection lives in regular Video settings; retain its
            // backing feature only for saved-preference compatibility.
            self.sortedFeatures = ExperimentalFeatures.shared.allFeatures.filter {
                $0.key != ExperimentalFeatures.shared.metal.key
            }.sorted { (featureA, featureB) in
                return String(describing: featureA.name) < String(describing: featureB.name)
            }
        }
    }
}

struct ExperimentalFeaturesView: View
{
    @StateObject
    private var viewModel: ViewModel = ViewModel()
    
    private var localizedTitle: String { NSLocalizedString("Experimental Features", comment: "") }
    
    var body: some View {
        Form {
            Section {
            } header: {
                if !PurchaseManager.shared.isExperimentalFeaturesAvailable
                {
                    VStack(spacing: 0) {
                        BecomePatronButton()
                        Text(" ") // Newline
                    }
                }
            } footer: {
                Text("These features have been added by contributors to the open-source Delta project on GitHub and are currently being tested.\n\nYou may encounter bugs when using these features.")
                    .font(.subheadline)
            }
            
            ForEach(viewModel.sortedFeatures, id: \.key) { feature in
                if let enabledFeature = feature as? any EnabledFeature
                {
                    section(for: enabledFeature)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // Cannot open existential if return type uses concrete type T in non-covariant position (e.g. Box<T>).
    // So instead we erase return type to AnyView.
    private func section<T: EnabledFeature>(for feature: T) -> AnyView
    {
        let section = FeatureSection(feature: feature)
        return AnyView(section)
    }
}

extension ExperimentalFeaturesView
{
    static func makeViewController() -> UIHostingController<some View>
    {
        let experimentalFeaturesView = ExperimentalFeaturesView()
        
        let hostingController = UIHostingController(rootView: experimentalFeaturesView)
        hostingController.navigationItem.largeTitleDisplayMode = .never
        hostingController.navigationItem.title = experimentalFeaturesView.localizedTitle
        return hostingController
    }
}

private struct FeatureSection<T: EnabledFeature>: View
{
    @ObservedObject
    var feature: T
    
    var body: some View {
        Section {
            NavigationLink(destination: FeatureDetailView(feature: feature)) {
                HStack {
                    Text(feature.name)
                    Spacer()
                    
                    if feature.isEnabled
                    {
                        Text("On")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }  footer: {
            if let description = feature.description
            {
                Text(description)
            }
        }
    }
}

#Preview(body: {
    ExperimentalFeaturesView()
})
