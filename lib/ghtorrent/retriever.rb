require 'uri'
require 'cgi'
require 'time'

require_relative './api_client'
require_relative './settings'
require_relative './utils'
require_relative './logging'

module GHTorrent
  module Retriever
    include GHTorrent::Settings
    include GHTorrent::Utils
    include GHTorrent::APIClient
    include GHTorrent::Logging

    def persister
      raise Exception.new('Unimplemented')
    end

    def retrieve_user_byusername(user)
      stored_user = persister.find(:users, { 'login' => user })
      if stored_user.empty?
        url = ghurl "users/#{user}"
        u = api_request(url)

        return if u.nil? or u.empty?

        persister.store(:users, u)
        what = user_type(u['type'])
        info "Added user #{what} #{user}"
        u
      else
        what = user_type(stored_user.first['type'])
        debug "#{what} #{user} exists"
        stored_user.first
      end
    end

    # Try Github user search by email. This is optional info, so
    # it may not return any data. If this fails, try searching by name
    # http://developer.github.com/v3/search/#email-search
    def retrieve_user_byemail(email, name)
      url = ghurl("legacy/user/email/#{CGI.escape(email)}")
      byemail = api_request(url)

      if byemail.nil? || !byemail.is_a?(Hash) || byemail.empty? || !byemail['user'].is_a?(Hash)
        # Only search by name if name param looks like a proper name
        byname = if !name.nil? && name.split(/ /).size > 1
                  url = ghurl("legacy/user/search/#{CGI.escape(name)}")
                  api_request(url)
                end

        if byname.nil? || !byname.is_a?(Hash) || byname['users'].nil? || byname['users'].empty?
          nil
        else
          user = byname['users'].find do |u|
            u['name'] == name &&
              !u['login'].nil? &&
              !retrieve_user_byusername(u['login']).nil?
          end

          if user.nil?
            warn "Could not find user #{email}"
            nil
          elsif !email.nil? && user['email'] == email
            user
          else
            warn "Could not find user #{email}"
            nil
          end
        end
      elsif byemail['user']['login'].nil?
        u = byemail['user']
        persister.store(:users, u)
        what = user_type(u['type'])
        info "Added user #{what} #{u}"
        u
      else
        info "Added user #{byemail['user']['login']} retrieved by email #{email}"
        retrieve_user_byusername(byemail['user']['login'])
      end
    end

    def retrieve_user_follower(followed, follower)
      stored_item = persister.find(:followers, { 'follows' => followed,
                                                 'login' => follower })

      if stored_item.empty?
        retrieve_user_followers(followed).find { |x| x['login'] == follower }
      else
        stored_item.first
      end
    end

    def retrieve_user_followers(user)
      followers = paged_api_request(ghurl("users/#{user}/followers"))
      followers.each do |x|
        x['follows'] = user

        exists = !persister.find(:followers, { 'follows' => user,
                                               'login' => x['login'] }).empty?

        if !exists
          persister.store(:followers, x)
          info "Added follower #{user} -> #{x['login']}"
        else
          debug "Follower #{user} -> #{x['login']} exists"
        end
      end

      persister.find(:followers, { 'follows' => user })
    end

    def retrieve_user_following(user)
      following = paged_api_request(ghurl("users/#{user}/following"))
      user_followers_entry = nil

      following.each do |x|
        if user_followers_entry.nil?
          reverse_lookup = persister.find(:followers, { 'follows' => x['login'],
                                                        'login' => user })
          user_followers_entry = if reverse_lookup.empty?
                                   retrieve_user_followers(x['login'])\
                                     .find { |y| y['login'] == user }
                                 else
                                   reverse_lookup[0]
                                 end
        end

        exists = !persister.find(:followers, { 'follows' => x['login'],
                                               'login' => user }).empty?
        if !exists
          user_followers_entry['follows'] = x['login']
          user_followers_entry.delete(:_id)
          user_followers_entry.delete('_id')
          persister.store(:followers, user_followers_entry)
          info "Added following #{user} -> #{x['login']}"
        else
          debug "Following #{user} -> #{x['login']} exists"
        end
      end

      persister.find(:followers, { 'login' => user })
    end

    def retrieve_pull_request_commit(pr_obj, repo, sha, user)
      pull_commit = persister.find(:pull_request_commits, { 'sha' => "#{sha}" })

      if pull_commit.empty?
        commit = retrieve_commit(repo, sha, user)

        return if commit.nil?

        commit.delete(nil)
        commit.delete(:_id)
        commit.delete('_id')
        commit['pull_request_id'] = pr_obj[:id]
        persister.store(:pull_request_commits, commit)
        info "Added commit #{user}/#{repo} -> #{sha} with pull_id #{pr_obj['id']}"
        commit

      else
        debug "Pull request commit #{user}/#{repo} -> #{sha} exists for pull id #{pr_obj['id']}"
        pull_commit.first
      end
    end

    # Retrieve a single commit from a repo
    def retrieve_commit(repo, sha, user)
      commit = persister.find(:commits, { 'sha' => "#{sha}" })

      if commit.empty?
        url = ghurl "repos/#{user}/#{repo}/commits/#{sha}"
        c = api_request(url)

        return if c.nil? or c.empty?

        # commit patches are big and not always interesting
        c['files'].each { |file| file.delete('patch') } if config(:commit_handling) == 'trim'
        persister.store(:commits, c)
        info "Added commit #{user}/#{repo} -> #{sha}"
        c
      else
        debug "Commit #{user}/#{repo} -> #{sha} exists"
        commit.first
      end
    end

    # Retrieve commits starting from the provided +sha+
    def retrieve_commits(repo, sha, user, pages = -1)
      url = if sha.nil?
              ghurl "repos/#{user}/#{repo}/commits"
            else
              ghurl "repos/#{user}/#{repo}/commits?sha=#{sha}"
            end

      commits = restricted_page_request(url, pages)

      commits.map do |c|
        retrieve_commit(repo, c['sha'], user)
      end.select { |x| !x.nil? }
    end

    def retrieve_repo(user, repo, refresh = false)
      stored_repo = persister.find(:repos, { 'owner.login' => user,
                                             'name' => repo })
      if stored_repo.empty? or refresh
        url = ghurl "repos/#{user}/#{repo}"
        r = api_request(url)

        return if r.nil? or r.empty?

        if refresh
          persister.upsert(:repos, { 'name' => r['name'], 'owner.login' => r['owner']['login'] }, r)
          info "Refreshed repo #{user} -> #{repo}"
        else
          persister.store(:repos, r)
          info "Added repo #{user} -> #{repo}"
        end
        r
      else
        debug "Repo #{user} -> #{repo} exists"
        stored_repo.first
      end
    end

    def retrieve_languages(owner, repo)
      paged_api_request ghurl "repos/#{owner}/#{repo}/languages"
    end

    # Retrieve organizations the provided user participates into
    def retrieve_orgs(user)
      url = ghurl "users/#{user}/orgs"
      orgs = paged_api_request(url)
      orgs.map { |o| retrieve_org(o['login']) }
    end

    # Retrieve a single organization
    def retrieve_org(org)
      retrieve_user_byusername(org)
    end

    # Retrieve organization members
    def retrieve_org_members(org)
      stored_org_members = persister.find(:org_members, { 'org' => org })

      org_members = paged_api_request(ghurl("orgs/#{org}/members"))
      org_members.each do |x|
        x['org'] = org

        exists = !stored_org_members.find do |f|
          f['org'] == org && f['login'] == x['login']
        end.nil?

        if !exists
          persister.store(:org_members, x)
          info "Added org_member #{org} -> #{x['login']}"
        else
          debug "Org Member #{org} -> #{x['login']} exists"
        end
      end

      persister.find(:org_members, { 'org' => org }).map { |o| retrieve_org(o['login']) }
    end

    # Retrieve all comments for a single commit
    def retrieve_commit_comments(owner, repo, sha)
      retrieved_comments = paged_api_request(ghurl("repos/#{owner}/#{repo}/commits/#{sha}/comments"))

      retrieved_comments.each do |x|
        if persister.find(:commit_comments, { 'commit_id' => x['commit_id'],
                                              'id' => x['id'] }).empty?
          persister.store(:commit_comments, x)
        end
      end
      persister.find(:commit_comments, { 'commit_id' => sha })
    end

    # Retrieve a single comment
    def retrieve_commit_comment(owner, repo, sha, id)
      comment = persister.find(:commit_comments, { 'commit_id' => sha,
                                                   'id' => id }).first
      if comment.nil?
        r = api_request(ghurl("repos/#{owner}/#{repo}/comments/#{id}"))

        if r.nil? or r.empty?
          warn "Could not find commit_comment #{id}. Deleted?"
          return
        end

        persister.store(:commit_comments, r)
        info "Added commit_comment #{r['commit_id']} -> #{r['id']}"
        persister.find(:commit_comments, { 'commit_id' => sha, 'id' => id }).first
      else
        debug "Commit comment #{comment['commit_id']} -> #{comment['id']} exists"
        comment
      end
    end

    # Retrieve all watchers for a repository
    def retrieve_watchers(user, repo)
      repo_bound_items(user, repo, :watchers,
                       ["repos/#{user}/#{repo}/stargazers"],
                       { 'repo' => repo, 'owner' => user },
                       'login', nil, false, :desc)
    end

    # Retrieve a single watcher for a repository
    def retrieve_watcher(user, repo, watcher)
      repo_bound_item(user, repo, watcher, :watchers,
                      ["repos/#{user}/#{repo}/stargazers"],
                      { 'repo' => repo, 'owner' => user },
                      'login', :desc)
    end

    def retrieve_pull_requests(user, repo, refr = false)
      open = "repos/#{user}/#{repo}/pulls"
      closed = "repos/#{user}/#{repo}/pulls?state=closed"
      repo_bound_items(user, repo, :pull_requests,
                       [open, closed],
                       { 'repo' => repo, 'owner' => user },
                       'number', nil, refr, :asc)
    end

    def retrieve_pull_request(user, repo, pullreq_id)
      open = "repos/#{user}/#{repo}/pulls"
      closed = "repos/#{user}/#{repo}/pulls?state=closed"
      repo_bound_item(user, repo, pullreq_id, :pull_requests,
                      [open, closed],
                      { 'repo' => repo, 'owner' => user,
                        'number' => pullreq_id },
                      'number')
    end

    def retrieve_forks(user, repo)
      repo_bound_items(user, repo, :forks,
                       ["repos/#{user}/#{repo}/forks"],
                       { 'repo' => repo, 'owner' => user },
                       'id', nil, false, :asc)
    end

    def retrieve_fork(user, repo, fork_id)
      repo_bound_item(user, repo, fork_id, :forks,
                      ["repos/#{user}/#{repo}/forks"],
                      { 'repo' => repo, 'owner' => user },
                      'id')
    end

    def retrieve_pull_req_commits(user, repo, pullreq_id)
      pr_commits = paged_api_request(ghurl("repos/#{user}/#{repo}/pulls/#{pullreq_id}/commits"))

      pr_commits.map do |x|
        head_user = x['url'].split(%r{/})[4]
        head_repo = x['url'].split(%r{/})[5]

        retrieve_commit(head_repo, x['sha'], head_user)
      end.select { |x| !x.nil? }
    end

    def retrieve_pull_req_comments(owner, repo, pullreq_id)
      review_comments_url = ghurl "repos/#{owner}/#{repo}/pulls/#{pullreq_id}/comments"

      url = review_comments_url
      retrieved_comments = paged_api_request url

      retrieved_comments.each do |x|
        x['owner'] = owner
        x['repo'] = repo
        x['pullreq_id'] = pullreq_id.to_i

        next unless persister.find(:pull_request_comments, { 'owner' => owner,
                                                             'repo' => repo,
                                                             'pullreq_id' => pullreq_id,
                                                             'id' => x['id'] }).empty?

        persister.store(:pull_request_comments, x)
      end

      persister.find(:pull_request_comments, { 'owner' => owner, 'repo' => repo,
                                               'pullreq_id' => pullreq_id })
    end

    def retrieve_pull_req_comment(owner, repo, pullreq_id, comment_id)
      comment = persister.find(:pull_request_comments, { 'repo' => repo,
                                                         'owner' => owner,
                                                         'pullreq_id' => pullreq_id.to_i,
                                                         'id' => comment_id }).first
      if comment.nil?
        r = api_request(ghurl("repos/#{owner}/#{repo}/pulls/comments/#{comment_id}"))

        if r.nil? or r.empty?
          warn "Could not find pullreq_comment #{owner}/#{repo} #{pullreq_id}->#{comment_id}. Deleted?"
          return
        end

        r['repo'] = repo
        r['owner'] = owner
        r['pullreq_id'] = pullreq_id.to_i
        persister.store(:pull_request_comments, r)
        info "Added pullreq_comment #{owner}/#{repo} #{pullreq_id}->#{comment_id}"
        persister.find(:pull_request_comments, { 'repo' => repo, 'owner' => owner,
                                                 'pullreq_id' => pullreq_id.to_i,
                                                 'id' => comment_id }).first
      else
        debug "Pull request comment #{owner}/#{repo} #{pullreq_id}->#{comment_id} exists"
        comment
      end
    end

    def retrieve_issues(user, repo, refr = false)
      open = "repos/#{user}/#{repo}/issues"
      closed = "repos/#{user}/#{repo}/issues?state=closed"
      repo_bound_items(user, repo, :issues,
                       [open, closed],
                       { 'repo' => repo, 'owner' => user },
                       'number', nil, refr, :asc)
    end

    def retrieve_issue(user, repo, issue_id)
      open = "repos/#{user}/#{repo}/issues"
      closed = "repos/#{user}/#{repo}/issues?state=closed"
      repo_bound_item(user, repo, issue_id, :issues,
                      [open, closed],
                      { 'repo' => repo, 'owner' => user },
                      'number')
    end

    def retrieve_issue_events(owner, repo, issue_id)
      url = ghurl "repos/#{owner}/#{repo}/issues/#{issue_id}/events"
      retrieved_events = paged_api_request url

      issue_events = retrieved_events.map do |x|
        x['owner'] = owner
        x['repo'] = repo
        x['issue_id'] = issue_id

        if persister.find(:issue_events, { 'owner' => owner,
                                           'repo' => repo,
                                           'issue_id' => issue_id,
                                           'id' => x['id'] }).empty?
          info "Added issue_event #{owner}/#{repo} #{issue_id}->#{x['id']}"
          persister.store(:issue_events, x)
        end
        x
      end
      a = persister.find(:issue_events, { 'owner' => owner, 'repo' => repo,
                                          'issue_id' => issue_id })
      a.empty? ? issue_events : a
    end

    def retrieve_issue_event(owner, repo, issue_id, event_id)
      event = persister.find(:issue_events, { 'repo' => repo,
                                              'owner' => owner,
                                              'issue_id' => issue_id,
                                              'id' => event_id }).first
      if event.nil?
        r = api_request(ghurl("repos/#{owner}/#{repo}/issues/events/#{event_id}"))

        if r.nil? or r.empty?
          warn "Could not find issue_event #{owner}/#{repo} #{issue_id}->#{event_id}. Deleted?"
          return
        end

        r['repo'] = repo
        r['owner'] = owner
        r['issue_id'] = issue_id
        persister.store(:issue_events, r)
        info "Added issue_event #{owner}/#{repo} #{issue_id}->#{event_id}"
        a = persister.find(:issue_events, { 'repo' => repo, 'owner' => owner,
                                            'issue_id' => issue_id,
                                            'id' => event_id }).first
        a.nil? ? r : a
      else
        debug "Issue event #{owner}/#{repo} #{issue_id}->#{event_id} exists"
        event
      end
    end

    def retrieve_issue_comments(owner, repo, issue_id)
      url = ghurl "repos/#{owner}/#{repo}/issues/#{issue_id}/comments"
      retrieved_comments = paged_api_request url

      comments = retrieved_comments.each do |x|
        x['owner'] = owner
        x['repo'] = repo
        x['issue_id'] = issue_id

        next unless persister.find(:issue_comments, { 'owner' => owner,
                                                      'repo' => repo,
                                                      'issue_id' => issue_id,
                                                      'id' => x['id'] }).empty?

        persister.store(:issue_comments, x)
      end
      a = persister.find(:issue_comments, { 'owner' => owner, 'repo' => repo,
                                            'issue_id' => issue_id })
      a.empty? ? comments : a
    end

    def retrieve_issue_comment(owner, repo, issue_id, comment_id)
      comment = persister.find(:issue_comments, { 'repo' => repo,
                                                  'owner' => owner,
                                                  'issue_id' => issue_id,
                                                  'id' => comment_id }).first
      if comment.nil?
        r = api_request(ghurl("repos/#{owner}/#{repo}/issues/comments/#{comment_id}"))

        if r.nil? or r.empty?
          warn "Could not find issue_comment #{owner}/#{repo} #{issue_id}->#{comment_id}. Deleted?"
          return
        end

        r['repo'] = repo
        r['owner'] = owner
        r['issue_id'] = issue_id
        persister.store(:issue_comments, r)
        info "Added issue_comment #{owner}/#{repo} #{issue_id}->#{comment_id}"
        a = persister.find(:issue_comments, { 'repo' => repo, 'owner' => owner,
                                              'issue_id' => issue_id,
                                              'id' => comment_id }).first
        a.nil? ? r : a
      else
        debug "Issue comment #{owner}/#{repo} #{issue_id}->#{comment_id} exists"
        comment
      end
    end

    def retrieve_repo_labels(owner, repo, refr = false)
      repo_bound_items(owner, repo, :repo_labels,
                       ["repos/#{owner}/#{repo}/labels"],
                       { 'repo' => repo, 'owner' => owner },
                       'name', nil, refr, :asc)
    end

    def retrieve_repo_label(owner, repo, name)
      repo_bound_item(owner, repo, name, :repo_labels,
                      ["repos/#{owner}/#{repo}/labels"],
                      { 'repo' => repo, 'owner' => owner },
                      'name')
    end

    def retrieve_issue_labels(owner, repo, issue_id)
      url = ghurl("repos/#{owner}/#{repo}/issues/#{issue_id}/labels")
      paged_api_request(url)
    end

    def retrieve_topics(owner, repo)
      # volatile: currently available with api preview
      # https://developer.github.com/v3/repos/#list-all-topics-for-a-repository
      stored_topics = persister.find(:topics, { 'owner' => owner, 'repo' => repo })

      url = ghurl("repos/#{owner}/#{repo}/topics")
      r = api_request(url, 'application/vnd.github.mercy-preview+json')

      if r.nil? or r.empty? or r['names'].nil? or r['names'].empty?
        warn "No topics for #{owner}/#{repo}"
        return []
      end

      topics = r['names']
      return [] if topics.nil? or topics.empty?

      topics.each do |topic|
        if stored_topics.select { |x| x['topic'] == topic }.empty?
          topic_entry = {
            owner: owner,
            repo: repo,
            topic: topic
          }
          persister.store(:topics, topic_entry)
          info "Added topic #{topic} -> #{owner}/#{repo}"
        else
          debug "Topic #{topic} -> #{owner}/#{repo} exists"
        end
      end

      r['names']
    end

    # Get current Github events
    def get_events
      api_request 'https://api.github.com/events'
    end

    # Get all events for the specified repo.
    # GitHub will only return 90 days of events
    def get_repo_events(owner, repo)
      url = ghurl("repos/#{owner}/#{repo}/events")
      r = paged_api_request(url)

      r.each do |e|
        if get_event(e['id']).empty?
          persister.store(:events, e)
          info "Added event for repository #{owner}/#{repo} -> #{e['type']}-#{e['id']}"
        else
          debug "Repository event #{owner}/#{repo} -> #{e['type']}-#{e['id']} already exists"
        end
      end

      persister.find(:events, { 'repo.name' => "#{owner}/#{repo}" })
    end

    # Get a specific event by +id+.
    def get_event(id)
      persister.find(:events, { 'id' => id })
    end

    # Retrieve diff between two branches. If either branch name is not provided
    # the branch name is resolved to the corresponding default branch
    def retrieve_master_branch_diff(owner, repo, branch, parent_owner, parent_repo, parent_branch)
      branch = retrieve_default_branch(owner, repo) if branch.nil?
      parent_branch = retrieve_default_branch(parent_owner, parent_repo) if parent_branch.nil?
      return nil if branch.nil? or parent_branch.nil?

      cmp_url = "https://api.github.com/repos/#{parent_owner}/#{parent_repo}/compare/#{parent_branch}...#{owner}:#{branch}"
      api_request(cmp_url)
    end

    # Retrieve the default branch for a repo. If nothing is retrieved, 'master' is returned
    def retrieve_default_branch(owner, repo, refresh = false)
      retrieved = retrieve_repo(owner, repo, refresh)
      return nil if retrieved.nil?

      master_branch = 'master'
      if retrieved['default_branch'].nil?
        # The currently stored repo entry has been created before the
        # default_branch field was added to the schema
        retrieved = retrieve_repo(owner, repo, true)
        return nil if retrieved.nil?
      end
      master_branch = retrieved['default_branch'] unless retrieved.nil?
      master_branch
    end

    private

    def restricted_page_request(url, pages)
      if pages != -1
        paged_api_request(url, pages)
      else
        paged_api_request(url)
      end
    end

    def repo_bound_items(user, repo, entity, urls, selector, discriminator,
                         item_id = nil, refresh = false, order = :asc, media_type = '')
      urls.each do |url|
        total_pages = num_pages(ghurl(url))

        page_range = if order == :asc
                       (1..total_pages)
                     else
                       total_pages.downto(1)
                     end

        page_range.each do |page|
          items = api_request(ghurl(url, page), media_type)
          break if items.nil?

          items.each do |x|
            x['repo'] = repo
            x['owner'] = user

            instances = repo_bound_instance(entity, selector,
                                            discriminator, x[discriminator])
            exists = !instances.empty?

            if exists
              if refresh
                instances.each do |i|
                  id = if i[discriminator].to_i.to_s != i[discriminator]
                         i[discriminator] # item_id is int
                       else
                         i[discriminator].to_i # convert to int
                       end

                  instance_selector = selector.merge({ discriminator => id })
                  persister.upsert(entity, instance_selector, x)
                  debug "Refreshing #{entity} #{user}/#{repo} -> #{x[discriminator]}"
                end
              else
                debug "#{entity} #{user}/#{repo} -> #{x[discriminator]} exists"
              end
            else
              x = api_request(x['url'], media_type)
              break if x.nil?

              x['repo'] = repo
              x['owner'] = user
              persister.store(entity, x)
              info "Added #{entity} #{user}/#{repo} -> #{x[discriminator]}"
            end

            # If we are just looking for a single item, give the method a chance
            # to return as soon as we find it. This is to avoid loading all
            # items before we actually search for what we are looking for.
            unless item_id.nil?
              a = repo_bound_instance(entity, selector, discriminator, item_id)
              return a unless a.empty?
            end
          end
        end
      end

      if item_id.nil?
        persister.find(entity, selector)
      else
        # If the item we are looking for has been found, the method should
        # have returned earlier. So just return an empty result to indicate
        # that the item has not been found.
        []
      end
    end

    def repo_bound_item(user, repo, item_id, entity, url, selector,
                        discriminator, order = :asc, media_type = '')
      stored_item = repo_bound_instance(entity, selector, discriminator, item_id)

      r = if stored_item.empty?
            repo_bound_items(user, repo, entity, url, selector, discriminator,
                             item_id, false, order, media_type).first
          else
            stored_item.first
          end
      warn "Could not find #{entity} #{user}/#{repo} -> #{item_id}. Deleted?" if r.nil?
      r
    end

    def repo_bound_instance(entity, selector, discriminator, item_id)
      id = if item_id.to_i.to_s != item_id
             item_id # item_id is int
           else
             item_id.to_i # convert to int
           end

      instance_selector = selector.merge({ discriminator => id })
      result = persister.find(entity, instance_selector)
      if result.empty?
        # Try without type conversions. Useful when the discriminator type
        # is string and an item_id that can be converted to int is passed.
        # Having no types sucks occasionaly...
        instance_selector = selector.merge({ discriminator => item_id })
        persister.find(entity, instance_selector)
      else
        result
      end
    end

    def retrieve_workflows(owner, repo)
      currepo = ensure_repo(owner, repo)
      if currepo.nil?
        warn "Could not find repo #{owner}/#{repo} for retrieving workflows"
        return []
      end
    
      info "Retrieving workflows for #{owner}/#{repo}"
      workflows = []
      existing_ids = []
    
      persister.find(:workflows, { 'owner' => owner, 'repo' => repo }).each do |existing|
        existing_ids << existing[:github_id]
      end
    
      response = api_request(ghurl("repos/#{owner}/#{repo}/actions/workflows"))
      # debug "Raw API response: #{response.inspect}"
      # debug "response['workflows']: #{response['workflows'].inspect}" # Thêm để debug
      workflows_array = []
      if response && response["workflows"].is_a?(Array)
        workflows_array = response["workflows"]
      else
        # warn "Invalid or empty workflows response: #{response.inspect}"
        warn "Invalid or empty workflows response!"
      end
      # debug "workflows_array: #{workflows_array.inspect}"
    
      workflows_array.each do |workflow|
        workflow_id = workflow["id"].to_i
        next if existing_ids.include?(workflow_id)
    
        workflows << workflow
        existing_ids << workflow_id
        persister.store(:workflows, {
          github_id: workflow_id,
          name: workflow["name"],
          path: workflow["path"],
          state: workflow["state"],
          created_at: Time.parse(workflow["created_at"]),
          updated_at: Time.parse(workflow["updated_at"]),
          owner: owner,
          repo: repo,
          html_url: workflow["html_url"],
        })
        info "Added workflow #{owner}/#{repo} -> #{workflow_id}"
        # retrieve_workflow_runs(owner, repo, workflow_id)
      end
    
      info "API returned #{workflows.size} workflows for #{owner}/#{repo}"
      workflows
    end

    def retrieve_workflow_runs(owner, repo, workflow_id)
      currepo = ensure_repo(owner, repo)
      if currepo.nil?
        warn "Could not find repo #{owner}/#{repo} for retrieving workflow runs"
        return []
      end
    
      workflow_id = workflow_id.to_i
      info "Retrieving workflow runs for workflow #{workflow_id} in #{owner}/#{repo}"
      workflow_runs = []
      existing_ids = []
    
      persister.find(:workflow_runs, { 'owner' => owner, 'repo' => repo, 'workflow_id' => workflow_id }).each do |existing|
        existing_ids << existing[:github_id]
      end
    
      response = api_request(ghurl("repos/#{owner}/#{repo}/actions/workflows/#{workflow_id}/runs"))
      # debug "Raw API response for workflow runs: #{response.inspect}"
      runs_array = []
      if response && response["workflow_runs"].is_a?(Array)
        runs_array = response["workflow_runs"]
      else
        # warn "Invalid or empty workflow runs response: #{response.inspect}"
        warn "Invalid or empty workflow runs response!"
      end
      # debug "runs_array: #{runs_array.inspect}"
    
      runs_array.each do |run|
        run_id = run["id"].to_i
        next if existing_ids.include?(run_id)
    
        workflow_runs << run
        existing_ids << run_id
        persister.store(:workflow_runs, {
          github_id: run_id,
          workflow_id: workflow_id,
          name: run["name"],
          head_branch: run["head_branch"],
          head_sha: run["head_sha"],
          run_number: run["run_number"],
          status: run["status"],
          conclusion: run["conclusion"],
          created_at: Time.parse(run["created_at"]),
          run_started_at: Time.parse(run["run_started_at"]),
          updated_at: Time.parse(run["updated_at"]),
          event: run["event"],
          path: run["path"],
          run_attempt: run["run_attempt"],
          display_title: run["display_title"],
          owner: owner,
          repo: repo,
          html_url: run["html_url"],
          actor: {
            login: run["actor"]["login"],
            avatar_url: run["actor"]["avatar_url"],
            html_url: run["actor"]["html_url"]
          },
          triggering_actor: {
            login: run["triggering_actor"]&.[]("login"),
            avatar_url: run["triggering_actor"]&.[]("avatar_url"),
            html_url: run["triggering_actor"]&.[]("html_url")
          }
        })
        info "Added workflow run #{run_id} for workflow #{workflow_id} in #{owner}/#{repo}"
      end
    
      info "API returned #{workflow_runs.size} workflow runs for workflow #{workflow_id} in #{owner}/#{repo}"
      workflow_runs
    end

    def ghurl(path, page = -1, per_page = 100)
      if page > 0
        path += if path.include?('?')
                  "&page=#{page}&per_page=#{per_page}"
                else
                  "?page=#{page}&per_page=#{per_page}"
                end
        config(:mirror_urlbase) + path
      else
        path += if path.include?('?')
                  "&per_page=#{per_page}"
                else
                  "?per_page=#{per_page}"
                end
        config(:mirror_urlbase) + path
      end
    end
  end
end
