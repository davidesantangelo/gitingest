# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2025-03-02
- Added `faraday-retry` gem dependency for better API rate limit handling
- Implemented thread-safe buffer management with mutex locks
- Added new `ProgressIndicator` class for better CLI progress reporting (showing percentages)
- Improved memory efficiency with configurable buffer size
- Enhanced code organization with dedicated methods for file content formatting
- Added comprehensive method documentation and parameter descriptions
- Optimized thread pool size calculation for better performance
- Improved error handling in concurrent operations

## [0.2.0] - 2025-03-02
- Added support for quiet and verbose modes in the command-line interface
- Added the ability to specify a custom output file for the prompt
- Enhanced error handling with logging support
- Added logging functionality with custom loggers
- Introduced rate limit handling with retries for file fetching
- Added repository branch support
- Exclude specific file patterns via command-line arguments
- Enforced a 1000 file limit to prevent memory overload
- Updated version to 0.2.0

## [0.1.0] - 2025-03-02

### Added
- Initial release of Gitingest
- Core functionality to fetch and process GitHub repository files
- Command-line interface for easy interaction
- Smart file filtering with default exclusions for common non-code files
- Concurrent processing for improved performance
- Custom exclude patterns support
- GitHub authentication via access tokens
- Automatic rate limit handling with retry mechanism
- Repository prompt generation with file separation markers
- Support for custom branch selection
- Custom output file naming options