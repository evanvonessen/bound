require "digest"

module BoundBuildPaths
  # SwiftPM records absolute artifact paths. A moved checkout or Xcode must
  # receive its own cache rather than reuse copied DerivedData metadata.
  def self.verify_derived_data(root, developer_dir)
    root = File.realpath(root)
    developer_dir = File.realpath(developer_dir)
    key = Digest::SHA256.hexdigest([root, developer_dir].join("\0"))[0, 16]
    File.join(root, ".build", "fastlane", "DerivedData", key)
  end
end
