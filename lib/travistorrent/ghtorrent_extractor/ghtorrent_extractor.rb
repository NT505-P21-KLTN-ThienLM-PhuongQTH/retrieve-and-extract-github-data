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

require_relative 'go'
require_relative 'java'
require_relative 'ruby'
require_relative 'python'


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

      command.config = YAML::load_file command.options[:config]
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
      opt :config, 'config.yaml file location', :short => 'c',
          :default => 'config.yaml'
    end
  end

  def validate
    if options[:config].nil?
      unless file_exists?("config.yaml")
        Optimist::die "No config file in default location (#{Dir.pwd}). You
                        need to specify the #{:config} parameter."
      end
    else
      Optimist::die "Cannot find file #{options[:config]}" \
          unless File.exists?(options[:config])
    end

    Optimist::die 'Three arguments required' unless !args[1].nil?
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
      constring = uname ? "mongodb://#{uname}:#{passwd}@#{host}:#{port}/#{db}" : "mongodb://#{host}:#{port}/#{db}"
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

  def log(msg, level = 0)
    semaphore.synchronize do
      (0..level).each { STDERR.write ' ' }
      STDERR.puts msg
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
      Optimist::die "Cannot find repository #{owner}/#{repo}"
    end

    language = repo_entry[:language].downcase

    case language
      when /ruby/i then
        self.extend(RubyData)
      when /java/i then
        self.extend(JavaData)
      when /python/i then
        self.extend(PythonData)
      when /go/i then
        self.extend(GoData)
      else
        Optimist::die "Language #{language} not supported"
    end

    # Update the repo
    clone(owner, repo, true)

    log 'Retrieving all commits'
    walker = Rugged::Walker.new(git)
    walker.sorting(Rugged::SORT_DATE)
    walker.push(git.head.target)
    self.all_commits = walker.map { |commit| commit.oid[0..10] }
    log "#{all_commits.size} commits to process"

    # Get commits that close issues/pull requests
    # Index them by issue/pullreq id, as a sha might close multiple issues
    # see: https://help.github.com/articles/closing-issues-via-commit-messages
    q = "SELECT c.sha FROM commits c, project_commits pc WHERE pc.project_id = ? AND pc.commit_id = c.id"
    commits = db.fetch(q, repo_entry[:id]).all

    results = Parallel.map(commits, in_threads: THREADS) do |c|
      process_commit(c[:sha], owner, repo, language, repo_entry[:id])
    end.select { |x| !x.nil? }

    if results.empty?
      log "No data extracted!"
    else
      puts results.first.keys.map(&:to_s).join(',')
      results.each { |r| puts r.values.join(',') }
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
    ensure
      return age
    end
  end

  def calculate_number_of_commits(walker)
    begin
      num_commits = walker.count
    rescue => e
      log "Exception on commit numbers processing commit #{tigger_commit}: #{e.message}"
      log e.backtrace
    ensure
      return num_commits
    end
  end

  def calculate_confounds(trigger_comit)
    begin
      walker = Rugged::Walker.new(git)
      walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_DATE | Rugged::SORT_REVERSE)
      walker.push(trigger_comit)

      age = calculate_time_difference(walker, trigger_comit)
      num_commits = calculate_number_of_commits walker
    ensure
      return {
          :repo_age => age,
          :repo_num_commits => num_commits
      }
    end
  end

  # Process a single build
  def process_commit(sha, owner, repo, lang, repo_id)
    commit = mongo&.[]('commits')&.find({ 'sha' => sha }).limit(1).first
    # return nil if commit.nil? || commit.empty?
    log "Commit for SHA #{sha}: #{commit.inspect}"

    if commit.nil? || commit.empty?
      git_commit = git.lookup(sha)
      commit = {
        'commit' => {
          'author' => { 'email' => git_commit.author[:email] },
          'committer' => { 'date' => git_commit.author[:time].to_s }
        },
        'sha' => sha
      }
    end

    # Count number of src/comment lines
    sloc = src_lines(sha)
    months_back = 3

    branches = git.branches.each_name(:local).select { |b| git.branches[b].target_id == sha }
    branch = branches.first
    stats = calc_build_stats(owner, repo, [sha])
    confounds = calculate_confounds(sha)
    pr_info = pr_info_for_commit(sha, repo_id)

    {
        # [doc] The branch that was built
        :git_branch => commit.dig('commit', 'branch'),

        # [doc] A list of all commits that were built for this build, up to but excluding the commit of the previous
        # build, or up to and including a merge commit (in which case we cannot go further backward).
        # The internal calculation starts with the parent for PR builds or the actual
        # built commit for non-PR builds, traverse the parent commits up until a commit that is linked to a previous
        # build is found (excluded, this is under `tr_prev_built_commit`) or until we cannot go any further because a
        # branch point was reached. This is indicated in `git_prev_commit_resolution_status`. This list is what
        # the `git_diff_*` fields are calculated upon.
        :git_all_built_commits => sha,

        # [doc] Number of `git_all_built_commits`.
        :git_num_all_built_commits => 1,

        # [doc] The commit that triggered the build.
        :git_trigger_commit => sha,

        # [doc] The emails of the committers of the commits in all `git_all_built_commits`.
        :git_diff_committers => commit.dig('commit', 'author', 'email'),

        # [doc] Number of lines of production code changed in all `git_all_built_commits`.
        :git_diff_src_churn => stats[:lines_added] + stats[:lines_deleted],

        # [doc] Number of lines of test code changed in all `git_all_built_commits`.
        :git_diff_test_churn => stats[:test_lines_added] + stats[:test_lines_deleted],

        # [doc] Project name on GitHub.
        :gh_project_name => "#{owner}/#{repo}",

        # [doc] Whether this build was triggered as part of a pull request on GitHub.
        :gh_is_pr => pr_info[:is_pr],

        # [doc] If the build is a pull request, the creation timestamp for this pull request, in UTC.
        :gh_pr_created_at => pr_info[:created_at],

        # [doc] Dominant repository language, according to GitHub.
        :gh_lang => lang,

        # [doc] Number of developers that committed directly or merged PRs from the moment the build was triggered and 3 months back.
        :gh_team_size => main_team(owner, repo, sha, months_back).size,

        # [doc] If git_commit is linked to a PR on GitHub, the number of discussion comments on that PR.
        :gh_num_issue_comments => num_issue_comments(pr_info[:pr_id], pr_info[:created_at], commit['commit']['committer']['date']),
        
        # [doc] If gh_is_pr is true, the number of comments (code review) on this pull request on GitHub.
        :gh_num_pr_comments => num_pr_comments(pr_info[:pr_id], pr_info[:created_at], commit['commit']['committer']['date']),

        # [doc] The number of comments on `git_all_built_commits` on GitHub.
        :gh_num_commit_comments => num_commit_comments(owner, repo, [sha]),

        # [doc] Number of files added by all `git_all_built_commits`.
        :gh_diff_files_added => stats[:files_added],

        # [doc] Number of files deleted by all `git_all_built_commits`.
        :gh_diff_files_deleted => stats[:files_removed],

        # [doc] Number of files modified by all `git_all_built_commits`.
        :gh_diff_files_modified => stats[:files_modified],

        # [doc] Number of test cases added by `git_all_built_commits`.
        :gh_diff_tests_added => test_diff_stats(sha, sha)[:tests_added],

        # [doc] Number of test cases deleted by `git_all_built_commits`.
        :gh_diff_tests_deleted => test_diff_stats(sha, sha)[:tests_deleted],

        # [doc] Number of src files changed by all `git_all_built_commits`.
        :gh_diff_src_files => stats[:src_files],

        # [doc] Number of documentation files changed by all `git_all_built_commits`.
        :gh_diff_doc_files => stats[:doc_files],

        # [doc] Number of files which are neither source code nor documentation that changed by the commits that where built.
        :gh_diff_other_files => stats[:other_files],

        # [doc] Number of unique commits on the files touched in the commits (`git_all_built_commits`) that triggered the
        # build from the moment the build was triggered and 3 months back. It is a metric of how active the part of
        # the project is that these commits touched.
        :gh_num_commits_on_files_touched => commits_on_files_touched(owner, repo, sha, months_back),

        # [doc] Number of executable production source lines of code, in the entire repository.
        :gh_sloc => sloc,

        # [doc] Overall number of test code lines.
        :gh_test_lines => test_lines(sha).to_f,

        # [doc] Overall number of test cases.
        :gh_test_cases => num_test_cases(sha).to_f,

        # [doc] Overall number of assertions.
        :gh_asserts => num_assertions(sha).to_f,

        # [doc] Whether this commit was authored by a core team member. A core team member is someone who has committed
        # code at least once within the 3 months before this commit, either by directly committing it or by merging
        # commits.
        :gh_by_core_team_member => by_core_team_member?(commit, owner, repo),

        # [doc] Timestamp of the push that triggered the build (GitHub provided), in UTC.
        :gh_pushed_at => pushed_at(sha, commit),

        # [doc] Age of the repository, from the latest commit to its first commit, in days
        :gh_repo_age => confounds[:repo_age],

        # [doc] Number of commits in the repository
        :gh_repo_num_commits => confounds[:repo_num_commits]
    }

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

  def pushed_at(sha, commit)
    if mongo
      push_event = mongo['events'].find(
        {
          'repo.name' => "#{owner}/#{repo}",
          'type' => 'PushEvent',
          'payload.commits.sha' => sha
        },
        sort: { 'created_at' => 1 },
        limit: 1
      ).first
      push_event&.dig('created_at')
    else
      commit.dig('commit', 'committer', 'date') || git.lookup(sha).committer[:time].to_s
    end
  end

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
    commit_time = git.lookup(sha).time
    q = <<-QUERY
    SELECT DISTINCT u1.login
    FROM commits c, project_commits pc, users u, projects p, users u1
    WHERE pc.project_id = p.id
      AND pc.commit_id = c.id
      AND u.login = ?
      AND p.name = ?
      AND c.author_id = u1.id
      AND p.owner_id = u.id
      AND u1.fake IS FALSE
      AND c.created_at BETWEEN DATE_SUB(?, INTERVAL #{months_back} MONTH) AND ?
    QUERY
    db.fetch(q, owner, repo, commit_time, commit_time).map { |r| r[:login] }.uniq
  end

  def by_core_team_member?(commit, owner, repo)
    author = commit.dig('commit', 'author', 'email')
    months_back = 3
    main_team = main_team(owner, repo, commit['sha'], months_back)
    github_login(author)&.in?(main_team)
  end

  # Various statistics for the build. Returned as Hash with the following
  # keys: :lines_added, :lines_deleted, :files_added, :files_removed,
  # :files_modified, :files_touched, :src_files, :doc_files, :other_files.
  def calc_build_stats(owner, repo, commits)
    raw_commits = commit_entries(owner, repo, commits)
    result = Hash.new(0)

    def file_count(commits, status)
      commits.map do |c|
        c['files'].reduce(Array.new) do |acc, y|
          if y['status'] == status then
            acc << y['filename']
          else
            acc
          end
        end
      end.flatten.uniq.size
    end

    def files_touched(commits)
      commits.map do |c|
        c['files'].map do |y|
          y['filename']
        end
      end.flatten.uniq.size
    end

    def file_type(f)
      lang = Linguist::Language.find_by_filename(f)
      if lang.empty? then
        :data
      else
        lang[0].type
      end
    end

    def file_type_count(commits, type)
      commits.map do |c|
        c['files'].reduce(Array.new) do |acc, y|
          if file_type(y['filename']) == type then
            acc << y['filename']
          else
            acc
          end
        end
      end.flatten.uniq.size
    end

    def lines(commit, type, action)
      commit['files'].select do |x|
        next unless file_type(x['filename']) == :programming

        case type
          when :test
            true if test_file_filter.call(x['filename'])
          when :src
            true unless test_file_filter.call(x['filename'])
          else
            false
        end
      end.reduce(0) do |acc, y|
        diff_start = case action
                       when :added
                         "+"
                       when :deleted
                         "-"
                     end

        acc += unless y['patch'].nil?
                 y['patch'].lines.select { |x| x.start_with?(diff_start) }.size
               else
                 0
               end
        acc
      end
    end

    raw_commits.each do |x|
      next if x.nil?
      result[:lines_added] += lines(x, :src, :added)
      result[:lines_deleted] += lines(x, :src, :deleted)
      result[:test_lines_added] += lines(x, :test, :added)
      result[:test_lines_deleted] += lines(x, :test, :deleted)
    end

    result[:files_added] += file_count(raw_commits, "added")
    result[:files_removed] += file_count(raw_commits, "removed")
    result[:files_modified] += file_count(raw_commits, "modified")
    result[:files_touched] += files_touched(raw_commits)

    result[:src_files] += file_type_count(raw_commits, :programming)
    result[:doc_files] += file_type_count(raw_commits, :markup)
    result[:other_files] += file_type_count(raw_commits, :data)

    result
  end


  def test_diff_stats(from_sha, to_sha)
    from = git.lookup(from_sha)
    to = git.lookup(to_sha)

    diff = to.diff(from)

    added = deleted = 0
    state = :none
    diff.patch.lines.each do |line|
      if line.start_with? '---'
        file_path = line.strip.split(/---/)[1]
        next if file_path.nil?

        file_path = file_path[2..-1]
        next if file_path.nil?

        if test_file_filter.call(file_path)
          state = :in_test
        end
      end

      if line.start_with? '- ' and state == :in_test
        if test_case_filter.call(line)
          deleted += 1
        end
      end

      if line.start_with? '+ ' and state == :in_test
        if test_case_filter.call(line)
          added += 1
        end
      end

      if line.start_with? 'diff --'
        state = :none
      end
    end

    {:tests_added => added, :tests_deleted => deleted}
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
