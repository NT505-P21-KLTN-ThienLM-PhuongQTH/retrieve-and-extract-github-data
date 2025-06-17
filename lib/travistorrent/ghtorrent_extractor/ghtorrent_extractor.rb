#!/usr/bin/env ruby
#

# (c) 2012 -- 2017 Georgios Gousios <gousiosg@gmail.com>
# (c) 2015 -- 2017 Moritz Beller <moritzbeller -AT- gmx.de>

require 'time'
require 'linguist'
require 'thread'
require 'rugged'
require 'parallel'
require 'mongo'
require 'json'
require 'sequel'
require 'optimist'
require 'open-uri'
require 'net/http'
require 'fileutils'
require 'time_difference'

require 'erb'
require 'dotenv'
require_relative "../../csv_helper"

require_relative 'go'
require_relative 'java'
require_relative 'ruby'
require_relative 'python'
require_relative 'javascript'
require_relative 'typescript'
require_relative 'cpp'
require_relative 'csharp'

class GhtorrentExtractor

  REQ_LIMIT = 4990
  THREADS = 2

  attr_accessor :owner, :repo, :token, :all_commits

  class << self
    def run(args = ARGV)
      attr_accessor :options, :args, :name, :config

      command = new()
      command.name = self.class.name
      command.args = args

      command.process_options
      command.validate

      command.config = command.parse_config
      command.go
    end
  end

  def process_options
    #command = self
    @options = Optimist::options do
      banner <<-BANNER
Extract data for builds given a Github repo and a Travis build info file
A minimal Travis build info file should look like this

[
  {
    "build_id":68177642,
    "commit":"92f43dfb416990ce2f530ce29446481fe4641b73",
    "pull_req": null,
    "branch":"master",
    "status":"failed",
    "duration":278,
    "started_at":"2015-06-24 15:  42:17 UTC",
    "jobs":[68177643,68177644,68177645,68177646,68177647,68177648]
  }
]

Travis information contained in dir build_logs, one dir per Github repo

Token is a Github API token required to do API calls

