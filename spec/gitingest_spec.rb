# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gitingest do
  it "has a version number" do
    expect(Gitingest::VERSION).not_to be nil
  end

  describe Gitingest::Generator do
    it "requires a repository option" do
      expect { Gitingest::Generator.new({}) }.to raise_error(ArgumentError)
    end

    it "sets default values" do
      generator = Gitingest::Generator.new(repository: "user/repo")
      expect(generator.options[:branch]).to eq("main")
      expect(generator.options[:output_file]).to eq("repo_prompt.txt")
    end

    it "uses repository name for output file when not specified" do
      generator = Gitingest::Generator.new(repository: "user/custom-repo")
      expect(generator.options[:output_file]).to eq("custom-repo_prompt.txt")
    end

    it "respects custom output filename" do
      generator = Gitingest::Generator.new(repository: "user/repo", output_file: "custom_output.txt")
      expect(generator.options[:output_file]).to eq("custom_output.txt")
    end

    it "respects custom branch name" do
      generator = Gitingest::Generator.new(repository: "user/repo", branch: "develop")
      expect(generator.options[:branch]).to eq("develop")
    end

    it "initializes with default exclude patterns" do
      generator = Gitingest::Generator.new(repository: "user/repo")
      expect(generator.excluded_patterns.size).to eq(Gitingest::Generator::DEFAULT_EXCLUDES.size)
    end

    it "adds custom exclude patterns" do
      custom_excludes = %w[custom_pattern another_pattern]
      generator = Gitingest::Generator.new(repository: "user/repo", exclude: custom_excludes)
      # Should have default excludes + custom excludes
      expect(generator.excluded_patterns.size).to eq(Gitingest::Generator::DEFAULT_EXCLUDES.size + custom_excludes.size)
    end

    describe "#excluded_file?" do
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }

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
        generator = Gitingest::Generator.new(repository: "user/repo", token: token)
        expect(generator.client.access_token).to eq(token)
      end

      it "creates anonymous client when no token provided" do
        generator = Gitingest::Generator.new(repository: "user/repo")
        expect(generator.client.access_token).to be_nil
      end
    end

    describe "repository access validation" do
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }

      before do
        allow(generator.client).to receive(:repository)
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
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }
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
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }
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

    describe "generate_prompt" do
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }
      let(:repo_file) { double("repo_file", path: "lib/file.rb") }
      let(:file_double) { instance_double(File) }
      let(:pool) { instance_double(Concurrent::FixedThreadPool) }

      before do
        generator.instance_variable_set(:@repo_files, [repo_file])
        allow(Concurrent::FixedThreadPool).to receive(:new).and_return(pool)
        allow(pool).to receive(:post).and_yield
        allow(pool).to receive(:shutdown)
        allow(pool).to receive(:wait_for_termination).and_return(true) # Return true by default
        allow(pool).to receive(:kill) # Add this line to allow the kill method
        allow(File).to receive(:open).and_yield(file_double)
        allow(file_double).to receive(:puts)
        allow(generator).to receive(:fetch_file_content_with_retry).with("lib/file.rb").and_return("file content")
        allow(generator).to receive(:print) # For progress indicator
      end

      it "processes each file and generates content" do
        # Don't stub write_buffer so the actual method is called
        expect(generator).to receive(:fetch_file_content_with_retry).with("lib/file.rb")

        # The buffer should be written at the end of processing
        expect(file_double).to receive(:puts) do |content|
          expect(content).to include("File: lib/file.rb")
          expect(content).to include("file content")
        end

        generator.send(:generate_prompt)
      end

      # Add a specific test for thread pool timeout handling
      it "handles thread pool timeout correctly" do
        # Setup wait_for_termination to return false to simulate timeout
        allow(pool).to receive(:wait_for_termination).and_return(false)

        # Expect kill to be called in this case
        expect(pool).to receive(:kill)

        generator.send(:generate_prompt)
      end
    end

    describe "run" do
      let(:generator) { Gitingest::Generator.new(repository: "user/repo") }

      it "runs the full workflow" do
        expect(generator).to receive(:fetch_repository_contents)
        expect(generator).to receive(:generate_prompt)

        generator.run
      end
    end
  end
end
