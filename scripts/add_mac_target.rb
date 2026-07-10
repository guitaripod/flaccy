#!/usr/bin/env ruby
require 'xcodeproj'

PROJECT = 'flaccy.xcodeproj'
MAC_NAME = 'flaccyMac'
MAC_DIR = 'flaccyMac'
MAC_BUNDLE_ID = 'com.midgarcorp.flaccy.mac'
TEAM = 'P4DQK6SRKR'

SHARED_IOS_FILES = %w[
  Album.swift
  AlbumArtworkCache.swift
  AppLogger.swift
  ArtworkPalette.swift
  AudioPlayer.swift
  Backdrop.metal
  ChartsViewModel.swift
  DatabaseManager.swift
  DetailEnrichment.swift
  GroqService.swift
  ImageCache.swift
  LastFMService.swift
  LastFMStatsService.swift
  Library.swift
  LibraryFilter.swift
  LibraryLayoutMode.swift
  LibraryPaths.swift
  LibraryViewModel.swift
  ListeningGuideContent.swift
  LovedTracksService.swift
  LyricsService.swift
  MetadataEnrichmentService.swift
  MetadataService.swift
  MusicKitService.swift
  NowPlayingViewModel.swift
  PlatformImage.swift
  PurchaseManager.swift
  RecapModels.swift
  SampleMusicService.swift
  ScreenshotSeeder.swift
  Secrets.swift
  SimilarArtistService.swift
  SonglinkService.swift
  StationBuilder.swift
  SuggestedPlaylistService.swift
  Track.swift
  WantlistService.swift
  WantlistViewModel.swift
  YearInMusicModels.swift
  YearInMusicService.swift
].freeze

project = Xcodeproj::Project.open(PROJECT)

ios_target = project.targets.find { |t| t.name == 'flaccy' }
raise 'iOS target not found' unless ios_target

local_pkg = project.root_object.package_references.find do |ref|
  ref.respond_to?(:relative_path) && ref.relative_path == 'FlaccyCore'
end
raise 'FlaccyCore package reference not found' unless local_pkg

grdb_pkg = project.root_object.package_references.find do |ref|
  ref.respond_to?(:repositoryURL) && ref.repositoryURL.to_s.include?('GRDB')
end
raise 'GRDB package reference not found' unless grdb_pkg

def link_package_product(project, target, product_name, package = nil)
  return if target.package_product_dependencies.any? { |d| d.product_name == product_name }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = product_name
  dep.package = package if package
  target.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
  puts "Linked #{product_name} to #{target.name}"
end

mac_target = project.targets.find { |t| t.name == MAC_NAME }
if mac_target
  puts 'Mac target already exists; refreshing settings'
else
  mac_target = project.new_target(:application, MAC_NAME, :osx, '26.0')
  puts 'Created mac target'
end
mac_target.product_reference.path = 'Flaccy.app' if mac_target.product_reference

settings = {
  'SDKROOT' => 'macosx',
  'MACOSX_DEPLOYMENT_TARGET' => '26.0',
  'PRODUCT_BUNDLE_IDENTIFIER' => MAC_BUNDLE_ID,
  'PRODUCT_NAME' => 'Flaccy',
  'INFOPLIST_FILE' => "#{MAC_DIR}/Info.plist",
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'CODE_SIGN_ENTITLEMENTS' => "#{MAC_DIR}/flaccyMac.entitlements",
  'CODE_SIGN_STYLE' => 'Automatic',
  'DEVELOPMENT_TEAM' => TEAM,
  'ENABLE_HARDENED_RUNTIME' => 'NO',
  'CURRENT_PROJECT_VERSION' => '1',
  'MARKETING_VERSION' => '1.0',
  'SWIFT_VERSION' => '5.0',
  'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'MainActor',
  'SWIFT_APPROACHABLE_CONCURRENCY' => 'YES',
  'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY' => 'YES',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
  'COMBINE_HIDPI_IMAGES' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks',
  'EXCLUDED_SOURCE_FILE_NAMES' => 'LaunchScreen.storyboard',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'SKIP_INSTALL' => 'NO',
}
mac_target.build_configurations.each do |config|
  config.build_settings.merge!(settings)
  config.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET')
  if config.name == 'Release'
    config.build_settings.merge!(
      'CODE_SIGN_STYLE' => 'Manual',
      'CODE_SIGN_IDENTITY' => 'Apple Distribution',
      'PROVISIONING_PROFILE_SPECIFIER' => 'flaccy-mac-appstore-2026',
      'DEVELOPMENT_TEAM' => TEAM
    )
  end
end

mac_group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) && c.path == MAC_DIR
end
unless mac_group
  mac_group = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  mac_group.path = MAC_DIR
  mac_group.source_tree = '<group>'
  project.main_group.children << mac_group
  puts 'Created flaccyMac synchronized root group'
