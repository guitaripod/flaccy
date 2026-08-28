#!/usr/bin/env ruby
require 'xcodeproj'

PROJECT = File.expand_path('../flaccy.xcodeproj', __dir__)
REPO = 'https://github.com/RevenueCat/purchases-ios'
MIN_VERSION = '5.87.1'

project = Xcodeproj::Project.open(PROJECT)

package = project.root_object.package_references.find do |ref|
  ref.respond_to?(:repositoryURL) && ref.repositoryURL.to_s == REPO
end
unless package
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = REPO
  package.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => MIN_VERSION }
  project.root_object.package_references << package
  puts "Added package reference #{REPO}"
end

%w[flaccy flaccyMac].each do |name|
  target = project.targets.find { |t| t.name == name }
  raise "#{name} target not found" unless target
  next if target.package_product_dependencies.any? { |d| d.product_name == 'RevenueCat' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'RevenueCat'
  dep.package = package
  target.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
  puts "Linked RevenueCat to #{name}"
end

project.save
