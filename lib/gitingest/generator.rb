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

    # Optimization: pattern for dot files/directories
    DOT_FILE_PATTERN = %r{(?-mix:(^\.|/\.))}

    # Maximum number of files to process to prevent memory overload
    MAX_FILES = 1000

    # Optimization: increased buffer size to reduce I/O operations
    BUFFER_SIZE = 250

    # Optimization: thread-local buffer threshold
    LOCAL_BUFFER_THRESHOLD = 50

    # Add configurable threading options
    DEFAULT_THREAD_COUNT = [Concurrent.processor_count, 8].min
    DEFAULT_THREAD_TIMEOUT = 60 # seconds

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
    # @option options [Integer] :threads Number of threads to use (default: auto-detected)
    # @option options [Integer] :thread_timeout Seconds to wait for thread pool shutdown (default: 60)
    # @option options [Boolean] :show_structure Show repository directory structure (default: false)
    # @option options [String] :api_endpoint GitHub Enterprise API endpoint URL (e.g., "https://github.example.com/api/v3/")
    def initialize(options = {})
      @options = options
      @repo_files = []
      @excluded_patterns = []
      setup_logger
      validate_options
      configure_client
      compile_excluded_patterns
    end

    # Main execution method for command line
    def run
      fetch_repository_contents

      if @options[:show_structure]
        puts generate_directory_structure
        return
      end

      generate_file
    end

    # Generate content and save it to a file
    #
    # @return [String] Path to the generated file
    def generate_file
      fetch_repository_contents if @repo_files.empty?

      @logger.info "Generating file for #{@options[:repository]}"
      File.open(@options[:output_file], "w") do |file|
        process_content_to_output(file)
      end

      @logger.info "Prompt generated and saved to #{@options[:output_file]}"
      @options[:output_file]
    end

    # Generate content and return it as a string
    # Useful for programmatic usage
    #
    # @return [String] The generated repository content
    def generate_prompt
      @logger.info "Generating in-memory prompt for #{@options[:repository]}"

      fetch_repository_contents if @repo_files.empty?

      content = StringIO.new
      process_content_to_output(content)

      result = content.string
      @logger.info "Generated #{result.size} bytes of content in memory"
      result
    end

    # Generate a textual representation of the repository's directory structure
    #
    # @return [String] The directory structure as a formatted string
    def generate_directory_structure
      fetch_repository_contents if @repo_files.empty?

      @logger.info "Generating directory structure for #{@options[:repository]}"

      repo_name = @options[:repository].split("/").last
      structure = DirectoryStructureBuilder.new(repo_name, @repo_files).build

      @logger.info "\n"
      structure
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
      @options[:branch] ||= :default
      @options[:exclude] ||= []
      @options[:threads] ||= DEFAULT_THREAD_COUNT
      @options[:thread_timeout] ||= DEFAULT_THREAD_TIMEOUT
      @options[:show_structure] ||= false
      @excluded_patterns = DEFAULT_EXCLUDES + @options[:exclude]
      # No default for api_endpoint as it's optional
    end

    # Configure the GitHub API client
    def configure_client
      configure_api_endpoint if @options[:api_endpoint]

      create_client

      log_authentication_details
    end

    # Configure Octokit to use GitHub Enterprise API endpoint
    def configure_api_endpoint
      endpoint = @options[:api_endpoint]

      # Validate that the endpoint is a proper URL
      unless valid_api_endpoint?(endpoint)
        raise ArgumentError, "Invalid API endpoint URL: #{endpoint}. Must be a valid URL with HTTPS protocol."
      end

      Octokit.configure do |c|
        c.api_endpoint = endpoint
      end
      @logger.info "Using GitHub Enterprise API endpoint: #{endpoint}"
    end

    # Validate if the provided API endpoint is a proper URL
    def valid_api_endpoint?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && uri.scheme == 'https' && !uri.host.nil?
    rescue URI::InvalidURIError
      false
    end

    # Create Octokit client with or without authentication
    def create_client
      @client = if @options[:token]
                  Octokit::Client.new(access_token: @options[:token])
                else
                  Octokit::Client.new
                end
    end

    # Log authentication status
    def log_authentication_details
      if @options[:token]
        @logger.info "Using provided GitHub token for authentication"
      else
        @logger.warn "Warning: No token provided. API rate limits will be restricted and private repositories will be inaccessible."
        @logger.warn "For better results, provide a GitHub token with the --token option."
      end
    end

    # Optimization: Create a combined regex for faster exclusion checking
    def compile_excluded_patterns
      patterns = @excluded_patterns.map { |pattern| "(#{pattern})" }
      @combined_exclude_regex = Regexp.new("#{DOT_FILE_PATTERN.source}|#{patterns.join("|")}")
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
        repo = @client.repository(@options[:repository])
        @options[:branch] = repo.default_branch if @options[:branch] == :default
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

    # Optimization: Optimized file exclusion check with combined regex
    def excluded_file?(path)
      path.match?(@combined_exclude_regex)
    end

    # Common implementation for both file and string output
    def process_content_to_output(output)
      @logger.debug "Using thread pool with #{@options[:threads]} threads"

      buffer = []
      progress = ProgressIndicator.new(@repo_files.size, @logger)

      # Thread-local buffers to reduce mutex contention
      thread_buffers = {}
      mutex = Mutex.new
      errors = []

      # Thread pool based on configuration
      pool = Concurrent::FixedThreadPool.new(@options[:threads])

      # Group files by priority
      prioritized_files = prioritize_files(@repo_files)

      prioritized_files.each_with_index do |repo_file, index|
        pool.post do
          thread_id = Thread.current.object_id
          thread_buffers[thread_id] ||= []
          local_buffer = thread_buffers[thread_id]

          begin
            content = fetch_file_content_with_retry(repo_file.path)
            result = format_file_content(repo_file.path, content)
            local_buffer << result

            if local_buffer.size >= LOCAL_BUFFER_THRESHOLD
              mutex.synchronize do
                buffer.concat(local_buffer)
                write_buffer(output, buffer) if buffer.size >= BUFFER_SIZE
                local_buffer.clear
              end
            end

            progress.update(index + 1)
          rescue Octokit::Error => e
            mutex.synchronize do
              errors << "Error fetching #{repo_file.path}: #{e.message}"
              @logger.error "Error fetching #{repo_file.path}: #{e.message}"
            end
          rescue StandardError => e
            mutex.synchronize do
              errors << "Unexpected error processing #{repo_file.path}: #{e.message}"
              @logger.error "Unexpected error processing #{repo_file.path}: #{e.message}"
            end
          end
        end
      end

      begin
        pool.shutdown
        wait_success = pool.wait_for_termination(@options[:thread_timeout])

        unless wait_success
          @logger.warn "Thread pool did not shut down within #{@options[:thread_timeout]} seconds, forcing termination"
          pool.kill
        end
      rescue StandardError => e
        @logger.error "Error during thread pool shutdown: #{e.message}"
      end

      # Process remaining files in thread-local buffers
      mutex.synchronize do
        thread_buffers.each_value do |local_buffer|
          buffer.concat(local_buffer) unless local_buffer.empty?
        end
        write_buffer(output, buffer) unless buffer.empty?
      end

      return unless errors.any?

      @logger.warn "Completed with #{errors.size} errors"
      @logger.debug "First few errors: #{errors.first(3).join(", ")}" if @logger.debug?
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

    # Optimization: Fetch file content with exponential backoff for rate limiting
    def fetch_file_content_with_retry(path, retries = 3, base_delay = 2)
      content = @client.contents(@options[:repository], path: path, ref: @options[:branch])
      Base64.decode64(content.content)
    rescue Octokit::TooManyRequests
      raise unless retries.positive?

      # Optimization: Exponential backoff with jitter for better rate limit handling
      delay = base_delay**(4 - retries) * (0.8 + 0.4 * rand)
      @logger.warn "Rate limit exceeded, waiting #{delay.round(1)} seconds..."
      sleep(delay)
      fetch_file_content_with_retry(path, retries - 1, base_delay)
    end

    # Write buffer contents to file and clear buffer
    def write_buffer(file, buffer)
      return if buffer.empty?

      file.puts(buffer.join)
      buffer.clear
    end

    # Sort files by estimated processing priority
    def prioritize_files(files)
      # Sort files by estimated size (based on extension)
      # This helps with better thread distribution - process small files first
      files.sort_by do |file|
        path = file.path.downcase
        if path.end_with?(".md", ".txt", ".json", ".yaml", ".yml")
          0  # Process documentation and config files first (usually small)
        elsif path.end_with?(".rb", ".py", ".js", ".ts", ".go", ".java", ".c", ".cpp", ".h")
          1  # Then process code files (medium size)
        else
          2  # Other files last
        end
      end
    end
  end

  # Helper class for showing progress in CLI with visual bar
  class ProgressIndicator
    BAR_WIDTH = 30 # Width of the progress bar

    def initialize(total, logger)
      @total = total
      @logger = logger
      @last_percent = 0
      @start_time = Time.now
      @last_update_time = Time.now
      @update_interval = 0.5 # Limit updates to twice per second
    end

    # Update progress with visual bar
    def update(current)
      # Avoid updating too frequently
      now = Time.now
      return if now - @last_update_time < @update_interval && current != @total

      @last_update_time = now
      percent = (current.to_f / @total * 100).round

      # Only update at meaningful increments or completion
      return unless percent > @last_percent || current == @total

      elapsed = now - @start_time

      # Generate progress bar
      progress_chars = (BAR_WIDTH * (current.to_f / @total)).round
      bar = "[#{"|" * progress_chars}#{" " * (BAR_WIDTH - progress_chars)}]"

      # Calculate ETA
      eta_string = ""
      if current > 1 && percent < 100
        remaining = (elapsed / current) * (@total - current)
        eta_string = " ETA: #{format_time(remaining)}"
      end

      # Calculate rate (files per second)
      rate = begin
        current / elapsed
      rescue StandardError
        0
      end
      rate_string = " (#{rate.round(1)} files/sec)"

      # Clear line and print progress bar
      print "\r\e[K" # Clear the line
      print "#{bar} #{percent}% | #{current}/#{@total} files#{rate_string}#{eta_string}"
      print "\n" if current == @total # Add newline when complete

      # Also log to logger at less frequent intervals
      if (percent % 10).zero? && percent != @last_percent || current == @total
        @logger.info "Processing: #{percent}% complete (#{current}/#{@total} files)#{eta_string}"
      end

      @last_percent = percent
    end

    private

    # Format seconds into a human-readable time string
    def format_time(seconds)
      return "< 1s" if seconds < 1

      case seconds
      when 0...60
        "#{seconds.round}s"
      when 60...3600
        minutes = (seconds / 60).floor
        secs = (seconds % 60).round
        "#{minutes}m #{secs}s"
      else
        hours = (seconds / 3600).floor
        minutes = ((seconds % 3600) / 60).floor
        "#{hours}h #{minutes}m"
      end
    end
  end

  # Helper class to build directory structure visualization
  class DirectoryStructureBuilder
    def initialize(root_name, files)
      @root_name = root_name
      @files = files.map(&:path)
    end

    def build
      tree = { @root_name => {} }

      @files.sort.each do |path|
        parts = path.split("/")
        current = tree[@root_name]

        parts.each do |part|
          if part == parts.last
            current[part] = nil
          else
            current[part] ||= {}
            current = current[part]
          end
        end
      end

      output = ["Directory structure:"]
      render_tree(tree, "", output)
      output.join("\n")
    end

    private

    def render_tree(tree, prefix, output)
      return if tree.nil?

      tree.keys.each_with_index do |key, index|
        is_last = index == tree.keys.size - 1
        current_prefix = prefix

        if prefix.empty?
          output << "└── #{key}/"
          current_prefix = "    "
        else
          connector = is_last ? "└── " : "├── "
          item = tree[key].is_a?(Hash) ? "#{key}/" : key
          output << "#{prefix}#{connector}#{item}"
          current_prefix = prefix + (is_last ? "    " : "│   ")
        end

        render_tree(tree[key], current_prefix, output) if tree[key].is_a?(Hash)
      end
    end
  end
end
