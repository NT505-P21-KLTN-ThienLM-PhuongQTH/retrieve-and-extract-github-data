require 'uri'
require 'open3'

module GithubService
  def self.extract_owner_repo(url)
    uri = URI.parse(url)
    return nil unless uri.host == 'github.com'

    path = uri.path.split('/').reject(&:empty?)
    return nil unless path.length >= 2

    [path[0], path[1]]
  end

  def self.retrieve_repository(owner, repo, token)
    config_path = File.join(__dir__, '..', '..', 'config.yaml.erb')
    cmd = "bundle exec ruby -Ilib bin/ght-retrieve-repo #{owner} #{repo} -c #{config_path} -t #{token}"
    stdout, stderr, status = Open3.capture3(cmd)

    if status.success?
      { status: :success, message: "Repository #{owner}/#{repo} retrieved and saved to database" }
    else
      { status: :error, message: "Failed to retrieve repository: #{stderr}" }
    end
  end
end