[![Gem Version](https://badge.fury.io/rb/gitingest.svg)](https://badge.fury.io/rb/gitingest)

# Gitingest

Turn any GitHub repo into an LLM-ready prompt.

## Install

```bash
gem install gitingest
```

## Usage

```bash
# Basic
gitingest -r user/repo

# With token (for private repos)
gitingest -r user/repo -t YOUR_TOKEN

# Custom output
gitingest -r user/repo -o prompt.txt

# Show repo structure
gitingest -r user/repo -s
```

### As a Library

```ruby
require "gitingest"

# Basic usage
generator = Gitingest::Generator.new(
  repository: "user/repo",
  token: "YOUR_TOKEN"  # optional
)

# Write to file
generator.run

# Or get content as string
content = generator.generate_prompt
```

#### Full Options

```ruby
require "gitingest"

generator = Gitingest::Generator.new(
  repository: "user/repo",             # Required: GitHub repo (user/repo format)
  token: "YOUR_TOKEN",                 # Optional: GitHub personal access token
  api_endpoint: "https://ghe.example.com/api/v3/",  # Optional: GitHub Enterprise API URL
  output_file: "output.txt",           # Optional: Output file path
  branch: "main",                      # Optional: Branch name (default: repo default)
  exclude: ["*.md", "docs/"],          # Optional: Patterns to exclude
  show_structure: false,               # Optional: Show directory tree only
  threads: 4,                          # Optional: Thread count for fetching
  thread_timeout: 120,                 # Optional: Thread timeout in seconds
  quiet: false,                        # Optional: Reduce logging to errors only
  verbose: true,                       # Optional: Enable debug logging
  logger: Logger.new("gitingest.log")  # Optional: Custom logger instance
)

# Write to file
generator.run

# Get content as string
content = generator.generate_prompt

# Get directory structure
structure = generator.generate_directory_structure
```

## CLI Options

| Flag | Description |
|------|-------------|
| `-r, --repository` | GitHub repo (user/repo) |
| `-t, --token` | GitHub token |
| `-g, --api-endpoint` | GitHub Enterprise API URL |
| `-o, --output` | Output file |
| `-b, --branch` | Branch name |
| `-e, --exclude` | Patterns to exclude |
| `-s, --show-structure` | Show directory tree |
| `-T, --threads` | Thread count |
| `-q, --quiet` | Quiet mode |
| `-v, --verbose` | Verbose mode |

## Limits

- Max 1000 files per repo
- 60 req/hour without token, 5000 with token
- Private repos require a token

## License

MIT

## Credits

Inspired by [cyclotruc/gitingest](https://github.com/cyclotruc/gitingest).
