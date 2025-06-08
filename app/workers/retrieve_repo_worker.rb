require 'dotenv'
require 'dotenv/load'
require 'sidekiq'
require 'redis'
require 'mongo'
require 'securerandom'
require_relative '../services/github_service'

Dotenv.load(File.join(__dir__, '..', '..', '.env'))

MONGODB_URI = "mongodb://#{ENV['MONGO_USERNAME']}:#{ENV['MONGO_PASSWORD']}@#{ENV['MONGO_HOST']}:#{ENV['MONGO_PORT']}/#{ENV['MONGO_DATABASE']}"

redis_options = {
  host: ENV['REDIS_HOST'] || 'localhost',
  port: ENV['REDIS_PORT'] || 6379
}
redis_options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']

begin
  REDIS = Redis.new(redis_options)
  REDIS.ping
  puts "[Redis] Connected successfully"
rescue Redis::CannotConnectError => e
  puts "[Redis] Connection failed: #{e.message}"
  exit 1
end

Sidekiq.configure_client do |config|
  redis_options = {
    host: ENV['REDIS_HOST'] || 'localhost',
    port: (ENV['REDIS_PORT'] || 6379).to_i,
    password: ENV['REDIS_PASSWORD']
  }
  config.redis = redis_options
end

Sidekiq.configure_server do |config|
  redis_options = {
    host: ENV['REDIS_HOST'] || 'localhost',
    port: (ENV['REDIS_PORT'] || 6379).to_i,
    password: ENV['REDIS_PASSWORD']
  }
  config.redis = redis_options
end

class RetrieveRepoWorker
  include Sidekiq::Worker
  sidekiq_options queue: :retrieve_repo, retry: 5

  def perform(owner, repo, token, request_id)
    client = Mongo::Client.new(MONGODB_URI)
    begin
      puts "[Sidekiq] Processing job for #{owner}/#{repo} (request_id: #{request_id})"
      client[:retrieve_requests].update_one(
        { request_id: request_id },
        { '$set': { status: 'processing', updated_at: Time.now } },
        { upsert: true }
      )

      result = GithubService.retrieve_repository(owner, repo, token)

      client[:retrieve_requests].update_one(
        { request_id: request_id },
        { '$set': { status: result[:status], data: result[:data], updated_at: Time.now } }
      )

      REDIS.publish('retrieve_results', {
        request_id: request_id,
        status: result[:status],
        data: result[:data]
      }.to_json)
    rescue StandardError => e
      client[:retrieve_requests].update_one(
        { request_id: request_id },
        { '$set': { status: 'error', error: e.message, updated_at: Time.now } }
      )
      REDIS.publish('retrieve_results', {
        request_id: request_id,
        status: 'error',
        error: e.message
      }.to_json)
    end
  end
end