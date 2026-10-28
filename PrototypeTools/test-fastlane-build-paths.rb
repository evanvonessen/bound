require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../fastlane/build_paths"

class BuildPathsTest < Minitest::Test
  def test_relocated_checkout_and_xcode_get_new_caches
    Dir.mktmpdir do |tmp|
      old_root, new_root, xcode, moved_xcode = %w[old new Xcode DeveloperXcode].map { |name| File.join(tmp, name) }
      [old_root, new_root, xcode, moved_xcode].each { |path| FileUtils.mkdir_p(path) }
      before = BoundBuildPaths.verify_derived_data(old_root, xcode)
      after = BoundBuildPaths.verify_derived_data(new_root, xcode)
      refute_equal File.basename(before), File.basename(after)
      refute_equal after, BoundBuildPaths.verify_derived_data(new_root, moved_xcode)
      assert_equal after, BoundBuildPaths.verify_derived_data(new_root, xcode)
      refute File.exist?(after)
      link = File.join(tmp, "alias")
      File.symlink(new_root, link)
      assert_equal after, BoundBuildPaths.verify_derived_data(link, xcode)
    end
  end
end