end
unless mac_target.file_system_synchronized_groups.include?(mac_group)
  mac_target.file_system_synchronized_groups << mac_group
  puts 'Attached flaccyMac group to mac target'
end

mac_exception_set = mac_group.exceptions.find { |e| e.target == mac_target }
unless mac_exception_set
  mac_exception_set = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
  mac_exception_set.target = mac_target
  mac_group.exceptions << mac_exception_set
  puts 'Created exception set for flaccyMac group'
end
mac_exception_set.membership_exceptions = ['Info.plist']

ios_group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) && c.path == 'flaccy'
end
raise 'flaccy synchronized root group not found' unless ios_group

exceptions = Dir.chdir(File.dirname(__FILE__) + '/..') do
  Dir.children('flaccy').sort.reject do |entry|
    SHARED_IOS_FILES.include?(entry) || entry.start_with?('.') || entry == 'Base.lproj'
  end
end

exception_set = ios_group.exceptions.find { |e| e.target == mac_target }
unless exception_set
  exception_set = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
  exception_set.target = mac_target
  ios_group.exceptions << exception_set
  puts 'Created exception set for flaccy group in mac target'
end
exception_set.membership_exceptions = exceptions
puts "Mac target excludes #{exceptions.count} iOS-only entries from flaccy/"

unless mac_target.file_system_synchronized_groups.include?(ios_group)
  mac_target.file_system_synchronized_groups << ios_group
  puts 'Attached shared flaccy group to mac target'
end

link_package_product(project, mac_target, 'FlaccyCore')
link_package_product(project, mac_target, 'GRDB', grdb_pkg)

UITEST_NAME = 'flaccyMacUITests'
uitest_target = project.targets.find { |t| t.name == UITEST_NAME }
if uitest_target
  puts 'Mac UI test target already exists; refreshing settings'
else
  uitest_target = project.new_target(:ui_test_bundle, UITEST_NAME, :osx, '26.0')
  puts 'Created mac UI test target'
end
uitest_settings = {
  'SDKROOT' => 'macosx',
  'MACOSX_DEPLOYMENT_TARGET' => '26.0',
  'PRODUCT_NAME' => UITEST_NAME,
  'PRODUCT_BUNDLE_IDENTIFIER' => "#{MAC_BUNDLE_ID}.uitests",
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'CODE_SIGN_STYLE' => 'Automatic',
  'DEVELOPMENT_TEAM' => TEAM,
  'SWIFT_VERSION' => '5.0',
  'TEST_TARGET_NAME' => MAC_NAME,
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
}
uitest_target.build_configurations.each do |config|
  config.build_settings.merge!(uitest_settings)
  config.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET')
  config.build_settings.delete('INFOPLIST_FILE')
end
uitest_target.add_dependency(mac_target) unless uitest_target.dependencies.any? { |d| d.target == mac_target }

uitest_group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) && c.path == UITEST_NAME
end
unless uitest_group
  uitest_group = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  uitest_group.path = UITEST_NAME
  uitest_group.source_tree = '<group>'
  project.main_group.children << uitest_group
  puts 'Created flaccyMacUITests synchronized root group'
end
unless uitest_target.file_system_synchronized_groups.include?(uitest_group)
  uitest_target.file_system_synchronized_groups << uitest_group
  puts 'Attached flaccyMacUITests group to UI test target'
end

project.save
puts 'Saved project.'

scheme_path = Xcodeproj::XCScheme.shared_data_dir(PROJECT) + "#{MAC_NAME}.xcscheme"
unless File.exist?(scheme_path)
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(mac_target)
  scheme.set_launch_target(mac_target)
  scheme.save_as(PROJECT, MAC_NAME, true)
  puts 'Created shared scheme flaccyMac'
end

scheme = Xcodeproj::XCScheme.new(scheme_path)
unless scheme.test_action.testables.any? { |t| t.buildable_references.any? { |r| r.target_name == UITEST_NAME } }
  testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(uitest_target)
  scheme.test_action.add_testable(testable)
  scheme.save!
  puts 'Added flaccyMacUITests to flaccyMac scheme test action'
end

scheme_xml = File.read(scheme_path)
unless scheme_xml.include?('StoreKitConfigurationFileReference')
  storekit_ref = <<~XML.chomp
        <StoreKitConfigurationFileReference
           identifier = "../../flaccyMac/Flaccy-mac.storekit">
        </StoreKitConfigurationFileReference>
  XML
  scheme_xml = scheme_xml.sub(
    %r{(<LaunchAction[^>]*>\n)},
    "\\1#{storekit_ref}\n"
  )
  File.write(scheme_path, scheme_xml)
  puts 'Wired Flaccy-mac.storekit into flaccyMac scheme'
end
