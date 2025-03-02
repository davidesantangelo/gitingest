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
        expect(generator.excluded_file?(".env")).to be true
      end

      it "excludes files in dot directories" do
        expect(generator.excluded_file?(".github/workflows/ci.yml")).to be true
      end

      it "excludes files matching default patterns" do
        expect(generator.excluded_file?("node_modules/package.json")).to be true
        expect(generator.excluded_file?("image.png")).to be true
        expect(generator.excluded_file?("vendor/cache/gems")).to be true
      end

      it "doesn't exclude regular code files" do
        expect(generator.excluded_file?("lib/gitingest.rb")).to be false
        expect(generator.excluded_file?("README.md")).to be false
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
  end
end
