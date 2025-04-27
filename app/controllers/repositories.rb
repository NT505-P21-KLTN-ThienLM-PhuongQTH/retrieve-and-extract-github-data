require_relative '../services/github_service'
require 'dotenv'
require 'dotenv/load'
require 'net/http'
require 'uri'
require 'json'

Dotenv.load(File.join(__dir__, '..', '..', '.env'))

client = Mongo::Client.new(ENV['MONGODB_URI'])

post '/retrieve' do
  content_type :json

  begin
    request_body = JSON.parse(request.body.read)
    url = request_body['url']
    token = request_body['token']

    unless url && token
      status 400
      return { status: 'error', message: 'Missing URL or token' }.to_json
    end

    owner, repo = GithubService.extract_owner_repo(url)
    unless owner && repo
      status 400
      return { status: 'error', message: 'Invalid GitHub URL' }.to_json
    end

    result = GithubService.retrieve_repository(owner, repo, token)
    status(result[:status] == :success ? 200 : 500)
    result.to_json
  rescue JSON::ParserError
    status 400
    { status: 'error', message: 'Invalid JSON body' }.to_json
  rescue StandardError => e
    status 500
    { status: 'error', message: "Unexpected error: #{e.message}" }.to_json
  end
end

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
      workflow.slice!('_id', 'github_id', 'name', 'path', 'state', 'created_at', 'updated_at', 'project_id')
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
      # Chỉ giữ các trường cần thiết
      run.slice!('_id', 'github_id', 'workflow_id', 'name', 'head_branch', 'head_sha',
                 'run_number', 'status', 'conclusion', 'created_at', 'run_started_at', 'updated_at')
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
      'watchers_count', 'open_issues_count', 'permissions'
    )
    repo_data['_id'] = repo_data['_id'].to_s
    repo_data['pushed_at'] = repo_data['pushed_at']&.to_s

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