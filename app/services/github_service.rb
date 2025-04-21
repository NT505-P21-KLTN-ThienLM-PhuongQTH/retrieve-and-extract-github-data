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
    STDERR.puts "[GithubService] Retrieving repository #{owner}/#{repo}"

    retrieve_cmd = "bundle exec ruby -Ilib bin/ght-retrieve-repo #{owner} #{repo} -c #{config_path} -t #{token}"
    STDERR.puts "[GithubService] Executing: #{retrieve_cmd}"

    stdout, stderr, status = Open3.capture3(retrieve_cmd)
    unless status.success?
      STDERR.puts "[GithubService] Failed to retrieve repository: #{stderr}"
      return { status: :error, message: "Failed to retrieve repository: #{stderr}" }
    end
    STDERR.puts "[GithubService] ght-retrieve-repo stdout: #{stdout}"

    extract_cmd = "bundle exec ruby -Ilib bin/build_data_extraction #{owner} #{repo}"
    STDERR.puts "[GithubService] Executing: #{extract_cmd}"
    stdout, stderr, status = Open3.capture3(extract_cmd)
    if status.success?
      STDERR.puts "[GithubService] ghtorrent_extractor stdout: #{stdout}"
      return { status: :success, message: "Data extraction completed successfully: #{stdout}"}
    else
      STDERR.puts "[GithubService] Failed to extract data: #{stderr}"
      return { status: :error, message: "Failed to extract data: #{stderr}" }
    end
  end
end