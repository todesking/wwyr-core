# -*- coding: utf-8 -*-
require "rubygems"
require "bundler/setup"
require 'rspec'

require 'tmpdir'

Dir[File.join(File.dirname(__FILE__), "..", "lib", "**/*.rb")].each{|f| require f }

RSpec.configure do
end


module SpecHelper
  @@cleanup_hooks = []

  def self.register_cleanup_hook(&hook)
    @@cleanup_hooks << hook
  end

  def self.cleanup
    @@cleanup_hooks.reverse.each do|hook|
      begin
        hook.call
      rescue => e
        puts "!!!!!!!!!!!! ERROR on cleanup !!!!!!!!!!!"
        puts e
        puts e.backtrace
      end
    end
    @@cleanup_hooks.clear
  end

  class GitRepo
    def initialize(dir)
      @root = dir
    end

    def path
      @root
    end

    def new_file(name, content)
      path = File.join(@root, name)
      raise "File already exists: #{name}" if File.exists?(path)

      File.open(path, 'w') do|f|
        f.write content
      end
    end

    def modify_file(name, content)
      path = File.join(@root, name)
      raise "File not exists: #{name}" unless File.exists?(path)

      File.open(path, 'w') do|f|
        f.write content
      end
    end

    def git(*args)
      exec(:git, *args)
    end

    def exec(*args)
      out_command_log = ENV['OUT_COMMAND_LOG'].to_i > 0
      Dir.chdir(@root) do
        command = args.map(&:to_s)
        puts "EXECUTING: #{command*' '}" if out_command_log
        out = `#{command.join(' ')}`
        puts out if out_command_log
        raise "Exit status is nonzero(#{$?}) while executing: #{command.join(' ')}\nOUTPUT: #{out}" unless $?.exitstatus == 0
      end
    end

  end
end

def new_tmp_dir
  tmpdir = Dir.mktmpdir
  SpecHelper.register_cleanup_hook { FileUtils.remove_entry_secure(tmpdir) }
  tmpdir
end

def new_git_repository
  SpecHelper::GitRepo.new(new_tmp_dir)
end

def itss(name, &block)
  describe name do
    it { subject.instance_eval(name).instance_eval(&block) }
  end
end
