# Gitingest

Gitingest is a Ruby gem that fetches files from a GitHub repository and generates a consolidated text prompt, which can be used as input for large language models, documentation generation, or other purposes.

## Installation

### From RubyGems

```bash
gem install gitingest
```

### From Source

```bash
git clone https://github.com/davidesantangelo/gitingest.git
cd gitingest
bundle install
bundle exec rake install
```

## Usage

### Command Line

```bash
# Basic usage (public repository)
gitingest --repository user/repo 

# With GitHub token for private repositories
gitingest --repository user/repo --token YOUR_GITHUB_TOKEN

# Specify a custom output file
gitingest --repository user/repo --output my_prompt.txt

# Specify a different branch
gitingest --repository user/repo --branch develop

# Exclude additional patterns
gitingest --repository user/repo --exclude "*.md,docs/"

# Quiet mode
gitingest --repository user/repo --quiet

# Verbose mode
gitingest --repository user/repo --verbose
```

#### Available Options

- `-r, --repository REPO`: GitHub repository (username/repo) [Required]
- `-t, --token TOKEN`: GitHub personal access token [Optional but recommended]
- `-o, --output FILE`: Output file for the prompt [Default: reponame_prompt.txt]
- `-e, --exclude PATTERN`: File patterns to exclude (comma separated)
- `-b, --branch BRANCH`: Repository branch [Default: main]
- `-h, --help`: Show help message

### As a Library

```ruby
require "gitingest"

# Basic usage
generator = Gitingest::Generator.new(
  repository: "user/repo",
  token: "YOUR_GITHUB_TOKEN" # optional
)
generator.run

# With custom options
generator = Gitingest::Generator.new(
  repository: "user/repo",
  token: "YOUR_GITHUB_TOKEN",
  output_file: "my_prompt.txt",
  branch: "develop",
  exclude: ["*.md", "docs/"], 
  quiet: true # or verbose: true
)
generator.run

# With custom logger
custom_logger = Logger.new("gitingest.log")
generator = Gitingest::Generator.new(
  repository: "user/repo",
  logger: custom_logger
)
generator.run
```

## Features

- Fetches all files from a GitHub repository based on the given branch
- Automatically excludes common binary files and system files by default
- Allows custom exclusion patterns for specific file extensions or directories
- Uses concurrent processing for faster downloads
- Handles GitHub API rate limiting with automatic retry
- Generates a clean, formatted output file with file paths and content

## Default Exclusion Patterns

By default, the generator excludes files and directories commonly ignored in repositories, such as:

- Version control files (`.git/`, `.svn/`)
- System files (`.DS_Store`, `Thumbs.db`)
- Log files (`*.log`, `*.bak`)
- Images and media files (`*.png`, `*.jpg`, `*.mp3`)
- Archives (`*.zip`, `*.tar.gz`)
- Dependency directories (`node_modules/`, `vendor/`)
- Compiled and binary files (`*.pyc`, `*.class`, `*.exe`)

## Limitations

- To prevent memory overload, only the first 1000 files will be processed
- API requests are subject to GitHub limits (60 requests/hour without token, 5000 requests/hour with token)
- Private repositories require a GitHub personal access token

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/davidesantangelo/gitingest.

## Acknowledgements

Inspired by [`cyclotruc/gitingest`](https://github.com/cyclotruc/gitingest).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).