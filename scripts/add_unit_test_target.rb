#!/usr/bin/env ruby
require 'xcodeproj'
require 'json'

PROJECT = 'flaccy.xcodeproj'
TEST_NAME = 'flaccyTests'
TEST_DIR = 'flaccyTests'
TEST_BUNDLE_ID = 'com.midgarcorp.flaccyTests'
HOST_NAME = 'flaccy'
TEAM = 'P4DQK6SRKR'
TEST_PLAN = 'flaccy.xctestplan'

project = Xcodeproj::Project.open(PROJECT)

host_target = project.targets.find { |t| t.name == HOST_NAME }
raise 'iOS target not found' unless host_target

test_target = project.targets.find { |t| t.name == TEST_NAME }
if test_target
  puts 'Unit test target already exists; refreshing settings'
else
  test_target = project.new_target(:unit_test_bundle, TEST_NAME, :ios, '18.6', nil, :swift)
  puts 'Created unit test target'
end

# `@testable import flaccy` needs the app as the bundle loader: the test bundle
# links nothing of its own and resolves every symbol — including FlaccyCore,
# which the app already statically carries — against the host binary. The
# isolation settings must match the app target's or the app's `nonisolated`
# declarations read differently from inside the tests.
settings = {
  'BUNDLE_LOADER' => '$(TEST_HOST)',
  'TEST_HOST' => "$(BUILT_PRODUCTS_DIR)/#{HOST_NAME}.app/#{HOST_NAME}",
  'TEST_TARGET_NAME' => HOST_NAME,
  'PRODUCT_BUNDLE_IDENTIFIER' => TEST_BUNDLE_ID,
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'IPHONEOS_DEPLOYMENT_TARGET' => '18.6',
  'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
  'TARGETED_DEVICE_FAMILY' => '1',
  'CURRENT_PROJECT_VERSION' => '2',
  'MARKETING_VERSION' => '1.0',
  'DEVELOPMENT_TEAM' => TEAM,
  'CODE_SIGN_STYLE' => 'Automatic',
  'SWIFT_VERSION' => '5.0',
  'SWIFT_APPROACHABLE_CONCURRENCY' => 'YES',
  'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'MainActor',
  'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'NO',
}
test_target.build_configurations.each do |config|
  config.build_settings.merge!(settings)
end

existing_group = project.main_group.children.find { |c| c.display_name == TEST_NAME }
existing_group.remove_from_project if existing_group
group = project.main_group.new_group(TEST_NAME, TEST_DIR)

test_target.source_build_phase.clear

Dir.chdir(File.dirname(__FILE__) + '/..') do
  swift_files = Dir.glob("#{TEST_DIR}/**/*.swift").sort
  raise "No sources in #{TEST_DIR}/" if swift_files.empty?
  swift_files.each do |path|
    ref = group.new_file(path.sub("#{TEST_DIR}/", ''))
    test_target.source_build_phase.add_file_reference(ref)
  end
  puts "Added #{swift_files.count} swift files to #{TEST_NAME}"
end

test_target.add_dependency(host_target) unless test_target.dependencies.any? { |d| d.target == host_target }

project.save
puts 'Saved project.'

plan_path = File.expand_path(File.dirname(__FILE__) + "/../#{TEST_PLAN}")
plan = JSON.parse(File.read(plan_path))
unless plan['testTargets'].any? { |t| t['target']['name'] == TEST_NAME }
  plan['testTargets'].unshift(
    'target' => {
      'containerPath' => "container:#{PROJECT}",
      'identifier' => test_target.uuid,
      'name' => TEST_NAME,
    }
  )
  File.write(plan_path, JSON.pretty_generate(plan) + "\n")
  puts "Registered #{TEST_NAME} in #{TEST_PLAN}"
end
