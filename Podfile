platform :ios, '17.0'

inhibit_all_warnings!

target 'Delta' do
    use_modular_headers!

    pod 'SQLite.swift', '~> 0.12.0'
    pod 'SDWebImage', '~> 3.8'
    pod 'SMCalloutView', '~> 2.1.0'

    pod 'Roxas', :path => 'External/Roxas'
    pod 'Harmony', :path => 'External/Harmony'
end

target 'DeltaPreviews' do
    use_modular_headers!

    pod 'Roxas', :path => 'External/Roxas'
end

post_install do |installer|
    # Keep generated project settings aligned with the reviewed Xcode 27.1 setup.
    installer.pods_project.root_object.attributes['LastUpgradeCheck'] = '2710'
    installer.pods_project.root_object.attributes['BuildIndependentTargetsInParallel'] = '1'
    installer.pods_project.build_configurations.each do |config|
        config.build_settings['DEAD_CODE_STRIPPING'] = 'YES'
    end

    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'

            # These pinned archives contain category-only or conditionally empty
            # objects. Keep libtool's other diagnostics enabled.
            if ['SDWebImage', 'Roxas', 'GTMSessionFetcher', 'AppAuth', 'GTMAppAuth'].include?(target.name)
                config.build_settings['LIBTOOL_NO_WARNING_FOR_NO_SYMBOLS'] = 'YES'
            end
        end
    end

    # Swift adds its runtime search paths. CocoaPods' old toolchain-wide path also
    # expands into the downloaded Metal toolchain, which has no Swift runtime.
    installer.aggregate_targets.each do |target|
        target.xcconfigs.each do |configuration, config|
            paths = config.attributes['LIBRARY_SEARCH_PATHS']
            next unless paths

            config.attributes['LIBRARY_SEARCH_PATHS'] =
                paths.gsub('"${TOOLCHAIN_DIR}/usr/lib/swift/${PLATFORM_NAME}"', '').strip
            config.save_as(target.xcconfig_path(configuration))
        end
    end
end
