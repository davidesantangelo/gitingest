# frozen_string_literal: true

require "octokit"

module Gitingest
  class RepositoryFetcher
    MAX_FILES = 1000

    def initialize(client, repository, branch = :default, exclusion_filter = nil)
      @client = client
      @repository = repository
      @branch = branch
      @exclusion_filter = exclusion_filter
    end

    def fetch
      validate_repository_access
      repo_tree = @client.tree(@repository, @branch, recursive: true)

      files = repo_tree.tree.select do |item|
        item.type == "blob" && !@exclusion_filter&.excluded?(item.path)
      end

      if files.size > MAX_FILES
        # We might want to warn here, but for now we just truncate
        files = files.first(MAX_FILES)
      end

      files
    rescue Octokit::Unauthorized
      raise AuthenticationError, "Authentication error: Invalid or expired GitHub token"
    rescue Octokit::NotFound
      raise RepositoryNotFoundError, "Repository not found or is private"
    rescue Octokit::Error
      raise Error, "Error accessing repository. Please check your credentials and repository name"
    end

    private

    def validate_repository_access
      repo = @client.repository(@repository)
      @branch = repo.default_branch if @branch == :default

      begin
        @client.branch(@repository, @branch)
      rescue Octokit::NotFound
        raise BranchNotFoundError, "Branch not found in repository"
      end
    rescue Octokit::Unauthorized
      raise AuthenticationError, "Authentication error: Invalid or expired GitHub token"
    rescue Octokit::NotFound
      raise RepositoryNotFoundError, "Repository not found or is private"
    end
  end
end
