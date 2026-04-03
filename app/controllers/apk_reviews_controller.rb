# frozen_string_literal: true

require "digest"

class ::ApkReviewsController < ::ApplicationController
  requires_plugin "discourse-apk-ranking"

  LINK_CHECK_UA = "Mozilla/5.0 (compatible; DiscourseBot/1.0; +https://discourse.org)"

  before_action :ensure_logged_in, except: %i[index show]

  def index
    page = params[:page].to_i
    per_page = 20

    reviews =
      ApkReview
        .includes(:topic, :user)
        .offset(page * per_page)
        .limit(per_page)

    render json: {
      reviews: reviews.map { |r| ApkReviewSerializer.new(r, root: false).as_json },
      total_count: ApkReview.count,
    }
  end

  def show
    review = ApkReview.find_by(topic_id: params[:id])

    if review
      render json: { review: ApkReviewSerializer.new(review, root: false).as_json }
    else
      render json: { error: "Review not found" }, status: 404
    end
  end

  def create
    topic = Topic.find_by(id: params[:topic_id])

    unless topic
      return render json: { error: "Topic not found" }, status: 404
    end

    unless topic.category&.slug == SiteSetting.sideloaded_apps_category_slug
      return render json: { error: "Topic must be in the Sideloaded Apps Ranking category" }, status: 422
    end

    unless current_user.id == topic.user_id || current_user.staff?
      return render json: { error: "You can only create a review for your own topic" }, status: 403
    end

    if ApkReview.exists?(topic_id: topic.id)
      return render json: { error: "A review already exists for this topic. Use PUT to update." }, status: 422
    end

    review = ApkReview.new(review_params)
    review.topic_id = topic.id
    review.user_id = current_user.id
    review.last_access_date = Time.current

    if review.save
      render json: { review: ApkReviewSerializer.new(review, root: false).as_json }, status: 201
    else
      render json: { errors: review.errors.full_messages }, status: 422
    end
  end

  def update
    review = ApkReview.find_by(topic_id: params[:id])

    unless review
      return render json: { error: "Review not found" }, status: 404
    end

    unless current_user.id == review.user_id || current_user.staff?
      return render json: { error: "You can only update your own review" }, status: 403
    end

    old_attrs = review.attributes.slice(
      "apk_version", "apk_link", "app_description", "known_issues",
      "author_rating", "apk_checksum",
    )

    if review.update(review_params)
      create_edit_audit_post(review, old_attrs)

      # When APK link changes, re-verify and update the verification record
      verification_data = nil
      if old_attrs["apk_link"] != review.apk_link
        verification_data = refresh_verification_after_edit(review)
      end

      response = { review: ApkReviewSerializer.new(review.reload, root: false).as_json }
      response[:verification] = verification_data if verification_data
      render json: response
    else
      render json: { errors: review.errors.full_messages }, status: 422
    end
  end

  def track_download
    review = ApkReview.find_by(topic_id: params[:topic_id])
    return render json: { error: "Review not found" }, status: 404 unless review
    return render json: { error: "No APK link" }, status: 422 if review.apk_link.blank?

    uri = URI.parse(review.apk_link)
    response = probe_url(uri, open_timeout: 5, read_timeout: 5)

    if response.code.to_i.between?(200, 399)
      review.update_column(:last_access_date, Time.current)
      render json: {
        success: true,
        last_access_date: review.last_access_date,
        apk_link: review.apk_link,
      }
    else
      render json: {
        success: false,
        error: "File not accessible (HTTP #{response.code})",
        apk_link: review.apk_link,
      }
    end
  rescue StandardError => e
    render json: {
      success: false,
      error: "Could not reach the file: #{e.message}",
      apk_link: review&.apk_link,
    }
  end

  def validate_link
    url = params[:url].to_s.strip
    return render json: { valid: false, reason: I18n.t("js.sideloaded_apps.link_validation.url_required") }, status: 422 if url.blank?

    uri = URI.parse(url)
    return render json: { valid: false, reason: I18n.t("js.sideloaded_apps.link_validation.invalid_scheme") }, status: 422 unless %w[http https].include?(uri.scheme)

    response = probe_url(uri, open_timeout: 10, read_timeout: 10)

    content_type = response["content-type"].to_s.downcase
    content_disposition = response["content-disposition"].to_s.downcase
    file_size = response["content-length"].to_i

    is_html = content_type.include?("text/html")
    is_download =
      content_disposition.include?("attachment") || content_type.include?("application/") ||
        content_type.include?("binary") || url.match?(/\.apk\z/i)

    if !response.code.to_i.between?(200, 399)
      render json: {
               valid: false,
               is_direct_download: false,
               content_type: content_type,
               file_size: file_size,
               reason: I18n.t("js.sideloaded_apps.link_validation.http_error", code: response.code),
             }
    elsif is_html && !is_download
      render json: {
               valid: true,
               is_direct_download: false,
               content_type: content_type,
               file_size: file_size,
             }
    else
      render json: { valid: true, is_direct_download: true, content_type: content_type, file_size: file_size }
    end
  rescue URI::InvalidURIError
    render json: { valid: false, reason: I18n.t("js.sideloaded_apps.link_validation.invalid_url") }
  rescue StandardError => e
    render json: { valid: false, reason: I18n.t("js.sideloaded_apps.link_validation.unreachable", message: e.message) }
  end

  MAX_DOWNLOAD_SIZE = 500.megabytes
  DOWNLOAD_TIMEOUT = 60

  def compute_checksum
    url = params[:url].to_s.strip
    return render json: { error: I18n.t("js.sideloaded_apps.link_validation.url_required") }, status: 422 if url.blank?

    uri = URI.parse(url)
    unless %w[http https].include?(uri.scheme)
      return render json: { error: I18n.t("js.sideloaded_apps.link_validation.invalid_scheme") }, status: 422
    end

    sha256 = Digest::SHA256.new
    total_bytes = 0
    valid_download = false

    FinalDestination::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 10,
      read_timeout: DOWNLOAD_TIMEOUT,
    ) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = LINK_CHECK_UA
      request["Accept"] = "*/*"
      http.request(request) do |response|
        unless response.code.to_i.between?(200, 299)
          return(
            render json: {
                     valid_download: false,
                     reason: I18n.t("js.sideloaded_apps.link_validation.http_error", code: response.code),
                   }
          )
        end

        content_type = response["content-type"].to_s.downcase
        if content_type.include?("text/html")
          return(
            render json: {
                     valid_download: false,
                     reason: I18n.t("js.sideloaded_apps.link_validation.not_a_download"),
                   }
          )
        end

        valid_download = true

        response.read_body do |chunk|
          total_bytes += chunk.bytesize
          if total_bytes > MAX_DOWNLOAD_SIZE
            return(
              render json: {
                       valid_download: false,
                       reason: I18n.t("js.sideloaded_apps.link_validation.file_too_large", max_mb: MAX_DOWNLOAD_SIZE / 1.megabyte),
                     }
            )
          end
          sha256.update(chunk)
        end
      end
    end

    computed = sha256.hexdigest
    user_checksum = params[:user_checksum].to_s.strip.downcase
    user_checksum_match =
      if user_checksum.present?
        computed == user_checksum
      end

    render json: {
             valid_download: valid_download,
             checksum: computed,
             file_size: total_bytes,
             user_checksum_match: user_checksum_match,
           }
  rescue URI::InvalidURIError
    render json: { valid_download: false, reason: I18n.t("js.sideloaded_apps.link_validation.invalid_url") }
  rescue StandardError => e
    render json: { valid_download: false, reason: I18n.t("js.sideloaded_apps.link_validation.unreachable", message: e.message) }
  end

  def rate
    topic = Topic.find_by(id: params[:topic_id])
    return render json: { error: "Topic not found" }, status: 404 unless topic
    return render json: { error: "Not in sideloaded apps category" }, status: 422 unless topic.category&.slug == SiteSetting.sideloaded_apps_category_slug

    if topic.user_id == current_user.id
      return render json: { error: "You cannot rate your own review" }, status: 422
    end

    rating = params[:rating].to_i
    return render json: { error: "Rating must be between 1 and 5" }, status: 422 unless rating.between?(1, 5)

    PluginStore.set("sideloaded_ratings", "t#{topic.id}_u#{current_user.id}", rating)

    community = ApkReview.community_rating_for(topic.id)
    render json: {
      success: true,
      user_rating: rating,
      community_average: community[:average],
      community_count: community[:count],
    }
  end

  def verify_now
    review = ApkReview.find_by(topic_id: params[:topic_id])
    return render json: { error: "Review not found" }, status: 404 unless review
    return render json: { error: "No link to verify" }, status: 422 if review.apk_link.blank?

    uri = URI.parse(review.apk_link)
    response = probe_url(uri)
    code = response.code.to_i

    content_type = response["content-type"].to_s.downcase
    is_html = content_type.include?("text/html")
    is_download = response["content-disposition"].to_s.downcase.include?("attachment") ||
      content_type.include?("application/") ||
      content_type.include?("binary") ||
      review.apk_link.match?(/\.apk\z/i)

    verification = ApkVerification.find_or_initialize_by(topic_id: review.topic_id)
    verification.link_type = (is_html && !is_download) ? "webpage" : "file"

    if code.between?(200, 399)
      verification.availability_status = "available"
      verification.availability_description = "Link is accessible (HTTP #{code})"
      review.update_column(:last_access_date, Time.current)
    else
      verification.availability_status = "unavailable"
      verification.availability_description = "Link returned HTTP #{code}"
    end
    verification.last_http_status = code

    if verification.availability_status == "available" && review.apk_checksum.present?
      checksum_result = compute_checksum_for(review.apk_link, review.apk_checksum)
      verification.consistency_status = checksum_result[:status]
      verification.consistency_description = checksum_result[:description]
      verification.last_computed_checksum = checksum_result[:checksum]
    elsif review.apk_checksum.blank?
      verification.consistency_status = "unknown"
      verification.consistency_description = "No checksum available"
    else
      verification.consistency_status = "unknown"
      verification.consistency_description = "Cannot verify — link is unavailable"
    end

    verification.last_checked_at = Time.current
    verification.save!

    render json: {
      success: true,
      verification: {
        availability_status: verification.availability_status,
        consistency_status: verification.consistency_status,
        last_checked_at: verification.last_checked_at,
        availability_description: verification.availability_description,
        consistency_description: verification.consistency_description,
        link_type: verification.link_type,
      },
      last_access_date: review.reload.last_access_date,
    }
  rescue StandardError => e
    render json: { error: "Verification failed: #{e.message}" }
  end

  def report_outdated
    review = ApkReview.find_by(topic_id: params[:topic_id])
    return render json: { error: I18n.t("sideloaded_apps.errors.not_found") }, status: 404 unless review
    return render json: { error: I18n.t("sideloaded_apps.errors.not_in_category") }, status: 422 unless review.topic&.category&.slug == SiteSetting.sideloaded_apps_category_slug
    return render json: { error: I18n.t("sideloaded_apps.report_outdated.cannot_report_own") }, status: 422 if review.user_id == current_user.id

    user_note = params[:message].to_s.strip
    if user_note.length < 20
      return render json: { error: I18n.t("sideloaded_apps.report_outdated.min_length", count: 20) }, status: 422
    end

    topic = review.topic
    author = topic.user
    topic_url = "#{Discourse.base_url}#{topic.relative_url}"
    reporter = current_user.username
    app_name = review.app_name
    version = review.apk_version

    raw = I18n.t(
      "sideloaded_apps.report_outdated.pm_body",
      reporter: reporter,
      app_name: app_name,
      version: version,
      topic_url: topic_url,
    )
    raw += "\n\n> #{user_note}" if user_note.present?

    usernames = [author.username]
    usernames += Group[:moderators].human_users.pluck(:username) if Group[:moderators]
    usernames = usernames.uniq - [current_user.username]

    return render json: { error: I18n.t("sideloaded_apps.report_outdated.no_recipients") }, status: 422 if usernames.empty?

    PostCreator.create!(
      current_user,
      title: I18n.t("sideloaded_apps.report_outdated.pm_title", app_name: app_name),
      raw: raw,
      archetype: Archetype.private_message,
      target_usernames: usernames.join(","),
      skip_validations: true,
    )

    render json: { success: true }
  end

  private

  def compute_checksum_for(url, original_checksum)
    uri = URI.parse(url)
    sha256 = Digest::SHA256.new
    max_size = SiteSetting.sideloaded_apps_max_apk_file_size_mb.megabytes

    FinalDestination::HTTP.start(
      uri.host, uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 10,
      read_timeout: 60,
    ) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = LINK_CHECK_UA
      request["Accept"] = "*/*"
      total_bytes = 0

      http.request(request) do |response|
        unless response.code.to_i.between?(200, 299)
          return { status: "inconsistent", description: "Could not download file (HTTP #{response.code})", checksum: nil }
        end

        response.read_body do |chunk|
          total_bytes += chunk.bytesize
          return { status: "inconsistent", description: "File exceeds maximum size limit", checksum: nil } if total_bytes > max_size
          sha256.update(chunk)
        end
      end
    end

    computed = sha256.hexdigest
    if computed == original_checksum
      { status: "consistent", description: "Checksum matches (SHA-256: #{computed[0..11]}...)", checksum: computed }
    else
      { status: "inconsistent", description: "Checksum mismatch — file may have been modified", checksum: computed }
    end
  rescue => e
    { status: "inconsistent", description: "Verification error: #{e.message}", checksum: nil }
  end

  def probe_url(uri, open_timeout: 10, read_timeout: 10)
    FinalDestination::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: open_timeout,
      read_timeout: read_timeout,
    ) do |http|
      head = Net::HTTP::Head.new(uri.request_uri)
      head["User-Agent"] = LINK_CHECK_UA
      head["Accept"] = "*/*"
      response = http.request(head)

      if response.code.to_i.in?([403, 405, 501])
        get = Net::HTTP::Get.new(uri.request_uri)
        get["User-Agent"] = LINK_CHECK_UA
        get["Accept"] = "*/*"
        get["Range"] = "bytes=0-0"
        response = http.request(get)
      end

      response
    end
  end

  def refresh_verification_after_edit(review)
    uri = URI.parse(review.apk_link)
    response = probe_url(uri, open_timeout: 5, read_timeout: 5)
    code = response.code.to_i

    content_type = response["content-type"].to_s.downcase
    is_html = content_type.include?("text/html")
    is_download = response["content-disposition"].to_s.downcase.include?("attachment") ||
      content_type.include?("application/") ||
      content_type.include?("binary") ||
      review.apk_link.match?(/\.apk\z/i)

    verification = ApkVerification.find_or_initialize_by(topic_id: review.topic_id)
    verification.link_type = (is_html && !is_download) ? "webpage" : "file"

    if code.between?(200, 399)
      verification.availability_status = "available"
      verification.availability_description = "Link is accessible (HTTP #{code})"
      review.update_column(:last_access_date, Time.current)
    else
      verification.availability_status = "unavailable"
      verification.availability_description = "Link returned HTTP #{code}"
    end
    verification.last_http_status = code

    if verification.availability_status == "available" && review.apk_checksum.present?
      checksum_result = compute_checksum_for(review.apk_link, review.apk_checksum)
      verification.consistency_status = checksum_result[:status]
      verification.consistency_description = checksum_result[:description]
      verification.last_computed_checksum = checksum_result[:checksum]
    elsif review.apk_checksum.blank?
      verification.consistency_status = "unknown"
      verification.consistency_description = "No checksum available"
    else
      verification.consistency_status = "unknown"
      verification.consistency_description = "Cannot verify — link is unavailable"
    end

    verification.last_checked_at = Time.current
    verification.save!

    {
      availability_status: verification.availability_status,
      consistency_status: verification.consistency_status,
      last_checked_at: verification.last_checked_at,
      availability_description: verification.availability_description,
      consistency_description: verification.consistency_description,
      link_type: verification.link_type,
    }
  rescue => e
    Rails.logger.warn("[Sideloaded Apps] Verification after edit failed for topic #{review.topic_id}: #{e.message}")
    nil
  end

  FIELD_LABELS = {
    "apk_version" => "Version",
    "apk_link" => "APK Link",
    "app_description" => "Description",
    "known_issues" => "Known Issues",
    "author_rating" => "Author Rating",
    "apk_checksum" => "Checksum",
  }.freeze

  def create_edit_audit_post(review, old_attrs)
    changes = []
    FIELD_LABELS.each do |field, label|
      old_val = old_attrs[field].to_s
      new_val = review.send(field).to_s
      next if old_val == new_val

      if field == "app_description" || field == "known_issues"
        changes << "- **#{label}** updated"
      else
        changes << "- **#{label}**: `#{old_val}` → `#{new_val}`"
      end
    end

    return if changes.empty?

    raw = "> **Review updated by @#{current_user.username}**\n>\n"
    raw += changes.map { |c| "> #{c}" }.join("\n")
    raw += "\n>\n> [View current review](#post_1)"

    PostCreator.create!(
      current_user,
      topic_id: review.topic_id,
      raw: raw,
      skip_validations: true,
    )
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to create audit post for topic #{review.topic_id}: #{e.message}")
  end

  def review_params
    params.require(:review).permit(
      :app_name,
      :app_category,
      :apk_link,
      :apk_version,
      :author_rating,
      :app_description,
      :known_issues,
      :apk_checksum,
      screenshot_urls: [],
    )
  end
end
