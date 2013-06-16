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
    def initialize
      @root = Dir.mktmpdir
      ::SpecHelper.register_cleanup_hook do
        self.close
      end
    end

    def close
      FileUtils.remove_entry_secure(@root)
    end

    def path
      @root
    end

    def exec(*args)
      Dir.chdir(@root) do
        command = args.map(&:to_s)
        success = `#{command.join(' ')}`
        raise "Exit status is nonzero(#{$?}) while executing: #{command.join(' ')}" unless success
      end
    end

  end
end

def new_git_repository
  SpecHelper::GitRepo.new
end

def new_tmp_dir
  tmpdir = Dir.mktmpdir
  SpecHelper.register_cleanup_hook { FileUtils.remove_entry_secure(tmpdir) }
  tmpdir
end
