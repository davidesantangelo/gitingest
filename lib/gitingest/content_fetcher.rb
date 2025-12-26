# frozen_string_literal: true

require "concurrent"
require "base64"

module Gitingest
  class ContentFetcher
    BUFFER_SIZE = 250
    LOCAL_BUFFER_THRESHOLD = 50
    DEFAULT_THREAD_COUNT = [Concurrent.processor_count, 8].min
    DEFAULT_THREAD_TIMEOUT = 60 # seconds

    def initialize(client, repository, files, logger, options = {})
      @client = client
      @repository = repository
      @files = files
      @logger = logger
      @threads = options[:threads] || DEFAULT_THREAD_COUNT
      @thread_timeout = options[:thread_timeout] || DEFAULT_THREAD_TIMEOUT
    end

    def fetch(output)
      @logger.debug "Using thread pool with #{@threads} threads"
      buffer = []
      progress = ProgressIndicator.new(@files.size, @logger)
      thread_buffers = Concurrent::Map.new
      mutex = Mutex.new
      errors = Concurrent::Array.new
      pool = Concurrent::FixedThreadPool.new(@threads)
      prioritized_files = prioritize_files(@files)

      prioritized_files.each_with_index do |repo_file, index|
        pool.post do
          thread_id = Thread.current.object_id
          thread_buffers[thread_id] ||= []
          local_buffer = thread_buffers[thread_id]
          begin
            content = fetch_file_content_with_retry(repo_file.sha)
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
            @logger.error "Error fetching #{repo_file.path}: #{e.message}"
            mutex.synchronize { errors << "Error fetching file: #{repo_file.path}" }
          rescue StandardError => e
            @logger.error "Unexpected error processing #{repo_file.path}: #{e.message}"
            mutex.synchronize { errors << "Unexpected error processing file: #{repo_file.path}" }
          end
        end
      end

      pool.shutdown
      unless pool.wait_for_termination(@thread_timeout)
        @logger.warn "Thread pool did not shut down gracefully within #{@thread_timeout}s, forcing termination."
        pool.kill
      end

      mutex.synchronize do
        thread_buffers.each_value { |local_buffer| buffer.concat(local_buffer) unless local_buffer.empty? }
        write_buffer(output, buffer) unless buffer.empty?
      end

      return unless errors.any?

      @logger.warn "Completed with #{errors.size} errors"
      @logger.debug "First few errors: #{errors.first(3).join(", ")}" if @logger.debug?
    end

    private

    def format_file_content(path, content)
      <<~TEXT
        ================================================================
        File: #{path}
        ================================================================
        #{content}

      TEXT
    end

    def fetch_file_content_with_retry(sha, retries = 3, base_delay = 2)
      blob = @client.blob(@repository, sha)
      content = blob.content
      case blob.encoding
      when "base64"
        Base64.decode64(content)
      else
        content
      end
    rescue Octokit::TooManyRequests
      raise unless retries.positive?

      delay = base_delay**(4 - retries) * (0.8 + 0.4 * rand)
      @logger.warn "Rate limit exceeded, waiting #{delay.round(1)} seconds..."
      sleep(delay)
      fetch_file_content_with_retry(sha, retries - 1, base_delay)
    end

    def write_buffer(file, buffer)
      return if buffer.empty?

      file.puts(buffer.join)
      buffer.clear
    end

    def prioritize_files(files)
      files.sort_by do |file|
        ext = File.extname(file.path.downcase)
        case ext
        when ".md", ".txt", ".json", ".yaml", ".yml"
          0 # Documentation and data files first
        when ".rb", ".py", ".js", ".ts", ".go", ".java", ".c", ".cpp", ".h"
          1 # Source code files second
        else
          2 # Other files last
        end
      end
    end
  end
end
