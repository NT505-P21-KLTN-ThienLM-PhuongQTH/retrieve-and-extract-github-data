# require './app/services/extractor'

class RepoController < App::Base
  get "/" do
    "Hello from Sinatra backend!"
  end

  post '/repos' do
    content_type :json
    payload = JSON.parse(request.body.read)
    repo_url = payload['repo_url']
    token = payload['token'] || settings.github_token

    unless repo_url =~ %r{https://github.com/([^/]+)/([^/]+)}
      halt 400, { error: 'Invalid GitHub repo URL' }.to_json
    end

    owner = $1
    repo = $2
    db = settings.db

    begin
      retrieval = GhtRetrieveRepo.new(owner, repo, token, db)
      retrieval.retrieve_commits
      { message: "Repository #{owner}/#{repo} initialized" }.to_json
    rescue => e
      halt 500, { error: "Failed to initialize repository: #{e.message}" }.to_json
    end
  end

  # get '/repos/:owner/:repo/commits' do
  #   content_type :json
  #   owner = params[:owner]
  #   repo = params[:repo]
    
  #   commits = Commit.where(owner: owner, repo: repo).eager(:builds).all
  #   commits.map do |c|
  #     {
  #       sha: c.sha,
  #       branch: c.branch,
  #       author_email: c.author_email,
  #       committed_at: c.committed_at,
  #       pushed_at: c.pushed_at,
  #       files_added: c.files_added,
  #       files_deleted: c.files_deleted,
  #       files_modified: c.files_modified,
  #       builds: c.builds.map { |b| { status: b.status, duration: b.duration, workflow_name: b.workflow_name } }
  #     }
  #   end.to_json
  # end
end