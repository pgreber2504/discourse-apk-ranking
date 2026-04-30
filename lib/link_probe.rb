# frozen_string_literal: true

module ::DiscourseApkRanking
  # SSRF-safe HTTP probing and streaming download that transparently
  # follow redirects.
  #
  # Why this exists: GitHub release downloads (and most CDN-backed file
  # hosts: GitLab, Bitbucket, S3 presigned URLs, etc.) reply with a 302
  # to a short-lived signed URL on every request. `Net::HTTP` does not
  # follow redirects on its own, so a single-hop probe sees the 302 and
  # the consistency check fails with "Could not download file (HTTP 302)".
  #
  # Each hop goes through `FinalDestination::HTTP.start`, so SSRF
  # protection is enforced per redirect (the signed URL host is resolved
  # and IP-filtered just like the original).
  module LinkProbe
    USER_AGENT = "Mozilla/5.0 (compatible; DiscourseBot/1.0; +https://discourse.org)"
    MAX_REDIRECTS = 5

    ProbeResult = Struct.new(
      :ok, :code, :content_type, :content_disposition, :content_length,
      :link_type, :final_url, :error,
      keyword_init: true,
    )

    DownloadResult = Struct.new(
      :code, :bytes_read, :truncated, :content_type, :error,
      keyword_init: true,
    )

    # Probe a URL with HEAD (falling back to GET Range: bytes=0-0 when
    # the server rejects HEAD with 403/405/501) and follow up to
    # MAX_REDIRECTS hops. The returned `code` is the *terminal* HTTP
    # status; `final_url` is the resolved URL after redirects.
    def self.probe(url, open_timeout: 10, read_timeout: 10)
      uri = URI.parse(url)
      response = nil
      hops = 0

      loop do
        response = perform_head(uri, open_timeout: open_timeout, read_timeout: read_timeout)
        break unless redirect?(response.code.to_i)

        location = response["location"]
        break if location.blank?

        hops += 1
        return too_many_redirects(url) if hops > MAX_REDIRECTS

        next_uri = resolve_location(uri, location)
        break unless next_uri
        uri = next_uri
      end

      build_probe_result(url, uri, response)
    rescue StandardError => e
      ProbeResult.new(
        ok: false, code: nil, content_type: nil, content_disposition: nil,
        content_length: 0, link_type: nil, final_url: nil, error: e.message,
      )
    end

    # Stream a URL's body to the given block, following redirects. The
    # block receives raw byte chunks of the terminal 2xx response only;
    # redirect bodies are discarded. Returns a DownloadResult with the
    # terminal HTTP code, total bytes yielded, and a `truncated` flag if
    # `max_size` was hit (the block receives no further chunks once the
    # cap is reached).
    def self.stream_download(url, max_size:, open_timeout: 10, read_timeout: 60, &block)
      raise ArgumentError, "block required" unless block_given?

      uri = URI.parse(url)
      hops = 0
      terminal_code = nil
      terminal_content_type = nil
      bytes_read = 0
      truncated = false

      loop do
        next_location = nil

        # `throw :done` jumps out of the inner Net::HTTP block; the
        # surrounding `FinalDestination::HTTP.start` ensures the socket
        # is closed even on abrupt exit (size cap or future early aborts).
        catch(:done) do
          FinalDestination::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: open_timeout, read_timeout: read_timeout,
          ) do |http|
            request = Net::HTTP::Get.new(uri.request_uri)
            request["User-Agent"] = USER_AGENT
            request["Accept"] = "*/*"

            http.request(request) do |response|
              terminal_code = response.code.to_i
              terminal_content_type = response["content-type"].to_s.downcase

              if redirect?(terminal_code)
                next_location = response["location"]
                # Skip the body — redirect responses are typically empty
                # and we'll re-request against the new URL.
                throw :done
              end

              throw :done unless terminal_code.between?(200, 299)

              response.read_body do |chunk|
                if bytes_read + chunk.bytesize > max_size
                  truncated = true
                  throw :done
                end
                bytes_read += chunk.bytesize
                block.call(chunk)
              end
            end
          end
        end

        break if next_location.blank?

        hops += 1
        if hops > MAX_REDIRECTS
          return DownloadResult.new(
            code: terminal_code, bytes_read: bytes_read, truncated: truncated,
            content_type: terminal_content_type,
            error: "Too many redirects (>#{MAX_REDIRECTS})",
          )
        end

        next_uri = resolve_location(uri, next_location)
        break unless next_uri
        uri = next_uri
      end

      DownloadResult.new(
        code: terminal_code, bytes_read: bytes_read, truncated: truncated,
        content_type: terminal_content_type, error: nil,
      )
    rescue StandardError => e
      DownloadResult.new(
        code: terminal_code, bytes_read: bytes_read, truncated: truncated,
        content_type: terminal_content_type, error: e.message,
      )
    end

    def self.perform_head(uri, open_timeout:, read_timeout:)
      FinalDestination::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: open_timeout, read_timeout: read_timeout,
      ) do |http|
        head = Net::HTTP::Head.new(uri.request_uri)
        head["User-Agent"] = USER_AGENT
        head["Accept"] = "*/*"
        response = http.request(head)

        if response.code.to_i.in?([403, 405, 501])
          get = Net::HTTP::Get.new(uri.request_uri)
          get["User-Agent"] = USER_AGENT
          get["Accept"] = "*/*"
          get["Range"] = "bytes=0-0"
          response = http.request(get)
        end

        response
      end
    end
    private_class_method :perform_head

    def self.redirect?(code)
      code.between?(300, 399)
    end
    private_class_method :redirect?

    def self.resolve_location(base_uri, location)
      parsed = URI.parse(location)
      parsed = base_uri + parsed if parsed.relative?
      parsed
    rescue URI::Error
      nil
    end
    private_class_method :resolve_location

    def self.build_probe_result(original_url, final_uri, response)
      code = response.code.to_i
      content_type = response["content-type"].to_s.downcase
      content_disposition = response["content-disposition"].to_s.downcase
      is_html = content_type.include?("text/html")
      is_download = content_disposition.include?("attachment") ||
        content_type.include?("application/") ||
        content_type.include?("binary") ||
        original_url.match?(/\.apk\z/i)

      ProbeResult.new(
        ok: code.between?(200, 299),
        code: code,
        content_type: content_type,
        content_disposition: content_disposition,
        content_length: response["content-length"].to_i,
        link_type: (is_html && !is_download) ? "webpage" : "file",
        final_url: final_uri.to_s,
        error: nil,
      )
    end
    private_class_method :build_probe_result

    def self.too_many_redirects(url)
      ProbeResult.new(
        ok: false, code: nil, content_type: nil, content_disposition: nil,
        content_length: 0, link_type: nil, final_url: url,
        error: "Too many redirects (>#{MAX_REDIRECTS})",
      )
    end
    private_class_method :too_many_redirects
  end
end
