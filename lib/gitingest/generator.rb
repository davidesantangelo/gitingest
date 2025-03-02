# frozen_string_literal: true

require "octokit"
require "base64"
require "fileutils"
require "concurrent"
require "logger"

module Gitingest
  class Generator
    # Default exclusion patterns for common files and directories
    DEFAULT_EXCLUDES = [
      # Version control
      '\.git/', '\.github/', '\.gitignore', '\.gitattributes', '\.gitmodules', '\.svn', '\.hg',

      # System files
      '\.DS_Store', 'Thumbs\.db', 'desktop\.ini',

      # Log files
      '.*\.log$', '.*\.bak$', '.*\.swp$', '.*\.tmp$', '.*\.temp$',

      # Images and media
      '.*\.png$', '.*\.jpg$', '.*\.jpeg$', '.*\.gif$', '.*\.svg$', '.*\.ico$',
      '.*\.pdf$', '.*\.mov$', '.*\.mp4$', '.*\.mp3$', '.*\.wav$',

      # Archives
      '.*\.zip$', '.*\.tar\.gz$',

      # Dependency directories
      "node_modules/", "vendor/", "bower_components/", "\.npm/", "\.yarn/", "\.pnpm-store/",
      "\.bundle/", "vendor/bundle", "packages/", "site-packages/",

      # Virtual environments
      "venv/", "\.venv/", "env/", "\.env", "virtualenv/",

      # IDE and editor files
      "\.idea/", "\.vscode/", "\.vs/", "\.settings/", ".*\.sublime-.*",
      "\.project", "\.classpath", "xcuserdata/", ".*\.xcodeproj/", ".*\.xcworkspace/",

      # Lock files
      "package-lock\.json", "yarn\.lock", "poetry\.lock", "Pipfile\.lock",
      "Gemfile\.lock", "Cargo\.lock", "bun\.lock", "bun\.lockb",

      # Build directories and artifacts
      "build/", "dist/", "target/", "out/", "\.gradle/", "\.settings/",
      ".*\.egg-info", ".*\.egg", ".*\.whl", ".*\.so", "bin/", "obj/", "pkg/",

      # Cache directories
      "\.cache/", "\.sass-cache/", "\.eslintcache/", "\.pytest_cache/",
      "\.coverage", "\.tox/", "\.nox/", "\.mypy_cache/", "\.ruff_cache/",
      "\.hypothesis/", "\.terraform/", "\.docusaurus/", "\.next/", "\.nuxt/",

      # Compiled code
      ".*\.pyc$", ".*\.pyo$", ".*\.pyd$", "__pycache__/", ".*\.class$",
      ".*\.jar$", ".*\.war$", ".*\.ear$", ".*\.nar$",
      ".*\.o$", ".*\.obj$", ".*\.dll$", ".*\.dylib$", ".*\.exe$",
      ".*\.lib$", ".*\.out$", ".*\.a$", ".*\.pdb$", ".*\.nupkg$",

      # Language specific files
      ".*\.min\.js$", ".*\.min\.css$", ".*\.map$", ".*\.tfstate.*",
      ".*\.gem$", ".*\.ruby-version", ".*\.ruby-gemset", ".*\.rvmrc",
      ".*\.rs\.bk$", ".*\.gradle", ".*\.suo", ".*\.user", ".*\.userosscache",
      ".*\.sln\.docstates", "gradle-app\.setting",
      ".*\.pbxuser", ".*\.mode1v3", ".*\.mode2v3", ".*\.perspectivev3", ".*\.xcuserstate",
      "\.swiftpm/", "\.build/"
    ].freeze

    # Maximum number of files to process to prevent memory overload
    MAX_FILES = 1000
    BUFFER_SIZE = 100 # Write every 100 files to reduce I/O operations

    attr_reader :options, :client, :repo_files, :excluded_patterns, :logger

    # Initialize a new Generator with the given options
    #
    # @param options [Hash] Configuration options
    # @option options [String] :repository GitHub repository in format "username/repo"
    # @option options [String] :token GitHub personal access token
    # @option options [String] :branch Repository branch (default: "main")
    # @option options [String] :output_file Output file path
    # @option options [Array<String>] :exclude Additional patterns to exclude
    # @option options [Boolean] :quiet Reduce logging to errors only
    # @option options [Boolean] :verbose Increase logging verbosity
    # @option options [Logger] :logger Custom logger instance
    def initialize(options = {})
      @options = options
      @repo_files = []
      @excluded_patterns = []
      setup_logger
      validate_options
      configure_client
      compile_excluded_patterns
    end

    # Main execution method
    def run
      fetch_repository_contents
      generate_prompt
    end

    private

    # Set up logging based on verbosity options
    def setup_logger
      @logger = @options[:logger] || Logger.new($stdout)
      @logger.level = if @options[:quiet]
                        Logger::ERROR
                      elsif @options[:verbose]
                        Logger::DEBUG
                      else
                        Logger::INFO
                      end
      # Simplify logger format for command line usage
      @logger.formatter = proc { |severity, _, _, msg| "#{severity == "INFO" ? "" : "[#{severity}] "}#{msg}\n" }
    end

    # Validate and set default options
    def validate_options
      raise ArgumentError, "Repository is required" unless @options[:repository]

      @options[:output_file] ||= "#{@options[:repository].split("/").last}_prompt.txt"
      @options[:branch] ||= "main"
      @options[:exclude] ||= []
      @excluded_patterns = DEFAULT_EXCLUDES + @options[:exclude]
    end

    # Configure the GitHub API client
    def configure_client
      @client = @options[:token] ? Octokit::Client.new(access_token: @options[:token]) : Octokit::Client.new

      if @options[:token]
        @logger.info "Using provided GitHub token for authentication"
      else
        @logger.warn "Warning: No token provided. API rate limits will be restricted and private repositories will be inaccessible."
        @logger.warn "For better results, provide a GitHub token with the --token option."
      end
    end

    # Convert exclusion patterns to regular expressions
    def compile_excluded_patterns
      @excluded_patterns = @excluded_patterns.map { |pattern| Regexp.new(pattern) }
    end

    # Fetch repository contents and apply exclusion filters
    def fetch_repository_contents
      @logger.info "Fetching repository: #{@options[:repository]} (branch: #{@options[:branch]})"
      begin
        validate_repository_access
        repo_tree = @client.tree(@options[:repository], @options[:branch], recursive: true)
        @repo_files = repo_tree.tree.select { |item| item.type == "blob" && !excluded_file?(item.path) }

        if @repo_files.size > MAX_FILES
          @logger.warn "Warning: Found #{@repo_files.size} files, limited to #{MAX_FILES}."
          @repo_files = @repo_files.first(MAX_FILES)
        end
        @logger.info "Found #{@repo_files.size} files after exclusion filters"
      rescue Octokit::Unauthorized
        raise "Authentication error: Invalid or expired GitHub token. Please provide a valid token."
      rescue Octokit::NotFound
        raise "Repository not found: '#{@options[:repository]}' or branch '#{@options[:branch]}' doesn't exist or is private."
      rescue Octokit::Error => e
        raise "Error accessing repository: #{e.message}"
      end
    end

    # Validate repository and branch access
    def validate_repository_access
      begin
        @client.repository(@options[:repository])
      rescue Octokit::Unauthorized
        raise "Authentication error: Invalid or expired GitHub token"
      rescue Octokit::NotFound
        raise "Repository '#{@options[:repository]}' not found or is private. Check the repository name or provide a valid token."
      end

      begin
        @client.branch(@options[:repository], @options[:branch])
      rescue Octokit::NotFound
        raise "Branch '#{@options[:branch]}' not found in repository '#{@options[:repository]}'"
      end
    end

    # Check if a file should be excluded based on its path
    def excluded_file?(path)
      return true if path.start_with?(".") || path.split("/").any? { |part| part.start_with?(".") }

      @excluded_patterns.any? { |pattern| path.match?(pattern) }
    end

    # Generate the consolidated prompt file
    def generate_prompt
      @logger.info "Generating prompt..."
      buffer = []
      progress = ProgressIndicator.new(@repo_files.size, @logger)

      # Dynamic thread pool based on core count
      pool = Concurrent::FixedThreadPool.new([Concurrent.processor_count, 5].min)

      File.open(@options[:output_file], "w") do |file|
        @repo_files.each_with_index do |repo_file, index|
          pool.post do
            content = fetch_file_content_with_retry(repo_file.path)
            result = format_file_content(repo_file.path, content)

            # Thread-safe buffer management
            buffer_mutex.synchronize do
              buffer << result
              write_buffer(file, buffer) if buffer.size >= BUFFER_SIZE
            end

            progress.update(index + 1)
          rescue Octokit::Error => e
            @logger.error "Error fetching #{repo_file.path}: #{e.message}"
          end
        end

        pool.shutdown
        pool.wait_for_termination

        # Write any remaining files in buffer
        buffer_mutex.synchronize do
          write_buffer(file, buffer) unless buffer.empty?
        end
      end

      @logger.info "Prompt generated and saved to #{@options[:output_file]}"
    end

    # Format a file's content for the prompt
    def format_file_content(path, content)
      <<~TEXT
        ================================================================
        File: #{path}
        ================================================================
        #{content}

      TEXT
    end

    # Fetch file content with retry logic for rate limiting
    def fetch_file_content_with_retry(path, retries = 3)
      content = @client.contents(@options[:repository], path: path, ref: @options[:branch])
      Base64.decode64(content.content)
    rescue Octokit::TooManyRequests
      raise unless retries.positive?

      sleep_time = 60 / retries
      @logger.warn "Rate limit exceeded, waiting #{sleep_time} seconds..."
      sleep(sleep_time)
      fetch_file_content_with_retry(path, retries - 1)
    end

    # Write buffer contents to file and clear buffer
    def write_buffer(file, buffer)
      file.puts(buffer.join)
      buffer.clear
    end

    # Thread-safe mutex for buffer operations
    def buffer_mutex
      @buffer_mutex ||= Mutex.new
    end
  end

  # Helper class for showing progress in CLI
  class ProgressIndicator
    def initialize(total, logger)
      @total = total
      @logger = logger
      @last_percent = 0
    end

    def update(current)
      percent = (current.to_f / @total * 100).round
      return unless percent > @last_percent && ((percent % 5).zero? || current == @total)

      @logger.info "Processing: #{percent}% complete (#{current}/#{@total} files)"
      @last_percent = percent
    end
  end
end
