# Run against an already-built simulator app that embeds this fork (CocoaPods supplies xcodeproj):
# ruby scripts/test-search-bar-ios.rb /path/to/App.app <simulator-udid> /path/to/test-output
require 'xcodeproj'
require 'fileutils'
require 'shellwords'

# RNS_SEARCH_MUTATION=missing-dismiss|missing-text-update|unconditional-dismiss exercises test sensitivity.
mutation = ENV['RNS_SEARCH_MUTATION']
abort 'Unknown RNS_SEARCH_MUTATION' if mutation && !%w[missing-dismiss missing-text-update unconditional-dismiss].include?(mutation)
app, device, output = ARGV
abort 'Usage: ruby scripts/test-search-bar-ios.rb <app> <simulator-udid> <output>' unless output
app = File.expand_path(app)
output = File.expand_path(output)
executable = IO.popen(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleExecutable', "#{app}/Info.plist"], &:read).strip
bundle = IO.popen(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier', "#{app}/Info.plist"], &:read).strip
abort 'Could not read host app metadata' if executable.empty? || bundle.empty?
FileUtils.mkdir_p(output)
File.write("#{output}/host.m", 'int main(int argc, char **argv) { return 0; }')
project = Xcodeproj::Project.new("#{output}/SearchEvents.xcodeproj")
host = project.new_target(:application, executable, :ios, '18.0')
host.source_build_phase.add_file_reference(project.main_group.new_file("#{output}/host.m"))
host.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => bundle,
                              'GENERATE_INFOPLIST_FILE' => 'YES',
                              'CODE_SIGNING_ALLOWED' => 'NO',
                              'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO')
end
# Xcode needs an application target to recognize TEST_HOST; reuse the compiled client, not a mock.
copy = host.new_shell_script_build_phase('Use built native client')
copy.shell_script = "ditto #{app.shellescape} \"$BUILT_PRODUCTS_DIR/#{executable}.app\""
copy.always_out_of_date = '1'
target = project.new_target(:unit_test_bundle, 'SearchEvents', :ios, '18.0')
source = project.main_group.new_file(File.expand_path('../ios/__tests__/RNSSearchBarTests.mm', __dir__))
target.source_build_phase.add_file_reference(source)
target.frameworks_build_phase.add_file_reference(project.frameworks_group.new_file('System/Library/Frameworks/UIKit.framework', :sdk_root))
target.build_configurations.each do |config|
  config.build_settings.merge!('TEST_HOST' => "$(BUILT_PRODUCTS_DIR)/#{executable}.app/#{executable}",
                              'BUNDLE_LOADER' => '$(TEST_HOST)',
                              'PRODUCT_BUNDLE_IDENTIFIER' => 'local.rns.SearchEvents',
                              'GENERATE_INFOPLIST_FILE' => 'YES',
                              'CODE_SIGNING_ALLOWED' => 'NO',
                              'CLANG_ENABLE_OBJC_ARC' => 'YES',
                              'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@loader_path/Frameworks', '@executable_path/Frameworks'])
end
target.add_dependency(host)
project.root_object.attributes['TargetAttributes'] = { target.uuid => { 'TestTargetID' => host.uuid } }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(target)
scheme.add_test_target(target)
if mutation
  scheme.test_action.should_use_launch_scheme_args_env = false
  scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
    { :key => 'RNS_SEARCH_MUTATION', :value => mutation, :enabled => true }
  ])
end
scheme.save_as(project.path, 'SearchEvents', true)
exec 'xcodebuild', 'test', '-project', project.path.to_s, '-scheme', 'SearchEvents',
     '-destination', "platform=iOS Simulator,id=#{device}", '-derivedDataPath', "#{output}/build"
