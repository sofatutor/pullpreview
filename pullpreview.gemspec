require_relative "./lib/pull_preview/version"

Gem::Specification.new do |s|
  s.name        = 'pullpreview'
  s.version     = PullPreview::VERSION
  s.date        = Time.now.utc.strftime("%Y-%m-%d")
  s.summary     = "PullPreview starts live environments on AWS from a Docker Compose file"
  s.description = "Secure, no-maintenance"
  s.authors     = ["Cyril Rohr", "Quentin Bonnard"]
  s.email       = 'support@pullpreview.com'
  s.files       = Dir.glob("{lib,data}/**/*") + %w(LICENSE README.md)
  s.homepage    = 'https://pullpreview.com'
  s.license     = 'Nonstandard'
  s.executables = ["pullpreview"]
  s.require_path = 'lib'
  s.add_dependency('aws-sdk-lightsail')
  s.add_dependency('slop')
  s.add_dependency('octokit')
  s.add_dependency('terminal-table')
  s.add_dependency('pry')
end
