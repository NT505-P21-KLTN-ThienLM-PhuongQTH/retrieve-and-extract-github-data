require 'bundler'
require 'dotenv'
require 'dotenv/load'

Bundler.require

Dotenv.load(File.join(__dir__, '..', '..', 'config', '.env'))
require_relative '../controllers/repositories'

require_relative '../../lib/ghtorrent/api_client'
require_relative '../../lib/ghtorrent/bson_orderedhash'
require_relative '../../lib/ghtorrent/command'
require_relative '../../lib/ghtorrent/event_processing'
require_relative '../../lib/ghtorrent/ghtorrent'
require_relative '../../lib/ghtorrent/hash'
require_relative '../../lib/ghtorrent/logging'
require_relative '../../lib/ghtorrent/persister'
require_relative '../../lib/ghtorrent/refresher'
require_relative '../../lib/ghtorrent/retriever'
require_relative '../../lib/ghtorrent/settings'
require_relative '../../lib/ghtorrent/utils'
require_relative '../../lib/ghtorrent/adapters/mongo_persister'
require_relative '../../lib/ghtorrent/commands/full_repo_retriever'