usage:
#{File.basename($0)} owner repo token

      BANNER
      # opt :config, 'config.yaml file location', :short => 'c',
      #     :default => 'config.yaml'
      opt :config, 'config.yaml.erb file location', short: 'c',
          default: File.expand_path('../../../../config.yaml.erb', __FILE__)
      opt :output, 'Output CSV file location', short: 'o',
          default: 'extracted_data.csv'
    end
  end

  def validate
    if options[:config].nil?
      unless File.exist?(File.expand_path('../../../config.yaml.erb', __FILE__))
        Optimist::die "No config file in default location (#{Dir.pwd}). You
                        need to specify the #{:config} parameter."
      end
    else
      Optimist::die "Cannot find file #{options[:config]}" \
          unless File.exists?(options[:config])
    end

    Optimist::die 'Three arguments required' unless !args[1].nil?
  end

  def parse_config
    config_file = @options[:config]
    Dotenv.load(File.join(File.dirname(config_file), 'config', '.env'))
    erb_template = File.read(config_file)
    yaml_content = ERB.new(erb_template).result
    config = YAML.load(yaml_content)
    unless config.is_a?(Hash)
      raise "Invalid config.yaml.erb: Expected a hash, got #{config.class}"
    end
    config
  end

  def db
    Thread.current[:sql_db] ||= Proc.new do
      Sequel.single_threaded = true
      Sequel.connect(self.config['sql']['url'], :encoding => 'utf8')
    end.call
    Thread.current[:sql_db]
  end

  def mongo
    @mongo ||= begin
      uname = config['mongo']['username']
      passwd = config['mongo']['password']
      host = config['mongo']['host']
      port = config['mongo']['port']
      db = config['mongo']['db']

      raise "Missing MongoDB host" if host.nil? || host.strip.empty?
      raise "Missing MongoDB port" if port.nil? || port.to_s.strip.empty?
      raise "Missing MongoDB db name" if db.nil? || db.strip.empty?

      constring = uname ? "mongodb://#{uname}:#{passwd}@#{host}:#{port}/#{db}" : "mongodb://#{host}:#{port}/#{db}"
      puts "[DEBUG] Connecting to MongoDB with URI: #{constring}"
      client = Mongo::Client.new(constring)
      client.database.collection_names # Test kết nối
      log "Connected to MongoDB successfully"
      client
    rescue Mongo::Error => e
      log "MongoDB connection failed: #{e.message}, falling back to GitHub API"
      nil
    end
  end

  def git
    Thread.current[:repo] ||= clone(ARGV[0], ARGV[1])
    Thread.current[:repo]
  end

  # Read a source file from the repo and strip its comments
  # The argument f is the result of Grit.lstree
  # Memoizes result per f
  def semaphore
    @semaphore ||= Mutex.new
    @semaphore
  end

  # def load_builds(owner, repo)
  #   f = File.join("build_logs", "#{owner}@#{repo}", "repo-data-travis.json")
  #   unless File.exists? f
  #     Optimist::die "Build file (#{f}) does not exist"
  #   end

  #   JSON.parse File.open(f).read, :symbolize_names => true
  # end

  # Load a commit from Github. Will return an empty hash if the commit does not exist.
  def github_commit(owner, repo, sha)
    parent_dir = File.join('commits', "#{owner}@#{repo}")
    commit_json = File.join(parent_dir, "#{sha}.json")
    FileUtils::mkdir_p(parent_dir)

    r = nil
    if File.exists? commit_json
      r = begin
        JSON.parse File.open(commit_json).read
      rescue
        # This means that the retrieval operation resulted in no commit being retrieved
        {}
      end
      return r
    end

    url = "https://api.github.com/repos/#{owner}/#{repo}/commits/#{sha}"
    log("Requesting #{url} (#{@remaining} remaining)")

    contents = nil
    begin
      r = open(url, 'User-Agent' => 'ghtorrent', 'Authorization' => "token #{token}")
      @remaining = r.meta['x-ratelimit-remaining'].to_i
      @reset = r.meta['x-ratelimit-reset'].to_i
      contents = r.read
      JSON.parse contents
    rescue OpenURI::HTTPError => e
      @remaining = e.io.meta['x-ratelimit-remaining'].to_i
      @reset = e.io.meta['x-ratelimit-reset'].to_i
      log "Cannot get #{url}. Error #{e.io.status[0].to_i}"
      {}
    rescue StandardError => e
      log "Cannot get #{url}. General error: #{e.message}"
      {}
    ensure
      File.open(commit_json, 'w') do |f|
        f.write contents unless r.nil?
        f.write '' if r.nil?
      end

      if 5000 - @remaining >= REQ_LIMIT
        to_sleep = @reset - Time.now.to_i + 2
        log "Request limit reached, sleeping for #{to_sleep} secs"
        sleep(to_sleep)
      end
    end
  end

  def log(msg, level = 0, type = :general)
    max_length = 1000
    msg = msg.to_s[0...max_length] + '...' if msg.to_s.length > max_length
    semaphore.synchronize do
      (0..level).each { STDERR.print ' ' }
      STDERR.puts "[#{type.upcase}] #{msg}"
    end
  end


  
  # Main command code
  def go
    mongo
    interrupted = false

    trap('INT') {
      log "#{File.basename($0)}(#{Process.pid}): Received SIGINT, exiting"
      interrupted = true
    }

    self.owner = ARGV[0]
    self.repo = ARGV[1]
    self.token = ARGV[2]

    user_entry = db[:users].first(:login => owner)

    if user_entry.nil?
      Optimist::die "Cannot find user #{owner}"
    end

    # repo_entry = db.from(:projects, :users).\
    #               where(:users__id => :projects__owner_id).\
    #               where(:users__login => owner).\
    #               where(:projects__name => repo).\
    #               select(:projects__id, :projects__language).\
    #               first
    repo_entry = db.from(:projects, :users)
                .where(Sequel[:users][:id] => Sequel[:projects][:owner_id])
                .where(Sequel[:users][:login] => owner)
                .where(Sequel[:projects][:name] => repo)
                .select(
                  Sequel[:projects][:id],
                  Sequel[:projects][:language]
                )
                .first

    if repo_entry.nil?
      log "Cannot find repository #{owner}/#{repo} in projects table", 1, :error
      Optimist::die "Cannot find repository #{owner}/#{repo}"
    end
    log "Found repository #{owner}/#{repo} with project_id=#{repo_entry[:id]}, language=#{repo_entry[:language]}", 1, :general
    
    language = repo_entry[:language]&.downcase || "unknown"

    case language
    when /javascript/i
      self.extend(JavaScriptData)
    when /typescript/i
      self.extend(TypeScriptData)
    when /c\+\+/i
      self.extend(CppData)
    when /c#/i
      self.extend(CSharpData)
    when /go/i
      self.extend(GoData)
    when /java/i
      self.extend(JavaData)
    when /python/i
      self.extend(PythonData)
    when /ruby/i
      self.extend(RubyData)
    else
      log "Language #{language} not supported, defaulting to JavaScript"
      self.extend(JavaScriptData)
    end

    # Update the repo
    clone(owner, repo, true)

    # log 'Retrieving all commits'
    # walker = Rugged::Walker.new(git)
    # walker.sorting(Rugged::SORT_DATE)
    # walker.push(git.head.target)
    # self.all_commits = walker.map { |commit| commit.oid[0..10] }
    # log "#{all_commits.size} commits to process"

    # Get commits that close issues/pull requests
    # Index them by issue/pullreq id, as a sha might close multiple issues
    # see: https://help.github.com/articles/closing-issues-via-commit-messages
    # q = "SELECT c.sha FROM commits c, project_commits pc WHERE pc.project_id = ? AND pc.commit_id = c.id"
    # commits = db.fetch(q, repo_entry[:id]).all

    # results = Parallel.map(commits, in_threads: THREADS) do |c|
    #   process_commit(c[:sha], owner, repo, language, repo_entry[:id])
    # end.select { |x| !x.nil? }

    log "Retrieving all workflow runs for #{owner}/#{repo}"
    workflow_runs = db.fetch(<<-SQL).all
      SELECT wr.*
      FROM workflow_runs wr
      INNER JOIN (
        SELECT head_branch, head_sha, MAX(run_started_at) AS max_run_started_at
        FROM workflow_runs
        WHERE project_id = #{repo_entry[:id]}
        GROUP BY head_branch, head_sha
      ) latest ON wr.head_branch = latest.head_branch
              AND wr.head_sha = latest.head_sha
              AND wr.run_started_at = latest.max_run_started_at
      WHERE wr.project_id = #{repo_entry[:id]}
    SQL
    log "#{workflow_runs.size} latest workflow runs to process"

    results = Parallel.map(workflow_runs, in_threads: THREADS) do |run|
      process_workflow_run(run, owner, repo, language, repo_entry[:id]) unless interrupted
    end.select { |x| !x.nil? }

    if results.empty?
      log "No data extracted!"
      return { status: :error, message: "No data extracted for #{owner}/#{repo}" }
    else
      # puts results.first.keys.map(&:to_s).join(',')
      # results.each { |r| puts r.values.join(',') }
      # File.write(@options[:output], array_of_hashes_to_csv(results.map { |r| r.transform_keys(&:to_s) }))
      # log "Results written to #{@options[:output]}"
      inserted_count = 0
      skipped_count = 0
      # results.each do |result|
      #   # Check if the record already exists in MongoDB
      #   existing = mongo[:ci_builds].find(
      #     gh_project_name: result[:gh_project_name],
      #     git_all_built_commits: result[:git_all_built_commits],
      #     git_branch: result[:git_branch]
      #   ).first

      #   if existing
      #     log "Skipping duplicate record for #{result[:gh_project_name]}, commit #{result[:git_all_built_commits]}, branch #{result[:git_branch]}", 1, :mongo
      #     skipped_count += 1
      #     next
      #   end

      #   begin
      #     mongo[:ci_builds].insert_one(result)
      #     inserted_count += 1
      #   rescue Mongo::Error => e
      #     log "Failed to insert record for #{result[:gh_project_name]}, commit #{result[:git_all_built_commits]}: #{e.message}", 1, :mongo
      #   end
      results.each do |result|
        begin
          mongo[:ci_builds].update_one(
            {
              gh_project_name: result[:gh_project_name],
              git_all_built_commits: result[:git_all_built_commits],
              git_branch: result[:git_branch]
            },
            { "$set" => result },
            upsert: true
          )
          inserted_count += 1
        rescue Mongo::Error => e
          log "Failed to upsert record for #{result[:gh_project_name]}, commit #{result[:git_all_built_commits]}: #{e.message}", 1, :mongo
        end
      end
      
      log "Upserted #{inserted_count} records to MongoDB ghtorrent.ci_builds", 1, :mongo
      # log "Saved #{inserted_count} records, skipped #{skipped_count} duplicates to MongoDB ghtorrent.ci_builds", 1, :mongo
      if inserted_count > 0
        { status: :success, message: "Extracted and saved #{inserted_count} records, skipped #{skipped_count} duplicates for #{owner}/#{repo}" }
      else
        { status: :success, message: "No new records saved, skipped #{skipped_count} duplicates for #{owner}/#{repo}" }
      end
    end

  end

  def calculate_time_difference(walker, trigger_commit)
    begin
      latest_commit_time = git.lookup(trigger_commit).time
      first_commit_time = walker.take(1).first.time
      age = TimeDifference.between(latest_commit_time, first_commit_time).in_days
    rescue => e
      log "Exception on time difference processing commit #{tigger_commit}: #{e.message}"
      log e.backtrace
      age = 0
    ensure
      return age
    end
  end

  def calculate_number_of_commits(trigger_commit)
    begin
      walker = Rugged::Walker.new(git)
      walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_DATE | Rugged::SORT_REVERSE)
      walker.push(trigger_commit)
      num_commits = walker.count
      num_commits = 1 if num_commits.zero?
    rescue => e
      log "Exception on commit numbers processing commit #{tigger_commit}: #{e.message}"
      log e.backtrace
      num_commits = 1
    end
    num_commits
  end

  def calculate_confounds(trigger_commit)
    begin
      walker = Rugged::Walker.new(git)
      walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_DATE | Rugged::SORT_REVERSE)
      walker.push(trigger_commit)

      age = calculate_time_difference(walker, trigger_commit)
      num_commits = calculate_number_of_commits(trigger_commit)
    ensure
      return {
          :repo_age => age,
          :repo_num_commits => num_commits
      }
    end
  end

  # Process a single build
  # def process_commit(sha, owner, repo, lang, repo_id)
  #   include_module = case lang.downcase
  #                     when 'javascript' then JavaScriptData
  #                     when 'typescript' then TypeScriptData
  #                     when 'c++' then CppData
  #                     when 'c#' then CSharpData
  #                     when 'go' then GoData
  #                     when 'java' then JavaData
  #                     when 'python' then PythonData
  #                     when 'ruby' then RubyData
  #                     else JavaScriptData
  #                     end
  #   extend include_module
  #   commit = mongo&.[]('commits')&.find({ 'sha' => sha }).limit(1).first
  #   # return nil if commit.nil? || commit.empty?
  #   log "Commit for SHA #{sha}: #{commit.inspect}"

  #   if commit.nil? || commit.empty?
  #     git_commit = git.lookup(sha)
  #     commit = {
  #       'commit' => {
  #         'author' => { 'email' => git_commit.author[:email] },
  #         'committer' => { 'date' => git_commit.author[:time].to_s }
  #       },
  #       'sha' => sha
  #     }
  #   end

  #   # Count number of src/comment lines
  #   sloc = src_lines(sha)
  #   log "Computed sloc for #{sha}: #{sloc}", 1, :commit
  #   months_back = 3

  #   branches = git.branches.each_name(:local).select { |b| git.branches[b].target_id == sha }
  #   branch = branches.first
  #   unless branch
  #     begin
  #       branch = `git -C #{File.join('repos', owner, repo)} rev-parse --abbrev-ref HEAD`.strip
  #     rescue
  #       branch = 'unknown'
  #     end
  #   end
  #   stats = calc_build_stats(owner, repo, [sha])
  #   confounds = calculate_confounds(sha)
  #   pr_info = pr_info_for_commit(sha, repo_id)

  #   result = {
  #       # [doc] The branch that was built
  #       :git_branch => branch || commit.dig('commit', 'branch'),

  #       # [doc] A list of all commits that were built for this build, up to but excluding the commit of the previous
  #       # build, or up to and including a merge commit (in which case we cannot go further backward).
  #       # The internal calculation starts with the parent for PR builds or the actual
  #       # built commit for non-PR builds, traverse the parent commits up until a commit that is linked to a previous
  #       # build is found (excluded, this is under `tr_prev_built_commit`) or until we cannot go any further because a
  #       # branch point was reached. This is indicated in `git_prev_commit_resolution_status`. This list is what
  #       # the `git_diff_*` fields are calculated upon.
  #       :git_all_built_commits => sha,

  #       # [doc] Number of `git_all_built_commits`.
  #       :git_num_all_built_commits => 1,

  #       # [doc] The commit that triggered the build.
  #       :git_trigger_commit => sha,

  #       # [doc] The emails of the committers of the commits in all `git_all_built_commits`.
  #       :git_diff_committers => commit.dig('commit', 'author', 'email'),

  #       # [doc] Number of lines of production code changed in all `git_all_built_commits`.
  #       :git_diff_src_churn => stats[:lines_added].to_i + stats[:lines_deleted].to_i,

  #       # [doc] Number of lines of test code changed in all `git_all_built_commits`.
  #       :git_diff_test_churn => stats[:test_lines_added].to_i + stats[:test_lines_deleted].to_i,

  #       # [doc] Project name on GitHub.
  #       :gh_project_name => "#{owner}/#{repo}",

  #       # [doc] Whether this build was triggered as part of a pull request on GitHub.
  #       :gh_is_pr => pr_info[:is_pr],

  #       # [doc] If the build is a pull request, the creation timestamp for this pull request, in UTC.
  #       :gh_pr_created_at => pr_info[:created_at],

  #       # [doc] Dominant repository language, according to GitHub.
  #       :gh_lang => lang,

  #       # [doc] Number of developers that committed directly or merged PRs from the moment the build was triggered and 3 months back.
  #       :gh_team_size => main_team(owner, repo, sha, months_back).size,

  #       # [doc] If git_commit is linked to a PR on GitHub, the number of discussion comments on that PR.
  #       :gh_num_issue_comments => num_issue_comments(pr_info[:pr_id], pr_info[:created_at], commit['commit']['committer']['date']),
        
  #       # [doc] If gh_is_pr is true, the number of comments (code review) on this pull request on GitHub.
  #       :gh_num_pr_comments => num_pr_comments(pr_info[:pr_id], pr_info[:created_at], commit['commit']['committer']['date']),

  #       # [doc] The number of comments on `git_all_built_commits` on GitHub.
  #       :gh_num_commit_comments => num_commit_comments(owner, repo, [sha]),

  #       # [doc] Number of files added by all `git_all_built_commits`.
  #       :gh_diff_files_added => stats[:files_added],

  #       # [doc] Number of files deleted by all `git_all_built_commits`.
  #       :gh_diff_files_deleted => stats[:files_removed],

  #       # [doc] Number of files modified by all `git_all_built_commits`.
  #       :gh_diff_files_modified => stats[:files_modified],

  #       # [doc] Number of test cases added by `git_all_built_commits`.
  #       :gh_diff_tests_added => test_diff_stats(sha, sha)[:tests_added],

  #       # [doc] Number of test cases deleted by `git_all_built_commits`.
  #       :gh_diff_tests_deleted => test_diff_stats(sha, sha)[:tests_deleted],

  #       # [doc] Number of src files changed by all `git_all_built_commits`.
  #       :gh_diff_src_files => stats[:src_files],

  #       # [doc] Number of documentation files changed by all `git_all_built_commits`.
  #       :gh_diff_doc_files => stats[:doc_files],

  #       # [doc] Number of files which are neither source code nor documentation that changed by the commits that where built.
  #       :gh_diff_other_files => stats[:other_files],

  #       # [doc] Number of unique commits on the files touched in the commits (`git_all_built_commits`) that triggered the
  #       # build from the moment the build was triggered and 3 months back. It is a metric of how active the part of
  #       # the project is that these commits touched.
  #       :gh_num_commits_on_files_touched => commits_on_files_touched(owner, repo, sha, months_back),

  #       # [doc] Number of executable production source lines of code, in the entire repository.
  #       :gh_sloc => sloc,

  #       # [doc] Overall number of test code lines.
  #       :gh_test_lines_per_kloc => test_lines(sha).to_f,

  #       # [doc] Overall number of test cases.
  #       :gh_test_cases_per_kloc => num_test_cases(sha).to_f,

  #       # [doc] Overall number of assertions.
  #       :gh_asserts_cases_per_kloc => num_assertions(sha).to_f,

  #       # [doc] Whether this commit was authored by a core team member. A core team member is someone who has committed
  #       # code at least once within the 3 months before this commit, either by directly committing it or by merging
  #       # commits.
  #       :gh_by_core_team_member => by_core_team_member?(commit, owner, repo),

  #       # # [doc] Timestamp of the push that triggered the build (GitHub provided), in UTC.
  #       # :gh_pushed_at => pushed_at(sha, commit),

  #       # [doc] Age of the repository, from the latest commit to its first commit, in days
  #       :gh_repo_age => confounds[:repo_age],

  #       # [doc] Number of commits in the repository
  #       :gh_repo_num_commits => confounds[:repo_num_commits]
  #   }
  #   log "Processed commit #{sha}: src_churn=#{result[:git_diff_src_churn]}, src_files=#{result[:gh_diff_src_files]}, sloc=#{result[:gh_sloc]}, num_commits=#{result[:gh_repo_num_commits]}", 1, :commit
  #   result
  # end

  def process_workflow_run(run, owner, repo, lang, repo_id)
    include_module = case lang.downcase
                    when 'javascript' then JavaScriptData
                    when 'typescript' then TypeScriptData
                    when 'c++' then CppData
                    when 'c#' then CSharpData
                    when 'go' then GoData
                    when 'java' then JavaData
                    when 'python' then PythonData
                    when 'ruby' then RubyData
                    else JavaScriptData
                    end
    extend include_module
    sha = run[:head_sha]
    commit = db[:commits].where(:sha => sha).first
    log "Commit for SHA #{sha}: #{commit.inspect}"
    github_run_id = run[:github_id].to_i
    log "GitHub run ID from DB: #{github_run_id}"
    if commit.nil? || commit.empty?
      begin
        git_commit = git.lookup(sha)
        author_email = git_commit.author[:email]
        author_login = github_login(author_email)
        commit = {
          'commit' => {
            'author' => { 'email' => author_email, 'id' => author_login },
            'committer' => { 'date' => git_commit.author[:time].to_s }
          },
          :sha => sha,
          :author_id => author_login,
          :created_at => git_commit.author[:time].to_s
        }
      rescue
        log "Cannot find commit #{sha} in repository, skipping run #{run[:github_id]}"
        return nil
      end
    else
      begin
        git.lookup(sha) # Kiểm tra commit trong Git
      rescue
        log "Commit #{sha} in commits table but not in Git, skipping run #{run[:github_id]}"
        return nil
      end
    end
    # Calculate build duration (in seconds)
    run_started_at = run[:run_started_at]
    updated_at = run[:updated_at]
    build_duration = ((updated_at - run_started_at)).to_i # Convert to seconds
    if build_duration < 0 || build_duration > 86_400 # 24 hours
      log "Invalid build_duration #{build_duration}s for run #{run[:github_id]} (started: #{run_started_at}, updated: #{updated_at}), setting to 0"
      build_duration = 0
    end

    # Map conclusion to build_failed
    build_failed = case run[:conclusion]
                  when 'success' then 'passed'
                  when 'failure' then 'failed'
                  else 'others'
                  end

    # Format gh_build_started_at
    gh_build_started_at = run_started_at.strftime('%m/%d/%Y %H:%M:%S')

    # Count number of src/comment lines
    sloc = src_lines(sha)
    log "Computed sloc for #{sha}: #{sloc}", 1, :commit
    months_back = 3
  
    # Use head_branch from workflow run
    branch = run[:head_branch] || 'unknown'

    stats = calc_build_stats(owner, repo, [sha])
    confounds = calculate_confounds(sha)
    pr_info = pr_info_for_commit(sha, repo_id)

    result = {
      # Branch from workflow run
      :git_branch => branch,
  
      # Commit that triggered the workflow run
      :git_all_built_commits => sha,
      :git_num_all_built_commits => 1,
      :git_trigger_commit => sha,
      # :git_diff_committers => commit['commit']&.dig('author', 'email') || commit[:email],
      :git_diff_src_churn => stats[:lines_added].to_i + stats[:lines_deleted].to_i,
      :git_diff_test_churn => stats[:test_lines_added].to_i + stats[:test_lines_deleted].to_i,
  
      # Project and PR info
      :gh_project_name => "#{owner}/#{repo}",
      :gh_is_pr => pr_info[:is_pr],
      # :gh_pr_created_at => pr_info[:created_at],
      :gh_lang => lang,
      :gh_team_size => main_team(owner, repo, sha, months_back).size,
      :gh_num_issue_comments => num_issue_comments(pr_info[:pr_id], pr_info[:created_at], commit[:created_at] || commit['commit']&.dig('committer', 'date')),
      :gh_num_pr_comments => num_pr_comments(pr_info[:pr_id], pr_info[:created_at], commit[:created_at] || commit['commit']&.dig('committer', 'date')),
      :gh_num_commit_comments => num_commit_comments(owner, repo, [sha]),
  
      # File stats
      :gh_diff_files_added => stats[:files_added],
      :gh_diff_files_deleted => stats[:files_removed],
      :gh_diff_files_modified => stats[:files_modified],
      :gh_diff_tests_added => test_diff_stats(sha, sha)[:tests_added],
      :gh_diff_tests_deleted => test_diff_stats(sha, sha)[:tests_deleted],
      :gh_diff_src_files => stats[:src_files],
      :gh_diff_doc_files => stats[:doc_files],
      :gh_diff_other_files => stats[:other_files],
  
      # Other metrics
      :gh_num_commits_on_files_touched => commits_on_files_touched(owner, repo, sha, months_back),
      :gh_sloc => sloc,
      :gh_test_lines_per_kloc => test_lines(sha).to_f,
      :gh_test_cases_per_kloc => num_test_cases(sha).to_f,
      :gh_asserts_cases_per_kloc => num_assertions(sha).to_f,
      :gh_by_core_team_member => by_core_team_member?(commit, owner, repo, months_back),
      :gh_repo_age => confounds[:repo_age],
      :gh_repo_num_commits => confounds[:repo_num_commits],
  
      # build info
      :build_duration => build_duration,
      :build_failed => build_failed,
      :gh_build_started_at => gh_build_started_at,
      :github_run_id => github_run_id
    }
    log "Processed workflow run #{run[:github_id]}: build_duration=#{build_duration}s, build_failed=#{build_failed}, sloc=#{sloc}", 1, :workflow_run
    result
  end

  def pr_info_for_commit(sha, repo_id)
    q = <<-QUERY
    SELECT pr.id AS pr_id, prh.created_at
    FROM pull_request_commits prc, commits c, pull_requests pr, pull_request_history prh
    WHERE prc.commit_id = c.id
      AND c.sha = ?
      AND prc.pull_request_id = pr.id
      AND pr.base_repo_id = ?
      AND prh.pull_request_id = pr.id
      AND prh.action = 'opened'
    LIMIT 1
    QUERY
    result = db.fetch(q, sha, repo_id).first
    {
      is_pr: !result.nil?,
      pr_id: result&.[](:pr_id),
      created_at: result&.[](:created_at)
    }
  end

  # Number of pull request code review comments in pull request
  def num_pr_comments(pr_id, from, to)
    return 0 unless pr_id

    q = <<-QUERY
    select count(*) as comment_count
    from pull_request_comments prc
    where prc.pull_request_id = ?
    and prc.created_at between timestamp(?) and timestamp(?)
    QUERY
    db.fetch(q, pr_id, from, to).first[:comment_count]
  end

  # Number of pull request discussion comments
  def num_issue_comments(pr_id, from, to)
    return 0 unless pr_id

    q = <<-QUERY
    select count(*) as issue_comment_count
    from pull_requests pr, issue_comments ic, issues i
    where ic.issue_id=i.id
    and i.issue_id=pr.pullreq_id
    and pr.base_repo_id = i.repo_id
    and pr.id = ?
    and ic.created_at between timestamp(?) and timestamp(?)
    QUERY
    db.fetch(q, pr_id, from, to).first[:issue_comment_count]
  end

  # def pushed_at(sha, commit)
  #   if mongo
  #     event = mongo['events'].find(
  #       {
  #         'repo.name' => "#{owner}/#{repo}",
  #         'type' => { '$in' => ['PushEvent', 'CreateEvent'] },
  #         'payload.commits.sha' => sha
  #       },
  #       sort: { 'created_at' => 1 },
  #       limit: 1
  #     ).first
  #     return event&.dig('created_at') if event
  #   end
  #   commit.dig('commit', 'committer', 'date') || git.lookup(sha).committer[:time].to_s
  # end

  def commit_fallback(sha)
    commit = github_commit(owner, repo, sha)
    commit.dig('commit', 'committer', 'date')
  end

  # Number of commit comments on commits between builds in the same branch
  def num_commit_comments(owner, repo, commits)
    commits.map do |sha|
      q = <<-QUERY
      select count(*) as commit_comment_count
      from project_commits pc, projects p, users u, commit_comments cc, commits c
      where pc.commit_id = cc.commit_id
        and p.id = pc.project_id
        and c.id = pc.commit_id
        and p.owner_id = u.id
        and u.login = ?
        and p.name = ?
        and c.sha = ?
      QUERY
      db.fetch(q, owner, repo, sha).first[:commit_comment_count]
    end.reduce(0) { |acc, x| acc + x }
  end

  # Number of integrators active during x months prior to pull request
  # creation.
  def main_team(owner, repo, sha, months_back)
    commit_time = begin
      git.lookup(sha).time
    rescue
      log "Commit #{sha} not found in Git, using commits.created_at", 1, :commit
      commit = db[:commits].where(:sha => sha).first
      commit ? commit[:created_at] : Time.now
    end
    q = <<-QUERY
    SELECT DISTINCT u1.login
    FROM commits c
    JOIN project_commits pc ON pc.commit_id = c.id
    JOIN users u ON u.login = ?
    JOIN projects p ON p.id = pc.project_id AND p.name = ? AND p.owner_id = u.id
    JOIN users u1 ON c.author_id = u1.id
    WHERE c.created_at BETWEEN DATE_SUB(?, INTERVAL #{months_back} MONTH) AND ?
    AND u1.fake IS FALSE
    QUERY
    logins = db.fetch(q, owner, repo, commit_time, commit_time).map { |r| r[:login] }.uniq
    log "Fetched main team for #{owner}/#{repo} (commit #{sha}, #{months_back} months): #{logins.inspect}", 2, :commit
    logins
  end

  def by_core_team_member?(commit, owner, repo, months_back)
    # author = commit.dig('commit', 'author', 'email')
    # months_back = 3
    # main_team = main_team(owner, repo, commit['sha'], months_back)
    # github_login(author)&.in?(main_team)

    author_id = commit[:author_id] || commit['commit']&.dig('author', 'id')
    author_login = github_login_by_id(author_id)
    main_team = main_team(owner, repo, commit[:sha], months_back)
    result = author_login.in?(main_team)
    log "Core team member check for #{author_login}: #{result}", 2, :commit
    result
  end

  def github_login_by_id(author_id)
    return nil unless author_id
  
    q = <<-QUERY
    SELECT login
    FROM users
    WHERE id = ?
    AND fake IS FALSE
    QUERY
    result = db.fetch(q, author_id).first
    login = result[:login] if result
    log "Queried login for author_id #{author_id}: #{login || 'not found'}", 2, :commit
    login
  end

  # Various statistics for the build. Returned as Hash with the following
  # keys: :lines_added, :lines_deleted, :files_added, :files_removed,
  # :files_modified, :files_touched, :src_files, :doc_files, :other_files.
  def calc_build_stats(owner, repo, commits)
    raw_commits = commit_entries(owner, repo, commits)
    result = Hash.new(0)
    file_types = {} # Cache kết quả phân loại
  
    def file_count(commits, status)
      commits.map do |c|
        c['files'].reduce([]) do |acc, y|
          acc << y['filename'] if y['status'] == status
          acc
        end
      end.flatten.uniq.size
    end
  
    def files_touched(commits)
      commits.map do |c|
        c['files'].map { |y| y['filename'] }
      end.flatten.uniq.size
    end
  
    def file_type(f, file_types)
      return file_types[f] if file_types.key?(f)
      lang = Linguist::Language.find_by_filename(f)
      type = if lang.empty?
               extension = File.extname(f).downcase
               programming_extensions = ['.js', '.jsx', '.ts', '.tsx', '.cpp', '.cxx', '.cc', '.h', '.hpp', '.cs']
               programming_extensions.include?(extension) ? :programming : :data
             else
               lang[0].type
             end
      log "File #{f} classified as #{type}#{lang.empty? ? ' (fallback based on extension)' : " (language: #{lang[0].name})"}", 1, :file
      file_types[f] = type
      type
    end
  
    def file_type_count(commits, type, file_types)
      commits.map do |c|
        log "Files in commit: #{c['files'].map { |y| y['filename'] }.join(', ')}", 1, :file
        c['files'].reduce([]) do |acc, y|
          acc << y['filename'] if file_type(y['filename'], file_types) == type
          acc
        end
      end.flatten.uniq.size
    end
  
    def lines(commit, type, action, file_types)
      commit['files'].select do |x|
        next unless file_type(x['filename'], file_types) == :programming
        case type
        when :test
          test_file_filter.call(x['filename'])
        when :src
          !test_file_filter.call(x['filename'])
        else
          false
        end
      end.reduce(0) do |acc, y|
        diff_start = action == :added ? "+" : "-"
        count = y['patch']&.lines&.select { |x| x.start_with?(diff_start) }&.size || 0
        log "Calculating #{action} lines for #{y['filename']}: #{count}", 2, :file unless y['filename'].match?(/\.json$|\.lock$/)
        acc + count
      end
    end
  
    raw_commits.each do |x|
      next if x.nil?
      log "Processing commit #{x['sha']}, files: #{x['files']&.map { |f| f['filename'] }&.join(', ') || 'none'}", 0, :commit
      result[:lines_added] += lines(x, :src, :added, file_types)
      result[:lines_deleted] += lines(x, :src, :deleted, file_types)
      result[:test_lines_added] += lines(x, :test, :added, file_types)
      result[:test_lines_deleted] += lines(x, :test, :deleted, file_types)
    end
  
    result[:files_added] = file_count(raw_commits, "added")
    result[:files_removed] = file_count(raw_commits, "removed")
    result[:files_modified] = file_count(raw_commits, "modified")
    result[:files_touched] = files_touched(raw_commits)
    result[:src_files] = file_type_count(raw_commits, :programming, file_types)
    result[:doc_files] = file_type_count(raw_commits, :markup, file_types)
    result[:other_files] = file_type_count(raw_commits, :data, file_types)
  
    log "Build stats for #{commits.join(', ')}: #{result.inspect}", 1, :commit
    result
  end


  def test_diff_stats(start_sha, end_sha)
    begin
      start_commit = git.lookup(start_sha)
      end_commit = git.lookup(end_sha)
      diff = git.diff(start_commit, end_commit)
      tests_added = 0
      tests_deleted = 0
      diff.each_patch do |patch|
        file = patch.delta.new_file[:path]
        next unless test_file?(file)
        patch.each_hunk do |hunk|
          hunk.each_line do |line|
            case line.line_origin
            when :addition
              tests_added += 1 if test_line?(line.content)
            when :deletion
              tests_deleted += 1 if test_line?(line.content)
            end
          end
        end
      end
      { tests_added: tests_added, tests_deleted: tests_deleted }
    rescue Rugged::OdbError
      log "Cannot find commit #{start_sha} or #{end_sha} in Git, returning zero test stats", 1, :commit
      { tests_added: 0, tests_deleted: 0 }
    end
  end

  # Number of unique commits on the files changed by the build commits
  # between the time the build was created and `months_back`
  def commits_on_files_touched(owner, repo, sha, months_back)
    commit = git.lookup(sha)
    oldest = Time.at(commit.time.to_i - 3600 * 24 * 30 * months_back)
    
    # Get the diff for the commit
    diff = commit.diff
    files = []
    diff.each_patch do |patch|
      files << patch.delta.old_file[:path] # Old file
      files << patch.delta.new_file[:path] # New file (if renamed/moved)
    end
    files.uniq! # Remove duplicates
    log "Files touched in #{sha}: #{files.join(', ')}"
    
    # Search for commits in the repository that modified the files
    walker = Rugged::Walker.new(git)
    walker.sorting(Rugged::SORT_DATE)
    walker.push(sha)
    walker.take_while { |c| c.time > oldest }
          .select { |c| c.diff(paths: files).size > 0 }
          .map(&:oid)
          .uniq
          .size
    end

  def github_login(email)
    q = <<-QUERY
    select u.login as login
    from users u
    where u.email = ?
    and u.fake is false
    QUERY
    l = db.fetch(q, email).first
    l.nil? ? nil : l[:login]
  end

  # JSON objects for the commits included in the pull request
  def commit_entries(owner, repo, shas)
    shas.reduce([]) { |acc, x|
      a = mongo['commits'].find({:sha => x}).limit(1).first

      if a.nil?
        a = github_commit(owner, repo, x)
      end

      acc << a unless a.nil? or a.empty?
      acc
    }.select { |c| c['parents'] }
  end

  # Recursively get information from all files given a rugged Git tree
  def lslr(tree, path = '')
    all_files = []
    for f in tree.map { |x| x }
      f[:path] = path + '/' + f[:name]
      if f[:type] == :tree
        begin
          all_files << lslr(git.lookup(f[:oid]), f[:path])
        rescue StandardError => e
          log e
          all_files
        end
      else
        all_files << f
      end
    end
    all_files.flatten
  end


  # List of files in a project checkout. Filter is an optional binary function
  # that takes a file entry and decides whether to include it in the result.
  def files_at_commit(sha, filter = lambda { true })

    begin
      files = lslr(git.lookup(sha).tree)
      if files.size <= 0
        log "No files for commit #{sha}"
      end
      files.select { |x| filter.call(x) }
    rescue StandardError => e
      log "Cannot find commit #{sha} in base repo"
      []
    end
  end

  # Clone or update, if already cloned, a git repository
  def clone(user, repo, update = false)

    def spawn(cmd)
      proc = IO.popen(cmd, 'r')

      proc_out = Thread.new {
        while !proc.eof
          log "GIT: #{proc.gets}"
        end
      }

      proc_out.join
    end

    checkout_dir = File.join('repos', user, repo)

    begin
      repo = Rugged::Repository.new(checkout_dir)
      if update
        system("cd #{checkout_dir} && git pull")
      end
      repo
    rescue
      system("git clone https://github.com/#{user}/#{repo}.git #{checkout_dir}")
      Rugged::Repository.new(checkout_dir)
      puts "Clone done."
    end
  end

  def stripped(f)
    @stripped ||= Hash.new
    unless @stripped.has_key? f
      semaphore.synchronize do
        unless @stripped.has_key? f
          @stripped[f] = strip_comments(git.read(f[:oid]).data)
        end
      end
    end
    @stripped[f]
  end

  def count_lines(files, include_filter = lambda { |x| true })
    files.map { |f|
      stripped(f).lines.select { |x|
        not x.strip.empty?
      }.select { |x|
        include_filter.call(x)
      }.size
    }.reduce(0) { |acc, x| acc + x }
  end

  def src_files(sha)
    files_at_commit(sha, src_file_filter)
  end

  def src_lines(sha)
    count_lines(src_files(sha))
  end

  def test_files(sha)
    files_at_commit(sha, test_file_filter)
  end

  def test_lines(sha)
    count_lines(test_files(sha))
  end

  def num_test_cases(sha)
    count_lines(test_files(sha), test_case_filter)
  end

  def num_assertions(sha)
    count_lines(test_files(sha), assertion_filter)
  end

  # Return a f: filename -> Boolean, that determines whether a
  # filename is a test file
  def test_file_filter
    raise Exception.new("Unimplemented")
  end

  # Return a f: filename -> Boolean, that determines whether a
  # filename is a src file
  def src_file_filter
    raise Exception.new("Unimplemented")
  end

  # Return a f: buff -> Boolean, that determines whether a
  # line represents a test case declaration
  def test_case_filter
    raise Exception.new("Unimplemented")
  end

  # Return a f: buff -> Boolean, that determines whether a
  # line represents an assertion
  def assertion_filter
    raise Exception.new("Unimplemented")
  end

  def strip_comments(buff)
    raise Exception.new("Unimplemented")
  end

end

#vim: set filetype=ruby expandtab tabstop=2 shiftwidth=2 autoindent smartindent:
