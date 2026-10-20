//
//  Features.swift
//  Delta
//
//  Created by Riley Testut on 4/21/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import DeltaFeatures

extension Settings
{
    struct Features: FeatureContainer
    {
        static let shared = Features()
        
        // Standard Features
        
        @Feature(name: "DS AirPlay", options: DSAirPlayOptions())
        var dsAirPlay
        
        // Previous Experimental Features
        
        @Feature(enabledWith: CustomFastForwardOptions())
        var customFastForward

        @Feature(enabledWith: RetroAchievementsOptions())
        var retroAchievements
        
        private init()
        {
            self.prepareFeatures()
        }
    }
}
