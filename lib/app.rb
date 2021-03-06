class NotImplemented < StandardError; end
def nimpl; raise NotImplemented; end

require 'yaml'
require 'grit'
require 'typedocs/fallback'
require 'tsort'

module WWYR
  module Entity
    def ==(other)
      other.class == self.class && other.entity_id == self.entity_id
    end
    alias eql? ==
    def hash
      entity_id.hash
    end
    def entity_id
      raise "should be implemented"
    end
  end

  class App
    def initialize(config)
      @config = config
    end

    attr_reader :config

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
  end

  class Config
    include Typedocs::DSL

    tdoc "Hash -> String ->"
    def initialize(config_hash, working_dir)
      @config = config_hash.dup.freeze
      @working_repos = WorkingRepositories.new(working_dir)
    end
    attr_reader :rules
    attr_reader :working_repos

    def repositories
      @config['repositories'].map {|name, attr|
        Repository.new(name, attr['url']).tap do|r|
          r.working_repo = working_repos.for(r)
        end
      }
    end

    def rules
      Rules.new.tap do|rules|
        @config['rules']['commit'].each do|c|
          type, config =
            case c
            when String then [c, {}]
            else [c['type'], c]
            end
          rules.add_commit_rule(
            RepositoryPattern.all,
            BranchPattern.all,
            CommitRule.const_get(type, false).new(c)
          )
        end
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
    include Typedocs::DSL

    tdoc "working_root_dir:String|File -> name:String -> url:String ->"
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

    def update
      raw.git.fetch
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
    include Typedocs::DSL

    tdoc "String -> String ->"
    def initialize(name, url)
      @name, @url = name, url
    end

    attr_reader :name
    attr_reader :url

    attr_accessor :working_repo

    def update
      working_repo.update
    end

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
      Branch.new(self, name)
    end

    tdoc "String -> Commit"
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

    tdoc "String -> String -> Commts"
    def commits_between(from_id, to_id)
      Commits.new(
        working_repo.raw.commits_between(from_id, to_id).map {|c|
          commit(c.id)
        }
      )
    end

    def commit_message_of(id)
      working_repo.raw.commit(id).tap{|c| break (c && c.message)}
    end

    tdoc "String -> Integer -> Commits"
    def recent_commits(branch_name, n)
      Commits.new(
        working_repo.raw.commits("origin/#{branch_name}", n).map {|c|
          commit(c.id)
        }
      )
    end

    tdoc "String -> [Commit...]"
    def commit_parents_of(id)
      working_repo.raw.commit(id).parents.map{|c| self.commit(c.id) }
    end

    private
      def raw_branch(name)
        fullname = "origin/#{name}"
        working_repo.raw.remotes.detect{|ref| ref.name == fullname }
      end
  end

  class Branch
    include Typedocs::DSL
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
    tdoc "Fixnum -> Commits"
    def recent_commits(n)
      repo.recent_commits(name, n)
    end
    def exists?
      repo.branch_exists?(self.name)
    end

    def head
      repo.branch_head_of(self.name)
    end

    def inspect
      "#<#{self.class.name} name=#{name}>"
    end

    include Entity
    def entity_id
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
    include Typedocs::DSL

    tdoc "Repository -> String ->"
    def initialize(repository, id)
      @repo = repository
      @id = id
    end
    attr_reader :id

    tdoc "[Commit...]"
    def parents
      @repo.commit_parents_of(id)
    end

    def message
      @repo.commit_message_of(id)
    end

    def changed_files
      @repo.changed_files_in_commit(id)
    end

    def inspect
      message =
        if @repo.working_repo && self.message
          " message=#{self.message}"
        end
      "#<#{self.class.name} #{@repo.name}:#{id}#{message}>"
    end

    include Entity
    alias entity_id id
  end

  class Commits
    include Typedocs::DSL
    tdoc "[Commit...]->"
    def initialize(commits)
      @commits = Sorter.sort(commits)
    end

    def method_missing(name, *args)
      @commits.public_send(name, *args)
    end

    class Sorter
      include Typedocs::DSL
      tdoc "[Commit...] -> [Commit...]"
      def self.sort(array)
        new(array).tsort
      end
      def initialize(commits)
        @commits = commits
        @commits_by_id = @commits.each_with_object({}){|c,h| h[c.id] = c }
      end
      include TSort
      def tsort_each_node(&b)
        @commits.each(&b)
      end
      def tsort_each_child(commit, &b)
        commit.parents.each do|parent|
          if @commits_by_id[parent.id]
            yield parent
          end
        end
      end
    end
  end

  class ChangedFile
    def initialize(commit, raw_diff)
      parsed = parse_diff(raw_diff.diff)
      @added_lines = parsed[:added_lines]
      @deleted_lines = parsed[:deleted_lines]
      @prev_path =
        if raw_diff.a_blob
          raw_diff.a_path
        else
          nil
        end
      @path = raw_diff.b_path
    end

    attr_reader :prev_path
    attr_reader :path
    attr_reader :added_lines
    attr_reader :deleted_lines

    def new_file?
      # FIXME: Yes, this is works only few environments, but general solution is not known.
      !prev_path
    end

    private
      # raw_diff_str -> { :added_lines|:deleted_lines => [line] }
      def parse_diff(str)
        added = []
        deleted = []
        lines = str.split(/\n/)
        state = :end
        lines.each do|line|
          case line
          when /^--- /, /^\+\+\+ / # path
            next
          when /^@@/ # range
            next
          when /^ / # unchanged line
            next
          when /^\+/
            added << line.sub(/^\+/, '')
          when /^-/
            deleted << line.sub(/^-/, '')
          else
            raise "Unknown diff format: #{line}"
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
      # [[RepositoryPattern, BranchRule]...]
      @branch_rules = []
      # [[[RepositoryPattern, BranchPattern], CommitRule]...]
      @commit_rules = []
    end
    def add_branch_rule(repo_pat, rule)
      nimpl
    end
    def add_commit_rule(repo_pat, branch_pat, rule)
      @commit_rules << [[repo_pat, branch_pat], rule]
    end
    def branch_rules_for(repo)
      nimpl
    end
    def commit_rules_for(branch)
      @commit_rules.select{|(repo_pat, branch_pat),rule|
        repo_pat.match?(branch.repo) && branch_pat.match?(branch)
      }.map{|(rp,bp),r| r}
    end
  end

  class BranchRule
    def extract_branch_events(branch, prev_head)
      nimpl
    end
  end

  class CommitRule
    def initialize(config)
    end
    def extract_commit_events(commit)
      nimpl
    end
    class RubyMethod < self
      def extract_commit_events(commit)
        events = []
        commit.changed_files.
          filter{|cf| cf.path =~ /\.rb$/}.each do|cf|
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
    def self.all
      All.new
    end
    class All < self
      def match?(branch)
        true
      end
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
