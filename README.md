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
gitingest --repository username/repo --token YOUR_GITHUB_TOKEN --output output.txt
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
require 'gitingest'

options = {
  repository: 'davidesantangelo/gitingest',
  token: 'your_github_token', # Optional
  output_file: 'output.txt', # Optional
  branch: 'master', # Optional
  exclude: ['node_modules', '.*\.png$'] # Optional
}

generator = Gitingest::Generator.new(options)
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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/davidesantangelo/gitingest.

## Acknowledgements

Inspired by [`cyclotruc/gitingest`](https://github.com/cyclotruc/gitingest).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).