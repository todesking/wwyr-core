module GitStalker
  class App
    def initialize(config)
      @config = config
    end

    attr_reader :config

    def events
      app_state = State.new
      rules = config.rules

      config.repositories.map {|repo|
        prev_state = app_state.load_repo_state(repo)
        next [] unless prev_state
        extract_all_events(repo, prev_state)
      }.flatten(1)
    end
  end

  def extract_all_events(repo, prev_state)
    repo.changed_branches(prev_state).map {|branch|
      prev_head = prev_state.head_of(branch)
      [
        extract_branch_events(branch, prev_head),
        extract_commit_events(branch, prev_head),
      ]
    }.flatten(2)
  end
  def extract_branch_events(brahch, prev_head)
    config.branch_rules_for(branch.repo).map {|rule|
      rule.extract_branch_events(branch, prev_head)
    }.flatten(1)
  end

  def extract_commit_events(branch, prev_head)
    commit_rules = config.rules.commit_rules_for(branch)
    branch.new_commits_since(prev_head).map {|commit|
      commit_rules.map {|rule|
        rule.extract_commit_events(commit)
      }
    }.flatten(2)
  end

  class Config
    def initialize(working_dir)
      @working_repos = WorkingRepositories.new(working_dir)
    end
    attr_reader :rules
    attr_reader :working_repos

    def repositories
      repos = {
        'mysql2' => 'https://github.com/brianmario/mysql2.git',
      }

      repos.map {|name, url|
        Repository.new(name, url).tap do|r|
          r.working_repo = working_repos.for(r)
        end
      }
    end

    def rules
      Rules.new.tap do|rules|
        rules.add_commit_rule(
          RepositoryPattern.all,
          BranchPattern.name_exact('master'),
          CommitRule::LineAdded.new(/def close/)
        )
      end
    end
  end

  class WorkingRepositories
    def initialize(working_root_dir)
      @working_root_dir = working_root_dir
    end
    attr_reader :working_root_dir
    def for(repo)
      WorkingRepository.new(working_root_dir, repo)
    end
  end

  class WorkingRepository
    def initialize(working_root_dir, name, url)
      @logical_repository = repo
      @working_dir = File.join(working_root_dir, name)
      @repo_url = url
    end
    def raw
      @raw ||=
        begin
          ensure_cloned
          Grit::Repo.new(@working_dir)
        end
    end

    def ensure_cloned
      setup_working_repo unless exists?
      nil
    end

    private
      def exists?
        File.exists?(@working_dir)
      end
      def setup_working_repo
        git = Grit::Git.new(@working_dir)
        git.native(:clone, {}, @repo_url, @working_dir)
      end
  end

  class Repository
    def initialize(name, url)
      @name, @url = name, url
    end

    attr_reader :name
    attr_reader :url

    attr_accessor :working_repo

    def current_state
      RepositoryState.new(
        self,
        branches.each_with_object({}) do|branch, h|
          h[branch] = Commit.new(self, branch.head)
        end
      )
    end

    def changed_branches(prev_state)
      head_changed = current_state.filter {|branch, commit|
        prev_state.head_of(branch) != commit
      }.map{|b, c| b}
      removed = prev_state.filter{|branch, commit|
        current_state.has_branch?(branch)
      }.map{|b, c| b}

      head_changed + removed
    end

    def branches
      working_repo.remotes.map{|raw|
        Branch.new(self, raw.name)
      }
    end

    def branch_exists?(name)
      !!raw_branch(name)
    end

    def branch_head_of(name)
      raw_b = raw_branch(name)
      raise "Branch not exists: #{name}" unless raw_b
      Commit.new(self, raw_b.commit)
    end

    private
      def raw_branch(name)
        fullname = "origin/#{name}"
        working_repo.remotes.detect{|ref| ref.name == fullname }
      end
  end

  class Branch
    def initialize(repo, name)
      @repo, @name = repo, name
    end
    attr_reader :repo
    attr_reader :name
    def new_commits_since(commit)
    end
    def exists?
      repo.branch_exists?(self.name)
    end
    def head
      repo.branch_head_of(self.name)
    end
  end

  class RepositoryState
    include Enumerable
    # &(Branch -> Commit ->) ->
    def each(&block)
      @heads.each(&block)
    end

    # Repository -> {Branch => Commit} ->
    def initialize(repo, heads)
      @repo = repo
      @heads = heads
    end

    # Branch -> Commit|nil
    def head_of(branch)
      heads[branch]
    end
  end

  class Commit
    def initialize(repository, raw_commit)
    end
    def changed_files
    end
  end

  class ChangedFile
  end

  class Rules
    def initialize
      # {RepositoryPattern => BranchRule}
      @branch_rules = {}
      # {BranchPattern => CommitRule}
      @commit_rules = {}
    end
    def add_branch_rule(repo_pat, rule)
    end
    def add_commit_rule(repo_pat, branch_pat, rule)
    end
    def branch_rules_for(repo)
    end
    def commit_rules_for(branch)
    end
  end

  class BranchRule
    def extract_branch_events(branch, prev_head)
      []
    end
  end

  class CommitRule
    def extract_commit_events(commit)
      []
    end
    class LineAdded < self
      def initialize(pat)
        @pat = pat
      end
      def extract_commit_events(commit)
        comit.ch
      end
    end
  end

  class RepositoryPattern
    def match?(repo)
    end

    def self.all
      All.new
    end
    class All < self
      def match?(repo)
        true
      end
    end
  end
  class BranchPattern
    def match?(branch)
    end

    def self.name_exact(*names)
      Exact.new(names)
    end
    class Exact < self
      def initialize(names)
        @names = names
      end
      def match?(branch)
        @names.include? branch.name
      end
    end
  end

  class State
    def load_repo_state(repo)
      nil
    end
  end
end
