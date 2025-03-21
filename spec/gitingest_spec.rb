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
      expect(generator.options[:threads]).to eq(Gitingest::Generator::DEFAULT_THREAD_COUNT)
      expect(generator.options[:thread_timeout]).to eq(Gitingest::Generator::DEFAULT_THREAD_TIMEOUT)
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

    it "initializes with default exclude patterns" do
      generator = Gitingest::Generator.new(repository: mock_repo)
      expect(generator.excluded_patterns.size).to eq(Gitingest::Generator::DEFAULT_EXCLUDES.size)
    end

    it "adds custom exclude patterns" do
      custom_excludes = %w[custom_pattern another_pattern]
      generator = Gitingest::Generator.new(repository: mock_repo, exclude: custom_excludes)
      # Should have default excludes + custom excludes
      expect(generator.excluded_patterns.size).to eq(Gitingest::Generator::DEFAULT_EXCLUDES.size + custom_excludes.size)
    end

    describe "file exclusion" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }

      it "excludes dotfiles" do
        expect(generator.send(:excluded_file?, ".env")).to be true
      end

      it "excludes files in dot directories" do
        expect(generator.send(:excluded_file?, ".github/workflows/ci.yml")).to be true
      end

      it "excludes files matching default patterns" do
        expect(generator.send(:excluded_file?, "node_modules/package.json")).to be true
        expect(generator.send(:excluded_file?, "image.png")).to be true
        expect(generator.send(:excluded_file?, "vendor/cache/gems")).to be true
      end

      it "doesn't exclude regular code files" do
        expect(generator.send(:excluded_file?, "lib/gitingest.rb")).to be false
        expect(generator.send(:excluded_file?, "README.md")).to be false
      end
    end

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

        # Need to mock Octokit configuration
        expect(Octokit).to receive(:configure) do |&block|
          config = double("config")
          expect(config).to receive(:api_endpoint=).with(enterprise_endpoint)
          block.call(config)
        end

        generator = Gitingest::Generator.new(repository: mock_repo, api_endpoint: enterprise_endpoint)

        # API endpoint doesn't get stored on the client directly, just verify the client was created
        expect(generator.client).not_to be_nil
      end

      it "doesn't configure custom API endpoint when not provided" do
        # Verify Octokit.configure is not called when no api_endpoint is given
        expect(Octokit).not_to receive(:configure)

        generator = Gitingest::Generator.new(repository: mock_repo)
        expect(generator.client).not_to be_nil
      end
    end

    describe "repository access validation" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:mock_repository) { double("repository", default_branch: "main") }

      before do
        allow(generator.client).to receive(:repository).and_return(mock_repository)
        allow(generator.client).to receive(:branch)
      end

      it "validates repository access successfully" do
        expect { generator.send(:validate_repository_access) }.not_to raise_error
      end

      it "raises error for unauthorized access" do
        allow(generator.client).to receive(:repository).and_raise(Octokit::Unauthorized)
        expect { generator.send(:validate_repository_access) }.to raise_error(/Authentication error/)
      end

      it "raises error for repository not found" do
        allow(generator.client).to receive(:repository).and_raise(Octokit::NotFound)
        expect { generator.send(:validate_repository_access) }.to raise_error(/not found or is private/)
      end

      it "raises error for branch not found" do
        allow(generator.client).to receive(:branch).and_raise(Octokit::NotFound)
        expect { generator.send(:validate_repository_access) }.to raise_error(/Branch.*not found/)
      end
    end

    describe "fetch_repository_contents" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:tree) { double("tree", tree: []) }

      before do
        allow(generator).to receive(:validate_repository_access)
        allow(generator.client).to receive(:tree).and_return(tree)
      end

      it "fetches and filters repository contents" do
        file1 = double("file1", type: "blob", path: "lib/gitingest.rb")
        file2 = double("file2", type: "blob", path: "node_modules/package.json")
        file3 = double("file3", type: "tree", path: "lib")

        allow(tree).to receive(:tree).and_return([file1, file2, file3])
        allow(generator).to receive(:excluded_file?).with("lib/gitingest.rb").and_return(false)
        allow(generator).to receive(:excluded_file?).with("node_modules/package.json").and_return(true)

        generator.send(:fetch_repository_contents)
        expect(generator.repo_files).to eq([file1])
      end

      it "limits the number of files processed" do
        files = (1..1100).map { |i| double("file#{i}", type: "blob", path: "file#{i}.rb") }
        allow(tree).to receive(:tree).and_return(files)
        allow(generator).to receive(:excluded_file?).and_return(false)

        generator.send(:fetch_repository_contents)
        expect(generator.repo_files.size).to eq(Gitingest::Generator::MAX_FILES)
      end
    end

    describe "fetch_file_content_with_retry" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:content) { double("content", content: Base64.encode64("file content")) }

      it "fetches and decodes file content" do
        allow(generator.client).to receive(:contents).and_return(content)

        result = generator.send(:fetch_file_content_with_retry, "lib/file.rb")
        expect(result).to eq("file content")
      end

      it "retries when rate limited" do
        call_count = 0
        allow(generator).to receive(:sleep)

        allow(generator.client).to receive(:contents) do
          call_count += 1
          call_count < 2 ? raise(Octokit::TooManyRequests) : content
        end

        result = generator.send(:fetch_file_content_with_retry, "lib/file.rb")
        expect(result).to eq("file content")
        expect(call_count).to eq(2)
      end
    end

    describe "generate_file" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo, output_file: "test_output.txt") }
      let(:file_double) { instance_double(File) }

      before do
        allow(generator).to receive(:fetch_repository_contents)
        allow(generator).to receive(:process_content_to_output)
        allow(File).to receive(:open).with("test_output.txt", "w").and_yield(file_double)
      end

      it "fetches repository contents if empty" do
        expect(generator).to receive(:fetch_repository_contents)
        generator.generate_file
      end

      it "calls process_content_to_output with file handle" do
        expect(generator).to receive(:process_content_to_output).with(file_double)
        generator.generate_file
      end

      it "returns output file path" do
        expect(generator.generate_file).to eq("test_output.txt")
      end
    end

    describe "generate_prompt" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:string_io) { StringIO.new }
      let(:result_string) { "Generated content" }

      before do
        allow(generator).to receive(:fetch_repository_contents)
        allow(StringIO).to receive(:new).and_return(string_io)
        allow(generator).to receive(:process_content_to_output)
        allow(string_io).to receive(:string).and_return(result_string)
      end

      it "fetches repository contents if empty" do
        expect(generator).to receive(:fetch_repository_contents)
        generator.generate_prompt
      end

      it "calls process_content_to_output with StringIO" do
        expect(generator).to receive(:process_content_to_output).with(string_io)
        generator.generate_prompt
      end

      it "returns generated string content" do
        expect(generator.generate_prompt).to eq(result_string)
      end
    end

    describe "process_content_to_output" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }
      let(:repo_file) { double("repo_file", path: "lib/file.rb") }
      let(:output) { instance_double(StringIO) }
      let(:pool) { instance_double(Concurrent::FixedThreadPool) }
      let(:progress_indicator) { instance_double(Gitingest::ProgressIndicator) }

      before do
        generator.instance_variable_set(:@repo_files, [repo_file])
        allow(Gitingest::ProgressIndicator).to receive(:new).and_return(progress_indicator)
        allow(progress_indicator).to receive(:update)
        allow(Concurrent::FixedThreadPool).to receive(:new).and_return(pool)
        allow(pool).to receive(:post).and_yield
        allow(pool).to receive(:shutdown)
        allow(pool).to receive(:wait_for_termination).and_return(true) # Return true by default
        allow(pool).to receive(:kill)
        allow(output).to receive(:puts)
        allow(generator).to receive(:fetch_file_content_with_retry).with("lib/file.rb").and_return("file content")
        allow(generator).to receive(:prioritize_files).and_return([repo_file])
        allow(generator).to receive(:write_buffer)
      end

      it "processes each file and formats content" do
        expect(generator).to receive(:fetch_file_content_with_retry).with("lib/file.rb")
        expect(generator).to receive(:format_file_content).with("lib/file.rb", "file content")

        generator.send(:process_content_to_output, output)
      end

      it "handles thread pool timeout correctly" do
        # Setup wait_for_termination to return false to simulate timeout
        allow(pool).to receive(:wait_for_termination).with(generator.options[:thread_timeout]).and_return(false)

        # Expect kill to be called in this case
        expect(pool).to receive(:kill)

        generator.send(:process_content_to_output, output)
      end

      it "handles unexpected errors gracefully" do
        allow(generator).to receive(:fetch_file_content_with_retry).and_raise(StandardError, "Test error")

        # Should log error but not crash
        expect(generator.logger).to receive(:error).with(/Unexpected error processing/)

        # Should complete normally
        generator.send(:process_content_to_output, output)
      end

      it "processes thread-local buffers after completion" do
        # Mock thread buffer behavior
        thread_buffers = { Thread.current.object_id => ["some content"] }
        generator.instance_variable_set(:@thread_buffers, thread_buffers)

        # Should process remaining buffers
        expect(generator).to receive(:write_buffer).at_least(:once)

        generator.send(:process_content_to_output, output)
      end
    end

    describe "prioritize_files" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }

      it "prioritizes documentation files first" do
        readme = double("readme", path: "README.md")
        code = double("code", path: "lib/file.rb")
        other = double("other", path: "unknown.xyz")

        files = [code, other, readme]
        sorted = generator.send(:prioritize_files, files)

        expect(sorted.first).to eq(readme)
        expect(sorted.last).to eq(other)
      end
    end

    describe "run" do
      let(:generator) { Gitingest::Generator.new(repository: mock_repo) }

      it "runs the full workflow" do
        expect(generator).to receive(:fetch_repository_contents)
        expect(generator).to receive(:generate_file)

        generator.run
      end
    end

    describe "directory structure" do
      let(:mock_repo) { "user/repo" }
      let(:generator) { Gitingest::Generator.new(repository: mock_repo, show_structure: true) }

      before do
        # Mock repository validation to avoid API calls
        allow(generator).to receive(:fetch_repository_contents)

        # Mock the repo files
        file1 = double("file1", type: "blob", path: "README.md")
        file2 = double("file2", type: "blob", path: "lib/gitingest.rb")
        file3 = double("file3", type: "blob", path: "lib/gitingest/version.rb")
        file4 = double("file4", type: "blob", path: "bin/gitingest")

        generator.instance_variable_set(:@repo_files, [file1, file2, file3, file4])
      end

      it "sets the show_structure option" do
        expect(generator.options[:show_structure]).to be true
      end

      it "generates a directory structure" do
        structure = generator.generate_directory_structure
        expect(structure).to include("Directory structure:")
        expect(structure).to include("└── repo/")
        expect(structure).to include("├── README.md")
        expect(structure).to include("├── bin/")
        expect(structure).to include("│   └── gitingest")
        expect(structure).to include("└── lib/")
        expect(structure).to include("    ├── gitingest.rb")
        expect(structure).to include("    └── gitingest/")
        expect(structure).to include("        └── version.rb")
      end

      it "handles an empty repository gracefully" do
        generator.instance_variable_set(:@repo_files, [])
        # Skip fetching repository contents to avoid API call
        allow(generator).to receive(:fetch_repository_contents) # This is the key fix

        structure = generator.generate_directory_structure
        expect(structure).to include("Directory structure:")
        expect(structure).to include("└── repo/")
      end

      it "prioritizes the directory structure in 'run' when show_structure is true" do
        # Skip fetching repository contents to avoid API call
        allow(generator).to receive(:fetch_repository_contents) # This is the key fix
        expect(generator).to receive(:generate_directory_structure).and_return("Structure output")
        expect(generator).to receive(:puts).with("Structure output")
        expect(generator).not_to receive(:generate_file)

        generator.run
      end
    end
  end

  describe Gitingest::DirectoryStructureBuilder do
    let(:root_name) { "test-repo" }

    it "builds a tree structure from file paths" do
      files = [
        double("file1", path: "README.md"),
        double("file2", path: "src/main.rb"),
        double("file3", path: "src/lib/helper.rb"),
        double("file4", path: "test/test_main.rb")
      ]

      builder = Gitingest::DirectoryStructureBuilder.new(root_name, files)
      structure = builder.build

      expect(structure).to include("Directory structure:")
      expect(structure).to include("└── test-repo/")
      expect(structure).to include("    ├── README.md")
      expect(structure).to include("    ├── src/")
      expect(structure).to include("    │   ├── lib/")
      expect(structure).to include("    │   │   └── helper.rb")
      expect(structure).to include("    │   └── main.rb")
      expect(structure).to include("    └── test/")
      expect(structure).to include("        └── test_main.rb")
    end

    it "handles empty file list" do
      builder = Gitingest::DirectoryStructureBuilder.new(root_name, [])
      structure = builder.build

      expect(structure).to include("Directory structure:")
      expect(structure).to include("└── test-repo/")
    end
  end

  describe Gitingest::ProgressIndicator do
    let(:logger) { instance_double(Logger) }
    let(:progress) { Gitingest::ProgressIndicator.new(100, logger) }

    before do
      allow(logger).to receive(:info)
      # Stub print to avoid terminal output during tests
      allow(progress).to receive(:print)
    end

    it "only updates at meaningful intervals" do
      # First update should print progress bar
      expect(progress).to receive(:print).with(/\[\|/).once
      expect(progress).to receive(:print).with("\n").once.ordered
      progress.update(100) # Complete the progress to trigger both prints
    end

    it "logs at 10% increments" do
      # Reset expected last percent
      progress.instance_variable_set(:@last_percent, 0)

      # Need to mock Time.now to make elapsed time calculation consistent
      allow(Time).to receive(:now).and_return(Time.now + 10)

      # Allow the update interval check to pass
      progress.instance_variable_set(:@last_update_time, Time.now - 1)

      # Should log at 10%
      expect(logger).to receive(:info).with(/Processing: 10% complete/)
      progress.update(10)
    end

    it "includes ETA for incomplete progress" do
      # Create a fresh instance with controlled timing
      start_time = Time.now - 50 # 50 seconds ago
      progress = Gitingest::ProgressIndicator.new(100, logger)
      progress.instance_variable_set(:@start_time, start_time)
      progress.instance_variable_set(:@last_update_time, start_time)
      progress.instance_variable_set(:@last_percent, 0)

      # First allow any print call
      allow(progress).to receive(:print)

      # Check logger output for ETA
      expect(logger).to receive(:info).with(/ETA:/)

      # Update to 50% - halfway through should give ETA close to elapsed time
      progress.update(50)
    end
  end
end
