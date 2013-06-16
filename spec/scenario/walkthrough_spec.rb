require 'spec_helper'

describe "At first, there is a repository" do
  after(:all) { SpecHelper.cleanup }
  let(:ns) { GitStalker }
  let(:working_dir) { new_tmp_dir }
  let(:repo_a) { new_git_repository }
  let(:config_yaml) { <<-EOS }
repositories:
  test:
    url: #{repo_a.path}
  EOS
  let(:config) { ns::Config.new(YAML.load(config_yaml), working_dir) }
  let(:app) { ns::App.new(config) }
  before(:each) do
    repo_a.exec :git, :init
  end
  describe 'first of first, we test the initialization process' do
    it('should_success') {}
    describe 'git init' do
      before(:each) do
        repo_a.exec :git, :init
      end
      it('should_success') {}
    end
  end
  context 'with no commits' do
    it { config.repositories.size.should == 1 }
    describe 'the repository' do
      subject { config.repositories.first }
      its(:name) { should == 'test' }
    end
  end
end
