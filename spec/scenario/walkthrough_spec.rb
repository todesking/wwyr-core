require 'spec_helper'

describe "At first, there is a repository" do
  after(:all) { SpecHelper.cleanup }
  let(:ns) { WWYR }
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
  describe 'config.repositories' do
    subject { config.repositories }
    its(:size) { should == 1 }
  end
  describe 'the repository' do
    let(:repository) { config.repositories.first }
    subject { repository }
    its(:name) { should == 'test' }
    context 'with no commits' do
      describe 'master branch' do
        subject { repository.branch('master') }
        it { should_not be_exist }
        it('head is unavailable') { expect { subject.head }.to raise_error }
      end
      describe 'repository state' do
        subject { repository.current_state }
        it('should have no branch') { subject.to_a.size.should == 0 }
      end
    end
    context 'with some commits' do
      let(:master_branch) { repository.branch('master') }
      before(:each) do
        repo_a.new_file 'readme', 'this is readme'
        repo_a.git *%(add readme)
        repo_a.git *%w(commit -m first_commit)

        repo_a.modify_file 'readme', 'READ!! ME!!'
        repo_a.new_file 'license', 'DO WHAT THE FUCK YOU WANT'
        repo_a.git *%w(add readme license)
        repo_a.git *%w(commit -m second_commit)
      end
      describe 'master branch' do
        subject { repository.branch('master') }
        it { should be_exist }
        its(:head) { should_not be_nil }
        describe 'head commit' do
          subject { master_branch.head }
          its(:message) { should == 'second_commit' }
          describe 'changed files' do
            let(:changed_files) { master_branch.head.changed_files }
            subject { changed_files }
            its(:size) { should == 2 }
            describe 'file: readme' do
              subject { changed_files.detect{|cf| cf.path == 'readme' } }
              it { should_not be_new_file }
              its(:added_lines) { should == ['READ!! ME!!'] }
              its(:deleted_lines) { should == ['this is readme'] }
            end
            describe 'file: license' do
              subject { changed_files.detect{|cf| cf.path == 'license' } }
              it { should be_new_file }
              its(:added_lines) { should == ['DO WHAT THE FUCK YOU WANT'] }
              its(:deleted_lines) { should be_empty }
            end
          end
        end
        describe 'recent_commits' do
          describe 'recent 0 commits' do
            subject { master_branch.recent_commits(0) }
            its(:size) { should == 0}
          end
          describe 'recent 1 commits' do
            subject { master_branch.recent_commits(1) }
            its(:size) { should == 1 }
            it('only contains head') { subject[0].id == master_branch.head.id }
          end
          describe 'recent 5 commits' do
            subject { master_branch.recent_commits(5) }
            its(:size) { should == 2 }
            it('only contains head') { subject[0].id == master_branch.head.id }
          end
        end
      end
      describe 'repository state' do
        subject { repository.current_state }
        it('should have 1 branch') { subject.to_a.size.should == 1 }
        describe '#head_of(master branch)' do
          subject { repository.current_state.head_of(master_branch) }
          it('should masters head') { subject.should == master_branch.head }
        end
      end
    end
  end
end
