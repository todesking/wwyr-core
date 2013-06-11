class NotImplemented < StandardError; end
def nimpl; raise NotImplemented; end

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
      WorkingRepository.new(working_root_dir, repo.name, repo.url)
    end
  end

  class WorkingRepository
    def initialize(working_root_dir, name, url)
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
          h[branch] = branch.head
        end
      )
    end

    def changed_branches(prev_state)
      head_changed = current_state.select {|branch, commit|
        prev_state.head_of(branch) != commit
      }.map{|b, c| b}

      removed = prev_state.select {|branch, commit|
        current_state.has_branch?(branch)
      }.map{|b, c| b}

      head_changed + removed
    end

    def branches
      working_repo.raw.remotes.reject{|raw| raw.name == 'origin/HEAD'}.map{|raw|
        Branch.new(self, raw.name.gsub(/^origin\//, ''))
      }
    end

    def branch(name)
      branches.find{|b| b.name == name} || (raise "Branch not found: #{name}")
    end

    # String -> Commit
    def commit(id)
      Commit.new(self, id)
    end

    def branch_exists?(name)
      !!raw_branch(name)
    end

    def branch_head_of(name)
      raw_b = raw_branch(name)
      raise "Branch not exists: #{name}" unless raw_b
      Commit.new(self, raw_b.commit.id)
    end

    def changed_files_in_commit(id)
      working_repo.raw.commit(id).diffs.map{|d| ChangedFile.new(self, d) }
    end

    def commits_between(from_id, to_id)
      working_repo.raw.commits_between(from_id, to_id).map {|c|
        commit(c.id)
      }
    end

    private
      def raw_branch(name)
        fullname = "origin/#{name}"
        working_repo.raw.remotes.detect{|ref| ref.name == fullname }
      end
  end

  class Branch
    def initialize(repo, name)
      @repo, @name = repo, name
    end
    attr_reader :repo
    attr_reader :name

    # Commit|nil -> [Commit ...]|[]
    def new_commits_since(commit)
      if commit
        @repo.commits_between(commit.id, head.id)
      else
        []
      end
    end
    def exists?
      repo.branch_exists?(self.name)
    end
    def head
      repo.branch_head_of(self.name)
    end

    def ==(other)
      other.is_a?(Branch) && self.poro == other.poro
    end

    alias eql? ==

    def hash
      poro.hash
    end

    def poro
      [@repo.name, @name]
    end
  end

  class RepositoryState
    include Enumerable
    # &([Branch ,Commit] ->) ->
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
      @heads[branch]
    end

    def has_branch?(branch)
      !!@heads[branch]
    end
  end

  class Commit
    def initialize(repository, id)
      @repo = repository
      @id = id
    end
    attr_reader :id

    def changed_files
      @repo.changed_files_in_commit(id)
    end
  end

  class ChangedFile
    def initialize(commit, raw_diff)
      parsed = parse_diff(raw_diff.diff)
      @added_lines = parsed[:added_lines]
      @deleted_lines = parsed[:deleted_lines]
      @prev_path = raw_diff.a_path
      @path = raw_diff.b_path
    end

    attr_reader :prev_path
    attr_reader :path
    attr_reader :added_lines
    attr_reader :deleted_lines

    private
      # raw_diff_str -> { :added_lines|:deleted_lines => [line] }
      def parse_diff(str)
        added = []
        deleted = []
        lines = str.split(/\n/)
        lines.each do|line|
          case line
          when /^\+ /
            added << line.sub(/^\+ /, '')
          when /^- /
            deleted << line.sub(/^- /, '')
          else
            # nothing
          end
        end
        {
          added_lines: added,
          deleted_lines: deleted,
        }
      end
  end

  class Rules
    def initialize
      # {RepositoryPattern => BranchRule}
      @branch_rules = {}
      # {BranchPattern => CommitRule}
      @commit_rules = {}
    end
    def add_branch_rule(repo_pat, rule)
      nimpl
    end
    def add_commit_rule(repo_pat, branch_pat, rule)
      nimpl
    end
    def branch_rules_for(repo)
      nimpl
    end
    def commit_rules_for(branch)
      nimpl
    end
  end

  class BranchRule
    def extract_branch_events(branch, prev_head)
      nimpl
    end
  end

  class CommitRule
    def extract_commit_events(commit)
      nimpl
    end
    class RubyMethod < self
      def extract_commit_events(commit)
        events = []
        commit.changed_files.each do|cf|
          added = defined_method_names(cf.added_lines)
          deleted = defined_method_names(cf.deleted_lines)
          changed = added & deleted
          just_deleted = deleted - added
          just_added = added - deleted
          unless [changed, just_deleted, just_added].all?(&:empty?)
            events << CommitEvent.new('ruby.method', commit, {
              path: cf.path,
              added: just_added,
              deleted: just_deleted,
              changed: changed,
            })
          end
        end
        events
      end
      private
        def defined_method_names(lines)
          defmethod_pat = /^\s*def\s+(([a-zA-Z0-9_!?]+\.)?[a-zA-Z0-9_!?]+)/
          lines.select{|l| l =~ defmethod_pat}.map{|l| defmethod_pat.match(l)[1]}.uniq
        end
    end
  end

  class CommitEvent
    def initialize(type, commit, data)
      @type = type
      @commit = commit
      @data = data
    end
    attr_reader :type
    attr_reader :commit
    attr_reader :data
  end

  class RepositoryPattern
    def match?(repo)
      nimpl
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
      nimpl
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
      case repo.name
      when 'mysql2'
        RepositoryState.new(repo, {
          Branch.new(repo, 'master') => repo.commit('e9d96941a4c962b940b47022bbfe77bcc37b652e')
        })
      else
        RepositoryState.new(repo, {})
      end
    end
  end
end
