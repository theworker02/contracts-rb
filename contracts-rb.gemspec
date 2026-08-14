Gem::Specification.new do |spec|
  spec.name = "contracts-rb"
  spec.version = "0.4.0"
  spec.authors = ["Magnexis"]
  spec.summary = "Behavioral contracts for Ruby methods and objects"
  spec.description = "Expressive runtime contracts for parameters, results, state, invariants, exceptions, tuples, and structured hash shapes."
  spec.homepage = "https://github.com/theworker02/contracts-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir[
    "assets/**/*", "lib/**/*.rb", "exe/*", "examples/**/*", "docs/**/*", "README.md", "LICENSE.txt",
    "CHANGELOG.md", "SECURITY.md", "CONTRIBUTING.md", "sig/**/*.rbs"
  ]
  spec.bindir = "exe"
  spec.executables = ["contracts"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/theworker02/contracts-rb"
  spec.metadata["changelog_uri"] = "https://github.com/theworker02/contracts-rb/blob/master/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/theworker02/contracts-rb/issues"
  spec.metadata["documentation_uri"] = "https://github.com/theworker02/contracts-rb/tree/master/docs"
end
