# Changelog

## [0.7.0] - 2025-06-04

### Changed
- Improved file exclusion logic for glob patterns to correctly match files at any directory depth (e.g., `*.md` now correctly matches `docs/file.md`).
- Refined internal handling of exclusion patterns for clarity and robustness, using `File.fnmatch` for all custom glob patterns.
- Enhanced debug logging for file exclusion to show the specific pattern that caused a match.

## [0.6.3] - 2025-04-14

### Fixed
- Fixed directory exclusion pattern to properly handle paths ending with slash

## [0.6.2] - 2025-04-11

### Changed
- Updated Octokit dependency from ~> 5.0 to ~> 9.0
- Updated various gem dependencies to their latest versions

## [0.6.1] - 2025-03-26

### Fixed
- Fixed error "target of repeat operator is not specified" when using `--exclude` with glob patterns like `*.md`

## [0.6.0] - 2025-03-18

### Changed
- Improved default branch handling to use repository's actual default branch instead of hardcoding "main"
- Enhanced error handling in repository access validation
- Updated documentation to reflect the correct default branch behavior
- Fixed issues with repository validation in tests

## [0.5.0] - 2025-03-10

### Added
- Added repository directory structure visualization with `--show-structure` / `-s` option
- Created `DirectoryStructureBuilder` class to generate tree views of repositories
- Added `generate_directory_structure` method to the Generator class
- Added tests for directory structure visualization

### Changed
- Enhanced documentation with directory structure visualization examples
- Updated CLI help with the new option

## [0.4.0] - 2025-03-03

### Added
- Added `generate_prompt` method for in-memory content generation without file I/O
- Integrated visual progress bar with file processing rate reporting
- Added human-readable time formatting for progress estimates
- Enhanced test coverage for multithreaded operations

### Changed
- Refactored `process_content_to_output` for better code reuse between file and string output
- Improved thread management to handle various error conditions more gracefully
- Enhanced documentation with programmatic usage examples

### Fixed
- Resolved thread pool shutdown issues in test environment
- Fixed race conditions in progress indicator updates
- Addressed timing inconsistencies in multithreaded test scenarios

## [0.3.1] - 2025-03-03

### Added
- Introduced configurable threading options:
  - `:threads` to specify the number of threads (default: auto-detected).
  - `:thread_timeout` to define thread pool shutdown timeout (default: 60 seconds).
- Implemented thread-local buffers to reduce mutex contention during file processing.
- Added exponential backoff with jitter for rate-limited API requests.
- Improved progress indicator with a visual progress bar and estimated time remaining.

### Changed
- Increased `BUFFER_SIZE` from 100 to 250 to reduce I/O operations.
- Optimized file exclusion check using a combined regex for faster matching.
- Improved thread pool efficiency by prioritizing smaller files first.
- Enhanced error handling with detailed logging and thread-safe error collection.

### Fixed
- Ensured thread pool shutdown respects the configured timeout.
- Resolved potential race conditions in file content retrieval.

## [0.3.0] - 2025-03-02

### Added
- Added `faraday-retry` gem dependency for better API rate limit handling.
- Implemented thread-safe buffer management with mutex locks.
- Introduced `ProgressIndicator` class for enhanced CLI progress reporting, including percentages.
- Improved memory efficiency with a configurable buffer size.
- Enhanced code organization by introducing dedicated methods for file content formatting.
- Added comprehensive method documentation and parameter descriptions.
- Optimized thread pool size calculation for improved performance.
- Improved error handling in concurrent operations.

## [0.2.0] - 2025-03-02

### Added
- Introduced support for quiet and verbose modes in the command-line interface.
- Added the ability to specify a custom output file for the prompt.
- Implemented enhanced error handling with logging support.
- Introduced logging functionality with customizable loggers.
- Added rate limit handling with retries for file fetching.
- Implemented repository branch support.
- Enabled exclusion of specific file patterns via command-line arguments.
- Enforced a 1000-file limit to prevent memory overload.
- Updated version to `0.2.0`.

## [0.1.0] - 2025-03-02

### Added
- Initial release of Gitingest.
- Core functionality to fetch and process GitHub repository files.
- Command-line interface for easy interaction.
- Smart file filtering with default exclusions for common non-code files.
- Concurrent processing for improved performance.
- Custom exclude patterns support.
- GitHub authentication via access tokens.
- Automatic rate limit handling with a retry mechanism.
- Repository prompt generation with file separation markers.
- Support for custom branch selection.
- Custom output file naming options.