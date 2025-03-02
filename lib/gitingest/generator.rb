# frozen_string_literal: true

require "octokit"
require "base64"
require "fileutils"
require "concurrent"

module Gitingest
  class Generator
    # Default exclusion patterns for common files and directories
    DEFAULT_EXCLUDES = [
      '\.git/', '\.github/', '\.gitignore', '\.DS_Store',
      '.*\.log$', '.*\.png$', '.*\.jpg$', '.*\.jpeg$', '.*\.gif$', '.*\.svg$',
      '.*\.pdf$', '.*\.zip$', '.*\.tar\.gz$', "node_modules/", "vendor/"
    ].freeze

    # Maximum number of files to process to prevent memory overload
    MAX_FILES = 1000

    attr_reader :options, :client, :repo_files, :excluded_patterns

    def initialize(options = {})
      @options = options
      @repo_files = []
      @excluded_patterns = []
      validate_options
      configure_client
      compile_excluded_patterns
    end

    ### Option Validation
    def validate_options
      raise ArgumentError, "Repository is required" unless @options[:repository]

      @options[:output_file] ||= "#{@options[:repository].split("/").last}_prompt.txt"
      @options[:branch] ||= "main"
      @options[:exclude] ||= []
      @excluded_patterns = DEFAULT_EXCLUDES + @options[:exclude]
    end

    ### Client Configuration
    def configure_client
      @client = @options[:token] ? Octokit::Client.new(access_token: @options[:token]) : Octokit::Client.new
      puts "Warning: No token provided. API limits restricted." unless @options[:token]
    end

    def compile_excluded_patterns
      @excluded_patterns = @excluded_patterns.map { |pattern| Regexp.new(pattern) }
    end

    ### Fetch Repository Contents
    def fetch_repository_contents
      puts "Fetching repository: #{@options[:repository]} (branch: #{@options[:branch]})"
      begin
        repo_tree = @client.tree(@options[:repository], @options[:branch], recursive: true)
        @repo_files = repo_tree.tree.select { |item| item.type == "blob" && !excluded_file?(item.path) }
        if @repo_files.size > MAX_FILES
          puts "Warning: Found #{@repo_files.size} files, limited to #{MAX_FILES}."
          @repo_files = @repo_files.first(MAX_FILES)
        end
        puts "Found #{@repo_files.size} files after exclusion filters"
      rescue Octokit::Error => e
        raise "Error accessing repository: #{e.message}"
      end
    end

    def excluded_file?(path)
      return true if path.start_with?(".") || path.split("/").any? { |part| part.start_with?(".") }

      @excluded_patterns.any? { |pattern| path.match?(pattern) }
    end

    ### Generate Prompt
    def generate_prompt
      puts "Generating prompt..."
      Concurrent::Array.new(@repo_files)
      buffer = []
      buffer_size = 100 # Write every 100 files to reduce I/O

      # Dynamic thread pool based on core count
      pool = Concurrent::FixedThreadPool.new([Concurrent.processor_count, 5].max)

      File.open(@options[:output_file], "w") do |file|
        @repo_files.each_with_index do |repo_file, index|
          pool.post do
            content = fetch_file_content_with_retry(repo_file.path)
            result = <<~TEXT
              ================================================================
              File: #{repo_file.path}
              ================================================================
              #{content}

            TEXT
            buffer << result
            write_buffer(file, buffer) if buffer.size >= buffer_size
            print "\rProcessing: #{index + 1}/#{@repo_files.size} files"
          rescue Octokit::Error => e
            puts "\nError fetching #{repo_file.path}: #{e.message}"
          end
        end
        pool.shutdown
        pool.wait_for_termination
        write_buffer(file, buffer) unless buffer.empty?
      end
      puts "\nPrompt generated and saved to #{@options[:output_file]}"
    end

    def fetch_file_content_with_retry(path, retries = 3)
      content = @client.contents(@options[:repository], path: path, ref: @options[:branch])
      Base64.decode64(content.content)
    rescue Octokit::TooManyRequests
      raise unless retries.positive?

      sleep_time = 60 / retries
      puts "Rate limit exceeded, waiting #{sleep_time} seconds..."
      sleep(sleep_time)
      fetch_file_content_with_retry(path, retries - 1)
    end

    def write_buffer(file, buffer)
      file.puts(buffer.join)
      buffer.clear
    end

    ### Main Execution
    def run
      fetch_repository_contents
      generate_prompt
    end
  end
end
