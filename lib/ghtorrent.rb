module GHTorrent
  # Route keys used for setting up queues for events, using GHTorrent
  ROUTEKEY_CREATE = "evt.CreateEvent"
  ROUTEKEY_DELETE = "evt.DeleteEvent"
  ROUTEKEY_DOWNLOAD = "evt.DownloadEvent"
  ROUTEKEY_FOLLOW = "evt.FollowEvent"
  ROUTEKEY_FORK = "evt.ForkEvent"
  ROUTEKEY_FORK_APPLY = "evt.ForkApplyEvent"
  ROUTEKEY_GIST = "evt.GistEvent"
  ROUTEKEY_GOLLUM = "evt.GollumEvent"
  ROUTEKEY_ISSUE_COMMENT = "evt.IssueCommentEvent"
  ROUTEKEY_ISSUES = "evt.IssuesEvent"
  ROUTEKEY_MEMBER = "evt.MemberEvent"
  ROUTEKEY_PUBLIC = "evt.PublicEvent"
  ROUTEKEY_PULL_REQUEST = "evt.PullRequestEvent"
  ROUTEKEY_PULL_REQUEST_REVIEW_COMMENT = "evt.PullRequestReviewCommentEvent"
  ROUTEKEY_PUSH = "evt.PushEvent"
  ROUTEKEY_TEAM_ADD = "evt.TeamAddEvent"
  ROUTEKEY_WATCH = "evt.WatchEvent"

  # Route key for projects
  ROUTEKEY_PROJECTS = "evt.projects"
  # Route key for users
  ROUTEKEY_USERS = "evt.users"

end

# Shared extensions to library methods
require_relative './ghtorrent/hash'
require_relative './ghtorrent/ghtime'
require_relative './ghtorrent/bson_orderedhash'

# Basic utility modules
require_relative './version'
require_relative './ghtorrent/utils'
require_relative './ghtorrent/logging'
require_relative './ghtorrent/settings'
require_relative './ghtorrent/api_client'

# Support for command line utilities offered by this gem
require_relative './ghtorrent/command'

# Configuration and drivers for caching retrieved data
require_relative './ghtorrent/adapters/base_adapter'
require_relative './ghtorrent/adapters/mongo_persister'
require_relative './ghtorrent/adapters/noop_persister'

# Support for retrieving and saving intermediate results
require_relative './ghtorrent/persister'
require_relative './ghtorrent/retriever'

# SQL database fillup methods
require_relative './ghtorrent/event_processing'
require_relative './ghtorrent/ghtorrent'
require_relative './ghtorrent/transacted_gh_torrent'
require_relative './ghtorrent/refresher'

# Multi-process queue clients
require_relative './ghtorrent/multiprocess_queue_client'

# Commands
require_relative './ghtorrent/commands/ght_retrieve_repo'

# vim: set sta sts=2 shiftwidth=2 sw=2 et ai :
