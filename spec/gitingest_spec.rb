# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gitingest do
  it "has a version number" do
    expect(Gitingest::VERSION).not_to be nil
  end

  describe Gitingest::Generator do
    let(:mock_repo) { "user/repo" }
    let(:mock_branch) { "main" }

    it "requires a repository option" do
      expect { Gitingest::Generator.new({}) }.to raise_error(ArgumentError)
    end

    it "sets default values" do
      generator = Gitingest::Generator.new(repository: mock_repo)
      expect(generator.options[:branch]).to eq(:default)
      expect(generator.options[:output_file]).to eq("repo_prompt.txt")
      expect(generator.options[:threads]).to eq(Gitingest::ContentFetcher::DEFAULT_THREAD_COUNT)
      expect(generator.options[:thread_timeout]).to eq(Gitingest::ContentFetcher::DEFAULT_THREAD_TIMEOUT)
    end

    it "uses repository name for output file when not specified" do
      generator = Gitingest::Generator.new(repository: "user/custom-repo")
      expect(generator.options[:output_file]).to eq("custom-repo_prompt.txt")
    end

    it "respects custom output filename" do
      generator = Gitingest::Generator.new(repository: mock_repo, output_file: "custom_output.txt")
      expect(generator.options[:output_file]).to eq("custom_output.txt")
    end

    it "respects custom branch name" do
      generator = Gitingest::Generator.new(repository: mock_repo, branch: "develop")
      expect(generator.options[:branch]).to eq("develop")
    end

    it "respects custom thread settings" do
      generator = Gitingest::Generator.new(repository: mock_repo, threads: 4, thread_timeout: 30)
      expect(generator.options[:threads]).to eq(4)
      expect(generator.options[:thread_timeout]).to eq(30)
    end

    # Note: File exclusion functionality is tested in spec/gitingest/exclusion_filter_spec.rb
    # Note: Repository access validation is tested in spec/gitingest/repository_fetcher_spec.rb

    describe "client configuration" do
      it "uses token for authentication when provided" do
        token = "sample_token"
        generator = Gitingest::Generator.new(repository: mock_repo, token: token)
        expect(generator.client.access_token).to eq(token)
      end

      it "creates anonymous client when no token provided" do
        generator = Gitingest::Generator.new(repository: mock_repo)
        expect(generator.client.access_token).to be_nil
      end

      it "configures GitHub Enterprise API endpoint when provided" do
        enterprise_endpoint = "https://github.example.com/api/v3/"

        # Thread-safe: api_endpoint is passed directly to client constructor
        generator = Gitingest::Generator.new(repository: mock_repo, api_endpoint: enterprise_endpoint)

        # Verify the client was created with the correct api_endpoint
        expect(generator.client).not_to be_nil
        expect(generator.client.api_endpoint).to eq(enterprise_endpoint)
      end

      it "uses default API endpoint when not provided" do
        generator = Gitingest::Generator.new(repository: mock_repo)
        expect(generator.client).not_to be_nil
        # Should use default GitHub API endpoint
        expect(generator.client.api_endpoint).to eq("https://api.github.com/")
      end
    end

    describe "run" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:fetcher) { instance_double(Gitingest::RepositoryFetcher) }
      let(:content_fetcher) { instance_double(Gitingest::ContentFetcher) }
      let(:files) { [double("file", path: "test.rb")] }

      before do
        allow(Gitingest::RepositoryFetcher).to receive(:new).and_return(fetcher)
        allow(Gitingest::ContentFetcher).to receive(:new).and_return(content_fetcher)
        allow(fetcher).to receive(:fetch).and_return(files)
        allow(content_fetcher).to receive(:fetch)
      end

      it "coordinates fetching and generation" do
        expect(fetcher).to receive(:fetch)
        expect(content_fetcher).to receive(:fetch)

        generator.run
      end

      it "generates directory structure when requested" do
        generator = Gitingest::Generator.new(repository: mock_repo, show_structure: true)

        expect(fetcher).to receive(:fetch)
        expect(generator).to receive(:puts).with(/Directory structure:/)
        expect(content_fetcher).not_to receive(:fetch)

        generator.run
      end
    end
  end
end
