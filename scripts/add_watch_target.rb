#!/usr/bin/env ruby
require 'xcodeproj'

PROJECT = 'flaccy.xcodeproj'
WATCH_NAME = 'flaccyWatch Watch App'
WATCH_DIR = 'flaccyWatch Watch App'
WATCH_BUNDLE_ID = 'com.midgarcorp.flaccy.watchkitapp'
IOS_BUNDLE_ID = 'com.midgarcorp.flaccy'
TEAM = 'P4DQK6SRKR'

# The copy deck lives in `flaccy/` because FlaccyCore declares no
# defaultLocalization and so may hold no user-facing string. The glob below only
# walks the watch folder, so these three have to be named explicitly or the
# watch silently falls back to its own hand-copied wording — which is exactly
# how it ended up describing phases that no longer exist.
SHARED_GROUP = 'Shared Copy'.freeze
SHARED_SOURCES = [
  'flaccy/LibraryLoadPhaseCopy.swift',
  'flaccy/EnrichmentJobCopy.swift',
  'flaccy/LibraryDebutCopy.swift',
].freeze

project = Xcodeproj::Project.open(PROJECT)

ios_target = project.targets.find { |t| t.name == 'flaccy' }
raise 'iOS target not found' unless ios_target

# --- 1. Local Swift package reference ------------------------------------
local_pkg = project.root_object.package_references.find do |ref|
  ref.respond_to?(:relative_path) && ref.relative_path == 'FlaccyCore'
end
unless local_pkg
  local_pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  local_pkg.relative_path = 'FlaccyCore'
  project.root_object.package_references << local_pkg
  puts 'Added local package reference FlaccyCore'
end

def link_core(project, target)
  return if target.package_product_dependencies.any? { |d| d.product_name == 'FlaccyCore' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'FlaccyCore'
  target.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
  puts "Linked FlaccyCore to #{target.name}"
end

# --- 2. Watch app target -------------------------------------------------
watch_target = project.targets.find { |t| t.name == WATCH_NAME }
if watch_target
  puts 'Watch target already exists; refreshing settings'
else
  watch_target = project.new_target(:application, WATCH_NAME, :watchos, '11.0', nil, :swift)
  puts 'Created watch target'
end

settings = {
  'SDKROOT' => 'watchos',
  'TARGETED_DEVICE_FAMILY' => '4',
  'WATCHOS_DEPLOYMENT_TARGET' => '11.0',
  'PRODUCT_BUNDLE_IDENTIFIER' => WATCH_BUNDLE_ID,
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'INFOPLIST_FILE' => "#{WATCH_DIR}/Info.plist",
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'INFOPLIST_KEY_CFBundleDisplayName' => 'Flaccy',
  'INFOPLIST_KEY_UISupportedInterfaceOrientations' => 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown',
  'CURRENT_PROJECT_VERSION' => '1',
  'MARKETING_VERSION' => '1.0',
  'DEVELOPMENT_TEAM' => TEAM,
  'SWIFT_VERSION' => '5.0',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
  'ENABLE_PREVIEWS' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
}

# The watch app reaches the archive by being embedded in flaccy.app, never on
# its own. Installed as a sibling it lands a second bundle in
# Products/Applications, which leaves the archive with no ApplicationProperties
# at all — Xcode then offers zero distribution methods and exportArchive dies
# with "expected one {}", naming the method rather than the real cause.
RELEASE_ONLY = { 'SKIP_INSTALL' => 'YES' }.freeze

# Release ships through buildvm, which passes a manual profile on the command
# line; a target left on Automatic makes xcodebuild refuse the archive with
# "conflicting provisioning settings" long after whoever re-ran this script has
# forgotten they did. Debug is signed automatically for device runs.
RELEASE_SIGNING = {
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY' => 'Apple Distribution',
  'PROVISIONING_PROFILE_SPECIFIER' => 'flaccy Watch AppStore 2026',
}.freeze

watch_target.build_configurations.each do |config|
  config.build_settings.merge!(settings)
  if config.name == 'Release'
    config.build_settings.merge!(RELEASE_SIGNING).merge!(RELEASE_ONLY)
  else
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['SKIP_INSTALL'] = 'YES'
  end
end

# --- 3. Watch sources, resources, Info.plist -----------------------------
existing_group = project.main_group.children.find { |c| c.display_name == WATCH_NAME }
existing_group.remove_from_project if existing_group
group = project.main_group.new_group(WATCH_NAME, WATCH_DIR)

# Clear any stale build-file references on the watch target
watch_target.source_build_phase.clear
watch_target.resources_build_phase.clear

Dir.chdir(File.dirname(__FILE__) + '/..') do
  swift_files = Dir.glob("#{WATCH_DIR}/**/*.swift").sort
  swift_files.each do |path|
    rel = path.sub("#{WATCH_DIR}/", '')
    ref = group.new_file(rel)
    watch_target.source_build_phase.add_file_reference(ref)
  end
  puts "Added #{swift_files.count} swift files to watch target"

  assets_ref = group.new_file('Assets.xcassets')
  watch_target.resources_build_phase.add_file_reference(assets_ref)
  group.new_file('Info.plist')
end

stale_shared = project.main_group.children.find { |c| c.display_name == SHARED_GROUP }
stale_shared.remove_from_project if stale_shared
shared_group = project.main_group.new_group(SHARED_GROUP, nil)
SHARED_SOURCES.each do |path|
  ref = shared_group.new_file(path)
  watch_target.source_build_phase.add_file_reference(ref)
end
puts "Added #{SHARED_SOURCES.count} shared copy files to watch target"

# --- 4. Link FlaccyCore --------------------------------------------------
link_core(project, watch_target)
link_core(project, ios_target)

# --- 5. Embed watch app in the iOS app -----------------------------------
embed_phase = ios_target.copy_files_build_phases.find { |p| p.name == 'Embed Watch Content' }
unless embed_phase
  embed_phase = ios_target.new_copy_files_build_phase('Embed Watch Content')
  embed_phase.symbol_dst_subfolder_spec = :products_directory
  embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
  puts 'Created Embed Watch Content phase'
end
embed_phase.files.to_a.each { |f| embed_phase.remove_build_file(f) }
embed_file = embed_phase.add_file_reference(watch_target.product_reference)
embed_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

ios_target.add_dependency(watch_target) unless ios_target.dependencies.any? { |d| d.target == watch_target }

project.save
puts 'Saved project.'
