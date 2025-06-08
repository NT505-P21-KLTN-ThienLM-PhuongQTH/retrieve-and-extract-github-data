require_relative '../services/github_service'
require 'dotenv'
require 'dotenv/load'
require 'net/http'
require 'uri'
require 'json'
require 'date'
require 'securerandom'

Dotenv.load(File.join(__dir__, '..', '..', '.env'))

MONGODB_URI = "mongodb://#{ENV['MONGO_USERNAME']}:#{ENV['MONGO_PASSWORD']}@#{ENV['MONGO_HOST']}:#{ENV['MONGO_PORT']}/#{ENV['MONGO_DATABASE']}"
client = Mongo::Client.new(MONGODB_URI)

REDIS = Redis.new(host: ENV['REDIS_HOST'], port: ENV['REDIS_PORT'], password: ENV['REDIS_PASSWORD'])

post '/retrieve' do
  content_type :json
  begin
    request_body = JSON.parse(request.body.read)
    url = request_body['url']
    token = request_body['token']
    request_id = request_body['request_id'] || SecureRandom.uuid

    unless url && token
      status 400
      return { status: 'error', message: 'Missing url or token' }.to_json
    end

    owner, repo = GithubService.extract_owner_repo(url)
    unless owner && repo
      status 400
      return { status: 'error', message: 'Invalid GitHub URL' }.to_json
    end

    client[:retrieve_requests].insert_one(
      request_id: request_id,
      owner: owner,
      repo: repo,
      status: 'queued',
      created_at: Time.now
    )

    require_relative '../workers/retrieve_repo_worker'
    RetrieveRepoWorker.perform_async(owner, repo, token, request_id)

    status 202
    { status: 'accepted', request_id: request_id }.to_json
  rescue JSON::ParserError
    status 400
    return { status: 'error', message: 'Invalid JSON body' }.to_json
  rescue StandardError => e
    status 500
    return { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/retrieve_status/:request_id' do
  content_type :json
  request_id = params[:request_id]
  request = client[:retrieve_requests].find(request_id: request_id).first
  if request
    status 200
    {
      status: request[:status],
      data: request[:data],
      error: request[:error],
      updated_at: request[:updated_at]
    }.to_json
  else
    status 404
    return { status: 'error', message: 'Request not found' }.to_json
  end
end

# post '/retrieve' do
#   content_type :json

#   begin
#     request_body = JSON.parse(request.body.read)
#     url = request_body['url']
#     token = request_body['token']

#     unless url && token
#       status 400
#       return { status: 'error', message: 'Missing URL or token' }.to_json
#     end

#     owner, repo = GithubService.extract_owner_repo(url)
#     unless owner && repo
#       status 400
#       return { status: 'error', message: 'Invalid GitHub URL' }.to_json
#     end

#     result = GithubService.retrieve_repository(owner, repo, token)
#     status(result[:status] == :success ? 200 : 500)
#     result.to_json
#   rescue JSON::ParserError
#     status 400
#     { status: 'error', message: 'Invalid JSON body' }.to_json
#   rescue StandardError => e
#     status 500
#     { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
#   end
# end

get '/repos/:owner/:repo' do
  content_type :json

  begin
    owner = params[:owner]
    repo = params[:repo]

    unless owner && repo
      status 400
      return { status: 'error', message: 'Missing owner or repo' }.to_json
    end

    # Truy vấn DB ghtorrent
    repo_data = client[:repos].find({ 'owner.login' => owner, name: repo }).first

    unless repo_data
      status 404
      return { status: 'error', message: 'Repository not found' }.to_json
    end

    # Chuyển ObjectId thành string và chỉ lấy các trường cần thiết
    repo_data = repo_data.to_h.slice(
      '_id', 'id', 'full_name', 'name', 'owner', 'private', 'html_url', 'homepage',
      'pushed_at', 'default_branch', 'language', 'stargazers_count', 'forks_count',
      'watchers_count', 'open_issues_count', 'permissions'
    )
    repo_data['_id'] = repo_data['_id'].to_s
    repo_data['pushed_at'] = repo_data['pushed_at']&.to_s
    repo_data.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/workflows' do
  content_type :json

  begin
    owner = params[:owner]
    repo = params[:repo]

    unless owner && repo
      status 400
      return { status: 'error', message: 'Missing owner or repo' }.to_json
    end

    workflows = client[:workflows].find({ owner: owner, repo: repo }).to_a

    workflows.each do |workflow|
      workflow['_id'] = workflow['_id'].to_s
      workflow['github_id'] = workflow['github_id'].to_i
      workflow['created_at'] = workflow['created_at'].to_s
      workflow['updated_at'] = workflow['updated_at'].to_s
      # Chỉ giữ các trường cần thiết
      workflow.slice!('_id', 'github_id', 'name', 'path', 'state', 'created_at', 'updated_at', 'project_id', 'html_url')
    end

    workflows.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/workflow_runs' do
  content_type :json

  begin
    owner = params[:owner]
    repo = params[:repo]

    unless owner && repo
      status 400
      return { status: 'error', message: 'Missing owner or repo' }.to_json
    end

    runs = client[:workflow_runs].find({ owner: owner, repo: repo }).to_a

    runs.each do |run|
      run['_id'] = run['_id'].to_s
      run['github_id'] = run['github_id'].to_i
      run['workflow_id'] = run['workflow_id'].to_i
      run['created_at'] = run['created_at'].to_s
      run['run_started_at'] = run['run_started_at'].to_s
      run['updated_at'] = run['updated_at'].to_s
      run['run_attempt'] = run['run_attempt'].to_i

      if run['head_sha']
        commit = client[:commits].find({ sha: run['head_sha']}).first
        if commit
          commit['_id'] = commit['_id'].to_s
          commit['commit']['author']['date'] = commit['commit']['author']['date'].to_s
          run['commit'] = commit.slice(
            'sha',
            'commit',
            'author',
            'html_url',
            'stats'
          )
        else
          run['commit'] = nil
          puts "No commit found for head_sha: #{run['head_sha']} in repo #{owner}/#{repo}"
        end
      end

      # Chỉ giữ các trường cần thiết
      run.slice!('_id', 'github_id', 'workflow_id', 'name', 'head_branch', 'head_sha',
                 'run_number', 'status', 'conclusion', 'created_at', 'run_started_at', 'updated_at',
                 'event', 'path', 'run_attempt', 'display_title', 'html_url', 'actor', 'triggering_actor',
                 'commit')
    end

    runs.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/sync-data' do
  content_type :json
  begin
    owner = params[:owner]
    repo = params[:repo]
    unless owner && repo
      status 400
      return { status: 'error', message: 'Missing owner or repo' }.to_json
    end

    # Lấy thông tin repo
    repo_data = client[:repos].find({ 'owner.login' => owner, name: repo }).first
    unless repo_data
      status 404
      return { status: 'error', message: 'Repository not found' }.to_json
    end
    repo_data = repo_data.to_h.slice(
      '_id', 'id', 'full_name', 'name', 'owner', 'private', 'html_url', 'homepage',
      'pushed_at', 'default_branch', 'language', 'stargazers_count', 'forks_count',
      'watchers_count', 'open_issues_count', 'permissions', 'created_at', 'updated_at'
    )
    repo_data['_id'] = repo_data['_id'].to_s
    repo_data['pushed_at'] = repo_data['pushed_at']&.to_s
    repo_data['created_at'] = repo_data['created_at']&.to_s
    repo_data['updated_at'] = repo_data['updated_at']&.to_s

    # Lấy workflows
    workflows = client[:workflows].find({ owner: owner, repo: repo }).to_a
    workflows.each do |workflow|
      workflow['_id'] = workflow['_id'].to_s
      workflow['github_id'] = workflow['github_id'].to_i
      workflow['created_at'] = workflow['created_at'].to_s
      workflow['updated_at'] = workflow['updated_at'].to_s
      workflow.slice!('_id', 'github_id', 'name', 'path', 'state', 'created_at', 'updated_at', 'project_id')
    end

    # Lấy workflow runs
    runs = client[:workflow_runs].find({ owner: owner, repo: repo }).to_a
    runs.each do |run|
      run['_id'] = run['_id'].to_s
      run['github_id'] = run['github_id'].to_i
      run['workflow_id'] = run['workflow_id'].to_i
      run['created_at'] = run['created_at'].to_s
      run['run_started_at'] = run['run_started_at'].to_s
      run['updated_at'] = run['updated_at'].to_s
      run.slice!('_id', 'github_id', 'workflow_id', 'name', 'head_branch', 'head_sha',
                 'run_number', 'status', 'conclusion', 'created_at', 'run_started_at', 'updated_at')
    end

    {
      status: 'success',
      repo: repo_data,
      workflows: workflows,
      workflow_runs: runs
    }.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/ci_builds' do
  content_type :json

  begin
    # Tạo query với điều kiện lọc theo git_branch và gh_project_name (nếu có)
    query = {}
    query[:git_branch] = params[:branch] if params[:branch]
    query[:gh_project_name] = params[:project_name] if params[:project_name]

    builds = client[:ci_builds].find(query).to_a

    builds.each do |build|
      # Chuyển ObjectId thành string
      build['_id'] = build['_id'].to_s
      
      # Chuyển các trường thời gian thành string
      build['gh_build_started_at'] = build['gh_build_started_at'].to_s if build['gh_build_started_at']
      
      # Chuyển các trường số thành integer
      build['git_num_all_built_commits'] = build['git_num_all_built_commits'].to_i if build['git_num_all_built_commits']
      build['git_diff_src_churn'] = build['git_diff_src_churn'].to_i if build['git_diff_src_churn']
      build['git_diff_test_churn'] = build['git_diff_test_churn'].to_i if build['git_diff_test_churn']
      build['gh_team_size'] = build['gh_team_size'].to_i if build['gh_team_size']
      build['gh_num_issue_comments'] = build['gh_num_issue_comments'].to_i if build['gh_num_issue_comments']
      build['gh_num_pr_comments'] = build['gh_num_pr_comments'].to_i if build['gh_num_pr_comments']
      build['gh_num_commit_comments'] = build['gh_num_commit_comments'].to_i if build['gh_num_commit_comments']
      build['gh_diff_files_added'] = build['gh_diff_files_added'].to_i if build['gh_diff_files_added']
      build['gh_diff_files_deleted'] = build['gh_diff_files_deleted'].to_i if build['gh_diff_files_deleted']
      build['gh_diff_files_modified'] = build['gh_diff_files_modified'].to_i if build['gh_diff_files_modified']
      build['gh_diff_tests_added'] = build['gh_diff_tests_added'].to_i if build['gh_diff_tests_added']
      build['gh_diff_tests_deleted'] = build['gh_diff_tests_deleted'].to_i if build['gh_diff_tests_deleted']
      build['gh_diff_src_files'] = build['gh_diff_src_files'].to_i if build['gh_diff_src_files']
      build['gh_diff_doc_files'] = build['gh_diff_doc_files'].to_i if build['gh_diff_doc_files']
      build['gh_diff_other_files'] = build['gh_diff_other_files'].to_i if build['gh_diff_other_files']
      build['gh_num_commits_on_files_touched'] = build['gh_num_commits_on_files_touched'].to_i if build['gh_num_commits_on_files_touched']
      build['gh_sloc'] = build['gh_sloc'].to_i if build['gh_sloc']
      build['gh_test_lines_per_kloc'] = build['gh_test_lines_per_kloc'].to_i if build['gh_test_lines_per_kloc']
      build['gh_test_cases_per_kloc'] = build['gh_test_cases_per_kloc'].to_i if build['gh_test_cases_per_kloc']
      build['gh_asserts_cases_per_kloc'] = build['gh_asserts_cases_per_kloc'].to_i if build['gh_asserts_cases_per_kloc']
      build['gh_repo_num_commits'] = build['gh_repo_num_commits'].to_i if build['gh_repo_num_commits']
      build['build_duration'] = build['build_duration'].to_i if build['build_duration']
      
      # Chuyển các trường số thực thành float
      build['gh_repo_age'] = build['gh_repo_age'].to_f if build['gh_repo_age']
      
      # Chuyển các trường boolean thành true/false
      build['gh_is_pr'] = !!build['gh_is_pr'] if build.key?('gh_is_pr')
      build['gh_by_core_team_member'] = !!build['gh_by_core_team_member'] if build.key?('gh_by_core_team_member')
    end

    { status: 'success', ci_builds: builds }.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

# Endpoint để trả về n giá trị gần nhất trong ci_builds, có thể lọc theo nhánh và tên repo
get '/ci_builds/recent' do
  content_type :json

  begin
    limit = (params[:limit] || 10).to_i # Mặc định trả về 10 giá trị nếu không có tham số limit
    if limit <= 0
      status 400
      return { status: 'error', message: 'Limit must be a positive integer' }.to_json
    end

    # Tạo query với điều kiện lọc theo git_branch và gh_project_name (nếu có)
    query = {}
    query[:git_branch] = params[:branch] if params[:branch]
    query[:gh_project_name] = params[:project_name] if params[:project_name]

    # Lấy tất cả document thỏa mãn query
    builds = client[:ci_builds].find(query).to_a

    # Sắp xếp trong Ruby theo gh_build_started_at (chuyển đổi thành DateTime trước)
    builds.sort_by! do |build|
      begin
        # Chuyển đổi gh_build_started_at từ string sang DateTime để sắp xếp chính xác
        DateTime.strptime(build['gh_build_started_at'], '%m/%d/%Y %H:%M:%S')
      rescue ArgumentError
        # Nếu có lỗi (giá trị không hợp lệ), đặt thời gian mặc định để tránh crash
        DateTime.new(1970, 1, 1) # Thời gian rất cũ
      end
    end

    # Đảo ngược để sắp xếp giảm dần (mới nhất trước)
    builds.reverse!

    # Lấy số lượng document theo limit
    builds = builds.first(limit)

    builds.each do |build|
      # Chuyển ObjectId thành string
      build['_id'] = build['_id'].to_s
      
      # Chuyển các trường thời gian thành string
      build['gh_build_started_at'] = build['gh_build_started_at'].to_s if build['gh_build_started_at']
      
      # Chuyển các trường số thành integer
      build['git_num_all_built_commits'] = build['git_num_all_built_commits'].to_i if build['git_num_all_built_commits']
      build['git_diff_src_churn'] = build['git_diff_src_churn'].to_i if build['git_diff_src_churn']
      build['git_diff_test_churn'] = build['git_diff_test_churn'].to_i if build['git_diff_test_churn']
      build['gh_team_size'] = build['gh_team_size'].to_i if build['gh_team_size']
      build['gh_num_issue_comments'] = build['gh_num_issue_comments'].to_i if build['gh_num_issue_comments']
      build['gh_num_pr_comments'] = build['gh_num_pr_comments'].to_i if build['gh_num_pr_comments']
      build['gh_num_commit_comments'] = build['gh_num_commit_comments'].to_i if build['gh_num_commit_comments']
      build['gh_diff_files_added'] = build['gh_diff_files_added'].to_i if build['gh_diff_files_added']
      build['gh_diff_files_deleted'] = build['gh_diff_files_deleted'].to_i if build['gh_diff_files_deleted']
      build['gh_diff_files_modified'] = build['gh_diff_files_modified'].to_i if build['gh_diff_files_modified']
      build['gh_diff_tests_added'] = build['gh_diff_tests_added'].to_i if build['gh_diff_tests_added']
      build['gh_diff_tests_deleted'] = build['gh_diff_tests_deleted'].to_i if build['gh_diff_tests_deleted']
      build['gh_diff_src_files'] = build['gh_diff_src_files'].to_i if build['gh_diff_src_files']
      build['gh_diff_doc_files'] = build['gh_diff_doc_files'].to_i if build['gh_diff_doc_files']
      build['gh_diff_other_files'] = build['gh_diff_other_files'].to_i if build['gh_diff_other_files']
      build['gh_num_commits_on_files_touched'] = build['gh_num_commits_on_files_touched'].to_i if build['gh_num_commits_on_files_touched']
      build['gh_sloc'] = build['gh_sloc'].to_i if build['gh_sloc']
      build['gh_test_lines_per_kloc'] = build['gh_test_lines_per_kloc'].to_i if build['gh_test_lines_per_kloc']
      build['gh_test_cases_per_kloc'] = build['gh_test_cases_per_kloc'].to_i if build['gh_test_cases_per_kloc']
      build['gh_asserts_cases_per_kloc'] = build['gh_asserts_cases_per_kloc'].to_i if build['gh_asserts_cases_per_kloc']
      build['gh_repo_num_commits'] = build['gh_repo_num_commits'].to_i if build['gh_repo_num_commits']
      build['build_duration'] = build['build_duration'].to_i if build['build_duration']
      
      # Chuyển các trường số thực thành float
      build['gh_repo_age'] = build['gh_repo_age'].to_f if build['gh_repo_age']
      
      # Chuyển các trường boolean thành true/false
      build['gh_is_pr'] = !!build['gh_is_pr'] if build.key?('gh_is_pr')
      build['gh_by_core_team_member'] = !!build['gh_by_core_team_member'] if build.key?('gh_by_core_team_member')
    end

    { status: 'success', ci_builds: builds }.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

get '/ci_builds_from_run' do
  content_type :json

  begin
    # Tạo query với điều kiện lọc
    query = {}
    query[:git_branch] = params[:branch] if params[:branch]
    query[:gh_project_name] = params[:project_name] if params[:project_name]

    # Xử lý run_date
    if params[:run_date]
      begin
        run_date = DateTime.parse(params[:run_date])
        run_date_str = run_date.strftime('%m/%d/%Y %H:%M:%S')
        query[:gh_build_started_at] = { '$lte' => run_date_str }
      rescue ArgumentError
        status 400
        return { status: 'error', message: 'Invalid run_date format. Use ISO 8601 (e.g., 2025-05-26T20:00:00Z)' }.to_json
      end
    end

    # Truy vấn ci_builds
    builds = client[:ci_builds].find(query).to_a

    # Chuyển đổi dữ liệu
    builds.each do |build|
      build['_id'] = build['_id'].to_s
      build['gh_build_started_at'] = build['gh_build_started_at'].to_s if build['gh_build_started_at']
      build['git_num_all_built_commits'] = build['git_num_all_built_commits'].to_i if build['git_num_all_built_commits']
      build['git_diff_src_churn'] = build['git_diff_src_churn'].to_i if build['git_diff_src_churn']
      build['git_diff_test_churn'] = build['git_diff_test_churn'].to_i if build['git_diff_test_churn']
      build['gh_team_size'] = build['gh_team_size'].to_i if build['gh_team_size']
      build['gh_num_issue_comments'] = build['gh_num_issue_comments'].to_i if build['gh_num_issue_comments']
      build['gh_num_pr_comments'] = build['gh_num_pr_comments'].to_i if build['gh_num_pr_comments']
      build['gh_num_commit_comments'] = build['gh_num_commit_comments'].to_i if build['gh_num_commit_comments']
      build['gh_diff_files_added'] = build['gh_diff_files_added'].to_i if build['gh_diff_files_added']
      build['gh_diff_files_deleted'] = build['gh_diff_files_deleted'].to_i if build['gh_diff_files_deleted']
      build['gh_diff_files_modified'] = build['gh_diff_files_modified'].to_i if build['gh_diff_files_modified']
      build['gh_diff_tests_added'] = build['gh_diff_tests_added'].to_i if build['gh_diff_tests_added']
      build['gh_diff_tests_deleted'] = build['gh_diff_tests_deleted'].to_i if build['gh_diff_tests_deleted']
      build['gh_diff_src_files'] = build['gh_diff_src_files'].to_i if build['gh_diff_src_files']
      build['gh_diff_doc_files'] = build['gh_diff_doc_files'].to_i if build['gh_diff_doc_files']
      build['gh_diff_other_files'] = build['gh_diff_other_files'].to_i if build['gh_diff_other_files']
      build['gh_num_commits_on_files_touched'] = build['gh_num_commits_on_files_touched'].to_i if build['gh_num_commits_on_files_touched']
      build['gh_sloc'] = build['gh_sloc'].to_i if build['gh_sloc']
      build['gh_test_lines_per_kloc'] = build['gh_test_lines_per_kloc'].to_i if build['gh_test_lines_per_kloc']
      build['gh_test_cases_per_kloc'] = build['gh_test_cases_per_kloc'].to_i if build['gh_test_cases_per_kloc']
      build['gh_asserts_cases_per_kloc'] = build['gh_asserts_cases_per_kloc'].to_i if build['gh_asserts_cases_per_kloc']
      build['gh_repo_num_commits'] = build['gh_repo_num_commits'].to_i if build['gh_repo_num_commits']
      build['build_duration'] = build['build_duration'].to_i if build['build_duration']
      build['gh_repo_age'] = build['gh_repo_age'].to_f if build['gh_repo_age']
      build['gh_is_pr'] = !!build['gh_is_pr'] if build.key?('gh_is_pr')
      build['gh_by_core_team_member'] = !!build['gh_by_core_team_member'] if build.key?('gh_by_core_team_member')
    end

    { status: 'success', ci_builds: builds }.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end