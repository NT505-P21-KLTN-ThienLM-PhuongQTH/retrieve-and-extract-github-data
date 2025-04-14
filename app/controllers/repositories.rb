require_relative '../services/github_service'

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