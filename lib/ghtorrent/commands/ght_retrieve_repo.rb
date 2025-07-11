require 'rubygems'

require_relative '../ghtorrent'
require_relative '../settings'
require_relative '../command'
require_relative '../retriever'
require_relative './full_repo_retriever'

class GHTRetrieveRepo < GHTorrent::Command

  include GHTorrent::Commands::FullRepoRetriever

  def prepare_options(options)
    options.banner <<-BANNER
An efficient way to get all data for a single repo

#{command_name} [options] owner repo

    BANNER
    supported_options(options)
  end

  def validate
    super
    validate_options
    Optimist::die("Missing owner") if ARGV[0].nil?
    Optimist::die("Missing repo") if ARGV[1].nil?
  end

  def go
    retrieve_full_repo(ARGV[0], ARGV[1])
  end
end
