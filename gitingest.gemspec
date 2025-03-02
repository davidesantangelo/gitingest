# frozen_string_literal: true

require_relative "lib/gitingest/version"

Gem::Specification.new do |spec|
  spec.name = "gitingest"
  spec.version = Gitingest::VERSION
  spec.authors = ["Davide Santangelo"]
  spec.email = ["davide.santangelo@gmail.com"]

  spec.summary       = "Efficiently generate AI prompts from GitHub repositories for code analysis and documentation"
  spec.description   = "Gitingest is a powerful command-line tool that fetches files from GitHub repositories and generates consolidated text prompts for AI analysis. It features smart file filtering, concurrent processing, custom exclusion patterns, authentication support, and automatic rate limit handling. Perfect for creating context-rich prompts from codebases for AI assistants, documentation generation, or codebase analysis."
  spec.homepage      = "https://github.com/davidesantangelo/gitingest"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "bin" # Change from "exe" to "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) } # Change from "exe/" to "bin/"
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html

  # Dependencies
  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "octokit", "~> 5.0"
  spec.add_dependency "optparse", "~> 0.1"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
