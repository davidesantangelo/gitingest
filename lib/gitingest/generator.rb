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

      # Language-specific files
      ".*\.min\.js$", ".*\.min\.css$", ".*\.map$", ".*\.tfstate.*",
      ".*\.gem$", ".*\.ruby-version", ".*\.ruby-gemset", ".*\.rvmrc",
      ".*\.rs\.bk$", ".*\.gradle", ".*\.suo", ".*\.user", ".*\.userosscache",
      ".*\.sln\.docstates", "gradle-app\.setting",
      ".*\.pbxuser", ".*\.mode1v3", ".*\.mode2v3", ".*\.perspectivev3", ".*\.xcuserstate",
      "\.swiftpm/", "\.build/"
    ].freeze

    # Pattern for dot files/directories
    DOT_FILE_PATTERN = %r{(?-mix:(^\.|/\.))}

    # Maximum number of files to process to prevent memory overload
    MAX_FILES = 1000

    # Buffer size to reduce I/O operations
    BUFFER_SIZE = 250

    # Thread-local buffer threshold
    LOCAL_BUFFER_THRESHOLD = 50

    # Default threading options
    DEFAULT_THREAD_COUNT = [Concurrent.processor_count, 8].min
    DEFAULT_THREAD_TIMEOUT = 60 # seconds

    attr_reader :options, :client, :repo_files, :excluded_patterns, :logger

    def initialize(options = {})
      @options = options
      @repo_files = []
      @excluded_patterns = []
      setup_logger
      validate_options
      configure_client
      compile_excluded_patterns
    end

    def run
      fetch_repository_contents
      if @options[:show_structure]
        puts generate_directory_structure
        return
      end
      generate_file
    end

    def generate_file
      fetch_repository_contents if @repo_files.empty?
      @logger.info "Generating file for #{@options[:repository]}"
      File.open(@options[:output_file], "w") do |file|
        process_content_to_output(file)
      end
      @logger.info "Prompt generated and saved to #{@options[:output_file]}"
      @options[:output_file]
    end

    def generate_prompt
      @logger.info "Generating in-memory prompt for #{@options[:repository]}"
      fetch_repository_contents if @repo_files.empty?
      content = StringIO.new
      process_content_to_output(content)
      result = content.string
      @logger.info "Generated #{result.size} bytes of content in memory"
      result
    end

    def generate_directory_structure
      fetch_repository_contents if @repo_files.empty?
      @logger.info "Generating directory structure for #{@options[:repository]}"
      repo_name = @options[:repository].split("/").last
      structure = DirectoryStructureBuilder.new(repo_name, @repo_files).build
      @logger.info "\n"
      structure
    end

    private

    def setup_logger
      @logger = @options[:logger] || Logger.new($stdout)
      @logger.level = if @options[:quiet]
                        Logger::ERROR
                      elsif @options[:verbose]
                        Logger::DEBUG
                      else
                        Logger::INFO
                      end
      @logger.formatter = proc { |severity, _, _, msg| "#{severity == "INFO" ? "" : "[#{severity}] "}#{msg}\n" }
    end

    def validate_options
      raise ArgumentError, "Repository is required" unless @options[:repository]

      @options[:output_file] ||= "#{@options[:repository].split("/").last}_prompt.txt"
      @options[:branch] ||= :default
      @options[:exclude] ||= []
      @options[:threads] ||= DEFAULT_THREAD_COUNT
      @options[:thread_timeout] ||= DEFAULT_THREAD_TIMEOUT
      @options[:show_structure] ||= false
      @excluded_patterns = DEFAULT_EXCLUDES + @options[:exclude]
    end

    def configure_client
      @client = @options[:token] ? Octokit::Client.new(access_token: @options[:token]) : Octokit::Client.new
      if @options[:token]
        @logger.info "Using provided GitHub token for authentication"
      else
        @logger.warn "Warning: No token provided. API rate limits will be restricted and private repositories will be inaccessible."
        @logger.warn "For better results, provide a GitHub token with the --token option."
      end
    end

    def compile_excluded_patterns
      @default_patterns = DEFAULT_EXCLUDES.map { |pattern| Regexp.new(pattern) }
      @custom_patterns = []
      @glob_patterns_with_char_classes = []

      @options[:exclude].each do |glob_pattern|
        if glob_pattern.include?("[") && glob_pattern.include?("]")
          @glob_patterns_with_char_classes << glob_pattern
        else
          @custom_patterns << Regexp.new(glob_to_regex(glob_pattern))
        end
      end
    end

    # Builds a single regex from the combined default and custom exclusion patterns.
    # Handles glob patterns and directory patterns (ending with /).
    #
    # @return [Regexp] The combined exclusion regex.
    def build_exclusion_regex
      combined_patterns = DEFAULT_EXCLUDES + @options.fetch(:exclude, [])
      regex_parts = combined_patterns.map do |pattern|
        if pattern.end_with?("/")
          # Directory pattern: Match anything starting with this path
          "^#{Regexp.escape(pattern)}"
        else
          # File or glob pattern: Convert glob to regex
          glob_to_regex(pattern)
        end
      end
      # Combine all parts, ensuring they match the full path or directory prefix
      Regexp.new(regex_parts.join("|"))
    end

    # Converts a glob pattern to a Regexp string.
    # Handles *, **, ?, and character classes.
    # Ensures the pattern matches the entire string by default.
    #
    # @param glob [String] The glob pattern.
    # @return [String] The regex pattern string.
    def glob_to_regex(glob)
      # More robust glob conversion
      regex = glob.gsub(%r{/\*\*($|/)}, '/.*\\1') # Handle **/ and ** at end
                  .gsub("*", "[^/]*")          # Match * within path segments
                  .gsub("?", "[^/]")           # Match ? within path segments
                  .gsub(".", '\\.')            # Escape dots
                  .gsub("{", "(")              # Convert { to ( for grouping
                  .gsub("}", ")")              # Convert } to ) for grouping
                  .gsub(",", "|")              # Convert , to | for OR within groups

      # Ensure the pattern matches the full path unless it was originally a directory pattern
      # (which is handled separately now) or contains wildcards suggesting partial match.
      # If it contains no wildcards, anchor it.
      if glob.include?("*") || glob.include?("?") || glob.include?("{")
        regex # Allow partial matching for wildcards
      else
        "^#{regex}$" # Anchor exact matches
      end
    end

    def fetch_repository_contents
      @logger.info "Fetching repository: #{@options[:repository]} (branch: #{@options[:branch]})"
      validate_repository_access
      repo_tree = @client.tree(@options[:repository], @options[:branch], recursive: true)
      @repo_files = repo_tree.tree.select { |item| item.type == "blob" && !excluded_file?(item.path) }
      if @repo_files.size > MAX_FILES
        @logger.warn "Warning: Found #{@repo_files.size} files, limited to #{MAX_FILES}."
        @repo_files = @repo_files.first(MAX_FILES)
      end
      @logger.info "Found #{@repo_files.size} files after exclusion filters"
    rescue Octokit::Unauthorized
      raise "Authentication error: Invalid or expired GitHub token."
    rescue Octokit::NotFound
      raise "Repository not found: '#{@options[:repository]}' or branch '#{@options[:branch]}' doesn't exist or is private."
    rescue Octokit::Error => e
      raise "Error accessing repository: #{e.message}"
    end

    # Validate repository and branch access
    def validate_repository_access
      repo = @client.repository(@options[:repository])
      @options[:branch] = repo.default_branch if @options[:branch] == :default

      # If repository check succeeds, store this fact before trying branch
      @repository_exists = true

      begin
        @client.branch(@options[:repository], @options[:branch])
      rescue Octokit::NotFound
        # If we got here, the repository exists but the branch doesn't
        raise "Branch '#{@options[:branch]}' not found in repository '#{@options[:repository]}'"
      end
    rescue Octokit::Unauthorized
      raise "Authentication error: Invalid or expired GitHub token"
    rescue Octokit::NotFound
      # Only reach this for repository not found (branch errors handled separately)
      raise "Repository '#{@options[:repository]}' not found or is private. Check the repository name or provide a valid token."
    end

    def excluded_file?(path)
      return true if path.match?(DOT_FILE_PATTERN)

      # Check for directory exclusion patterns (ending with '/')
      @options[:exclude].each do |pattern|
        if pattern.end_with?("/") && path.start_with?(pattern)
          @logger.debug "Excluding #{path} (matched directory pattern #{pattern})" if @logger.debug?
          return true
        end
      end

      # Continue with regular pattern checks
      return true if @default_patterns.any? { |pattern| path.match?(pattern) }
      return true if @custom_patterns.any? { |pattern| path.match?(pattern) }

      @glob_patterns_with_char_classes.any? { |glob_pattern| glob_match?(glob_pattern, path) }
    end

    def glob_match?(pattern, string)
      return true if pattern == string
      return false if !pattern.match?(/[*?\[]/) && pattern != string

      pattern_idx = 0
      string_idx = 0

      while pattern_idx < pattern.length && string_idx < string.length
        case pattern[pattern_idx]
        when "*"
          pattern_idx += 1 while pattern_idx + 1 < pattern.length && pattern[pattern_idx + 1] == "*"
          return true if pattern_idx == pattern.length - 1

          next_char = pattern[pattern_idx + 1]
          pattern_idx += 1
          while string_idx < string.length
            break if string[string_idx] == next_char || next_char == "?" ||
                     (next_char == "[" && char_class_match?(pattern, pattern_idx, string[string_idx]))

            string_idx += 1
          end
        when "?" then string_idx += 1
                      pattern_idx += 1
        when "["
          return false unless char_class_match?(pattern, pattern_idx, string[string_idx])

          pattern_idx += 1
          pattern_idx += 1 while pattern_idx < pattern.length && pattern[pattern_idx] != "]"
          pattern_idx += 1
          string_idx += 1
        when string[string_idx] then string_idx += 1
                                     pattern_idx += 1
        else return false
        end
      end

      pattern_idx += 1 while pattern_idx < pattern.length && pattern[pattern_idx] == "*"
      pattern_idx == pattern.length && string_idx == string.length
    end

    def char_class_match?(pattern, class_start_idx, char)
      idx = class_start_idx + 1
      match = false
      negate = pattern[idx] == "^" && (idx += 1)

      while idx < pattern.length && pattern[idx] != "]"
        if idx + 2 < pattern.length && pattern[idx + 1] == "-"
          range_start = pattern[idx]
          range_end = pattern[idx + 2]
          match = true if char >= range_start && char <= range_end
          idx += 3
        else
          match = true if pattern[idx] == char
          idx += 1
        end
        break if match
      end
      negate ? !match : match
    end

    def process_content_to_output(output)
      @logger.debug "Using thread pool with #{@options[:threads]} threads"
      buffer = []
      progress = ProgressIndicator.new(@repo_files.size, @logger)
      thread_buffers = {}
      mutex = Mutex.new
      errors = []
      pool = Concurrent::FixedThreadPool.new(@options[:threads])
      prioritized_files = prioritize_files(@repo_files)

      prioritized_files.each_with_index do |repo_file, index|
        pool.post do
          thread_id = Thread.current.object_id
          thread_buffers[thread_id] ||= []
          local_buffer = thread_buffers[thread_id]
          begin
            content = fetch_file_content_with_retry(repo_file.path)
            local_buffer << format_file_content(repo_file.path, content)
            if local_buffer.size >= LOCAL_BUFFER_THRESHOLD
              mutex.synchronize do
                buffer.concat(local_buffer)
                write_buffer(output, buffer) if buffer.size >= BUFFER_SIZE
                local_buffer.clear
              end
            end
            progress.update(index + 1)
          rescue Octokit::Error => e
            mutex.synchronize { errors << "Error fetching #{repo_file.path}: #{e.message}" }
            @logger.error "Error fetching #{repo_file.path}: #{e.message}"
          rescue StandardError => e
            mutex.synchronize { errors << "Unexpected error processing #{repo_file.path}: #{e.message}" }
            @logger.error "Unexpected error processing #{repo_file.path}: #{e.message}"
          end
        end
      end

      pool.shutdown
      pool.wait_for_termination(@options[:thread_timeout]) || (@logger.warn "Thread pool timeout, forcing termination"

                                                               pool.kill)

      mutex.synchronize do
        thread_buffers.each_value { |local_buffer| buffer.concat(local_buffer) unless local_buffer.empty? }
        write_buffer(output, buffer) unless buffer.empty?
      end

      return unless errors.any?

      @logger.warn "Completed with #{errors.size} errors"
      @logger.debug "First few errors: #{errors.first(3).join(", ")}" if @logger.debug?
    end

    def format_file_content(path, content)
      <<~TEXT
        ================================================================
        File: #{path}
        ================================================================
        #{content}

      TEXT
    end

    def fetch_file_content_with_retry(path, retries = 3, base_delay = 2)
      content = @client.contents(@options[:repository], path: path, ref: @options[:branch])
      Base64.decode64(content.content)
    rescue Octokit::TooManyRequests
      raise unless retries.positive?

      delay = base_delay**(4 - retries) * (0.8 + 0.4 * rand)
      @logger.warn "Rate limit exceeded, waiting #{delay.round(1)} seconds..."
      sleep(delay)
      fetch_file_content_with_retry(path, retries - 1, base_delay)
    end

    def write_buffer(file, buffer)
      return if buffer.empty?

      file.puts(buffer.join)
      buffer.clear
    end

    def prioritize_files(files)
      files.sort_by do |file|
        path = file.path.downcase
        if path.end_with?(".md", ".txt", ".json", ".yaml", ".yml") then 0
        elsif path.end_with?(".rb", ".py", ".js", ".ts", ".go", ".java", ".c", ".cpp", ".h") then 1
        else
          2
        end
      end
    end
  end

  class ProgressIndicator
    BAR_WIDTH = 30

    def initialize(total, logger)
      @total = total
      @logger = logger
      @last_percent = 0
      @start_time = Time.now
      @last_update_time = Time.now
      @update_interval = 0.5
    end

    def update(current)
      now = Time.now
      return if now - @last_update_time < @update_interval && current != @total

      @last_update_time = now
      percent = (current.to_f / @total * 100).round
      return unless percent > @last_percent || current == @total

      elapsed = now - @start_time
      progress_chars = (BAR_WIDTH * (current.to_f / @total)).round
      bar = "[#{"|" * progress_chars}#{" " * (BAR_WIDTH - progress_chars)}]"
      eta_string = current > 1 && percent < 100 ? " ETA: #{format_time((elapsed / current) * (@total - current))}" : ""
      rate = begin
        (current / elapsed).round(1)
      rescue StandardError
        0
      end
      print "\r\e[K#{bar} #{percent}% | #{current}/#{@total} files (#{rate} files/sec)#{eta_string}"
      print "\n" if current == @total
      if (percent % 10).zero? && percent != @last_percent || current == @total
        @logger.info "Processing: #{percent}% complete (#{current}/#{@total} files)#{eta_string}"
      end
      @last_percent = percent
    end

    private

    def format_time(seconds)
      return "< 1s" if seconds < 1

      case seconds
      when 0...60 then "#{seconds.round}s"
      when 60...3600 then "#{(seconds / 60).floor}m #{(seconds % 60).round}s"
      else "#{(seconds / 3600).floor}h #{((seconds % 3600) / 60).floor}m"
      end
    end
  end

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
          if part == parts.last then current[part] = nil
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
        current_prefix = if prefix.empty?
                           "    "
                         else
                           prefix + (is_last ? "    " : "│   ")
                         end
        connector = if prefix.empty?
                      "└── "
                    else
                      (is_last ? "└── " : "├── ")
                    end
        item = tree[key].is_a?(Hash) ? "#{key}/" : key
        output << "#{prefix}#{connector}#{item}"
        render_tree(tree[key], current_prefix, output) if tree[key].is_a?(Hash)
      end
    end
  end
end
