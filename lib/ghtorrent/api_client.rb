require 'open-uri'
require 'net/http'
require 'digest/sha1'
require 'fileutils'
require 'json'

require 'ghtorrent/logging'
require 'ghtorrent/settings'
require 'ghtorrent/ghtime'
require 'version'

module GHTorrent
  module APIClient
    include GHTorrent::Logging
    include GHTorrent::Settings
    include GHTorrent::Logging

    # A paged request. Used when the result can expand to more than one
    # result pages.
    def paged_api_request(url, pages = config(:mirror_history_pages_back),
                          last = nil)

      url = ensure_max_per_page(url)
      data = api_request_raw(url)

      return [] if data.nil?

      unless data.meta['link'].nil?
        links = parse_links(data.meta['link'])
        last = links['last'] if last.nil?

        if pages > 0
          pages = pages - 1
          if pages == 0
            return parse_request_result(data)
          end
        end

        if links['next'].nil?
          parse_request_result(data)
        else
          parse_request_result(data) | paged_api_request(links['next'], pages, last)
        end
      else
        parse_request_result(data)
      end
    end


    # A normal request. Returns a hash or an array of hashes representing the
    # parsed JSON result. The media type
    def api_request(url, media_type = '')
      parse_request_result api_request_raw(ensure_max_per_page(url), media_type)
    end

    # Return the last modified time for the resource identified by the provided
    # URL, as returned from GitHub.
    def last_updated(url, etag)
      begin
        ts = Time.now
        response = do_request(url, '', fmt_etag(etag))
        info "Successful etag request. URL: #{url}, HTTP: #{response.status.first}, old_etag: #{fmt_etag(etag)}, new_etag: #{fmt_etag(response.meta['etag'])}, Remaining: #{@remaining}, Total: #{Time.now.to_ms - ts.to_ms} ms"
      rescue OpenURI::HTTPError => e
        response = e.io
        if response.status.first != '304'
          info "Successful etag request. URL: #{url}, HTTP: 304, etag: #{fmt_etag(etag)}, Remaining: #{@remaining}, Total: #{Time.now.to_ms - ts.to_ms} ms"
          etag_request_error_message(url, e, etag)
          raise e
        end
      end

      return Time.parse(response.meta['last-modified']) unless response.meta['last-modified'].nil?
      return Time.at(86400)
    end

    # Determine the number of pages contained in a multi-page API response
    def num_pages(url)
      url = ensure_max_per_page(url)
      data = api_request_raw(url)

      if data.nil? or data.meta.nil? or data.meta['link'].nil?
        return 1
      end

      links = parse_links(data.meta['link'])

      if links.nil? or links['last'].nil?
        return 1
      end

      params = CGI::parse(URI::parse(links['last']).query)
      params['page'][0].to_i
    end

    private

    def ensure_max_per_page(url)
      if url.include?('page')
        if not url.include?('per_page')
          if url.include?('?')
            url + '&per_page=100'
          else
            url + '?per_page=100'
          end
        else
          url
        end
      else
        url
      end
    end

    # Parse a Github link header
    def parse_links(links)
      links.split(/,/).reduce({}) do |acc, x|
        matches = x.strip.match(/<(.*)>; rel=\"(.*)\"/)
        acc[matches[2]] = matches[1]
        acc
      end
    end

    # Parse the JSON result array
    def parse_request_result(result)
      if result.nil?
        []
      else
        json = result.read

        if json.nil?
          []
        else
          begin
            r = JSON.parse(json)

            # Thêm etag nếu là object
            if result.meta['etag'] && r.class != Array
              r['etag'] = fmt_etag(result.meta['etag'])
            end

            r
          rescue JSON::ParserError => e
            warn "[WARNING] Skipping invalid JSON: #{e.message}"
            warn "[URL] #{result.meta['uri'] rescue 'unknown'}"
            return []  # hoặc nil, tuỳ logic tiếp theo
          end
        end
      end
    end

    def fmt_etag(etag)
      etag.tr('W"/','') unless etag.nil?
    end

    def fmt_token(token)
      if token.nil? or token.empty?
        '<empty-token>'
      else
        token[0..10]
      end
    end

    def request_error_msg(url, exception)
      msg = <<-MSG
            Failed request. URL: #{url}, Status code: #{exception.io.status[0]},
            Status: #{exception.io.status[1]},
            Access: #{fmt_token(@token)},
            IP: #{@attach_ip}, Remaining: #{@remaining}
      MSG
      msg.strip.gsub(/\s+/, ' ').gsub("\n", ' ')
    end

    def error_msg(url, exception)
      msg = <<-MSG
            Failed request. URL: #{url}, Exception: #{exception.message},
            Access: #{fmt_token(@token)},
            IP: #{@attach_ip}, Remaining: #{@remaining}
      MSG
      msg.strip.gsub(/\s+/, ' ').gsub("\n", ' ')
    end

    def etag_request_error_message(url, exception, etag)
      request_error_msg(url, exception) + " etag: #{etag}"
    end

    # Do the actual request and return the result object
    def api_request_raw(url, media_type = '')

      begin
        start_time = Time.now

        contents = do_request(url, media_type)
        total = Time.now.to_ms - start_time.to_ms
        info "Successful request. URL: #{url}, Remaining: #{@remaining}, Total: #{total} ms"

        contents
      rescue OpenURI::HTTPError => e
        @remaining = e.io.meta['x-ratelimit-remaining'].to_i
        @reset = e.io.meta['x-ratelimit-reset'].to_i

        case e.io.status[0].to_i
          # The following indicate valid Github return codes
          when 400, # Bad request
              403, # Forbidden
              404, # Not found
              409, # Conflict -- returned on gets of empty repos
              422 then # Unprocessable entity
            warn request_error_msg(url, e)
            return nil
          when 401 # Unauthorized
            warn request_error_msg(url, e)
            warn "Unauthorised request with token: #{@token}"
            raise e
          when 451 # DMCA takedown
            warn request_error_msg(url, e)
            warn "Repo was taken down (DMCA)"
            return nil
          else # Server error or HTTP conditions that Github does not report
            warn request_error_msg(url, e)
            raise e
        end
      rescue StandardError => e
        warn error_msg(url, e)
        raise e
      ensure
        # The exact limit is only enforced upon the first @reset
        # No idea how many requests are available on this key. Sleep if we have run out
        if @remaining < @req_limit
          to_sleep = @reset - Time.now.to_i + 2
          warn "Request limit reached, reset in: #{to_sleep} secs"
          t = Thread.new do
            slept = 0
            while true do
              debug "Sleeping for #{to_sleep - slept} seconds"
              sleep 1
              slept += 1
            end
          end
          sleep([0, to_sleep].max)
          t.exit
        end
      end
    end

    def auth_method(token)
      return :token unless token.nil? or token.empty?
      return :none
    end

    def do_request(url, media_type, etag = nil)
      @attach_ip  ||= config(:attach_ip)
      @token      ||= config(:github_token)
      @user_agent ||= config(:user_agent)
      @remaining  ||= 5000
      @reset      ||= Time.now.to_i + 3600
      @auth_type  ||= auth_method(@token)
      @req_limit  ||= config(:req_limit)
      media_type = 'application/json' unless media_type.size > 0

      headers = {
        'User-Agent' => @user_agent,
        'Accept' => media_type
      }

      headers = headers.merge({ 'Authorization' => "token #{@token}" }) if auth_method(@token) == :token
      headers = headers.merge({ 'If-None-Match' => etag }) if etag

      # Encode square brackets if needed
      if url =~ %r{\[|\]}
        protocol, host, path = url.split(%r{/+}, 3)
        path = path.gsub('[', '%5B').gsub(']', '%5D')
        url = "#{protocol}//#{host}/#{path}"
      end

      attempt = 0
      begin
        attempt += 1
        result = URI.open(
          url,
          **headers.transform_keys(&:downcase),
          open_timeout: 20,  # tăng timeout kết nối
          read_timeout: 20   # tăng timeout đọc phản hồi
        )

        @remaining = result.meta['x-ratelimit-remaining'].to_i
        @reset = result.meta['x-ratelimit-reset'].to_i
        result
      rescue OpenURI::HTTPError => e
        raise e
      rescue Net::OpenTimeout, Net::ReadTimeout, EOFError, OpenSSL::SSL::SSLError => e
        warn "[WARN] Timeout on #{url}: #{e.class} - #{e.message}"
        retry if attempt < 3
        warn "[SKIP] Failed after 3 attempts: #{url}"
        nil
      end
    end

    # Attach to a specific IP address if the machine has multiple
    def attach_to(ip)
      TCPSocket.instance_eval do
        (class << self; self; end).instance_eval do
          alias_method :original_open, :open

          case RUBY_VERSION
            when /1.8/, /1.9/
              define_method(:open) do |conn_address, conn_port|
                original_open(conn_address, conn_port, ip)
              end
            else
              define_method(:open) do |conn_address, conn_port, local_host, local_port|
                original_open(conn_address, conn_port, ip, local_port)
              end
          end
        end
      end

      result = begin
        yield
      rescue StandardError => e
        raise e
      ensure
        TCPSocket.instance_eval do
          (class << self; self; end).instance_eval do
            alias_method :open, :original_open
            remove_method :original_open
          end
        end
      end

      result
    end

  end
end
