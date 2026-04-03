# frozen_string_literal: true

# name: discourse-apk-ranking
# about: Sideloaded Apps Ranking - community-driven app rating system for Mudita Kompakt
# version: 0.3.0
# authors: Mudita
# url: https://github.com/mudita/discourse-apk-ranking
# required_version: 2.7.0

enabled_site_setting :sideloaded_apps_ranking_enabled

register_asset "stylesheets/sideloaded-apps.scss"

register_editable_topic_custom_field(:apk_app_name)
register_editable_topic_custom_field(:apk_app_category)
register_editable_topic_custom_field(:apk_link)
register_editable_topic_custom_field(:apk_version)
register_editable_topic_custom_field(:apk_author_rating)
register_editable_topic_custom_field(:apk_description)
register_editable_topic_custom_field(:apk_known_issues)
register_editable_topic_custom_field(:apk_checksum)
register_editable_topic_custom_field(:apk_rating)
register_editable_topic_custom_field(:apk_screenshot_urls)
register_editable_topic_custom_field(:apk_author_is_developer)
register_editable_topic_custom_field(:apk_icon_url)

after_initialize do
  require Rails.root.join("app/models/topic_list.rb").to_s
  TopicList.preloaded_custom_fields << "apk_author_is_developer"
  TopicList.preloaded_custom_fields << "apk_icon_url"

  # Ensure topic_opts (containing custom_fields) survives the approval queue
  NewPostManager.add_plugin_payload_attribute(:topic_opts)
  require_relative "app/models/apk_review"
  require_relative "app/models/apk_verification"
  require_relative "app/controllers/apk_reviews_controller"
  require_relative "app/serializers/apk_review_serializer"
  require_relative "app/jobs/scheduled/verify_apk_links"

  register_post_custom_field_type("apk_rating", :integer)

  add_to_serializer(:reviewable_queued_post, :apk_review_data) do
    topic_opts = object.payload&.dig("topic_opts") || {}
    cf = topic_opts["custom_fields"] || {}
    return nil if cf["apk_app_name"].blank?

    {
      app_name: cf["apk_app_name"],
      app_category: cf["apk_app_category"] || "other",
      apk_link: cf["apk_link"] || "",
      apk_version: cf["apk_version"] || "",
      author_rating: (cf["apk_author_rating"] || 0).to_i,
      app_description: cf["apk_description"] || "",
      known_issues: cf["apk_known_issues"] || "",
      apk_checksum: cf["apk_checksum"] || "",
      author_is_developer: cf["apk_author_is_developer"] == "true",
      icon_url: cf["apk_icon_url"] || "",
      screenshot_urls: begin
        JSON.parse(cf["apk_screenshot_urls"] || "[]")
      rescue JSON::ParserError
        []
      end,
    }
  end

  # ── Ensure app-category tags + tag group exist ────
  TAG_GROUP_NAME = "Sideloaded App Category"

  ensure_app_category_tags = lambda do
    return unless SiteSetting.sideloaded_apps_ranking_enabled

    tag_group = TagGroup.find_by("LOWER(name) = ?", TAG_GROUP_NAME.downcase) ||
                TagGroup.create!(name: TAG_GROUP_NAME)

    ApkReview::APP_CATEGORIES.each do |cat_name|
      tag_name = "app-#{cat_name}"
      tag = Tag.find_by_name(tag_name) || Tag.create!(name: tag_name)
      TagGroupMembership.find_or_create_by!(tag: tag, tag_group: tag_group)
    end

    slug = SiteSetting.sideloaded_apps_category_slug
    category = Category.find_by(slug: slug)
    if category && !CategoryTagGroup.exists?(category: category, tag_group: tag_group)
      CategoryTagGroup.create!(category: category, tag_group: tag_group)
    end

    # Backfill tags on existing untagged review topics
    if category
      guardian = Guardian.new(Discourse.system_user)
      ApkReview.where(topic_id: Topic.where(category_id: category.id).select(:id)).find_each do |review|
        topic = review.topic
        next unless topic
        tag_name = "app-#{review.app_category}"
        next if topic.tags.exists?(name: tag_name)
        DiscourseTagging.tag_topic_by_names(topic, guardian, [tag_name], append: true)
      end
    end
  rescue => e
    Rails.logger.warn("[Sideloaded Apps] Failed to ensure tags: #{e.message}")
  end

  ensure_app_category_tags.call

  # ── Routes ──────────────────────────────────────────
  Discourse::Application.routes.append do
    get "/sideloaded-apps/reviews" => "apk_reviews#index"
    get "/sideloaded-apps/reviews/:id" => "apk_reviews#show"
    post "/sideloaded-apps/reviews" => "apk_reviews#create"
    put "/sideloaded-apps/reviews/:id" => "apk_reviews#update"
    post "/sideloaded-apps/rate" => "apk_reviews#rate"
    post "/sideloaded-apps/track-download" => "apk_reviews#track_download"
    post "/sideloaded-apps/validate-link" => "apk_reviews#validate_link"
    post "/sideloaded-apps/compute-checksum" => "apk_reviews#compute_checksum"
    post "/sideloaded-apps/verify-now" => "apk_reviews#verify_now"
    post "/sideloaded-apps/report-outdated" => "apk_reviews#report_outdated"
    get "/sideloaded-apps/top" => "apk_reviews#top"
  end

  # ── Topic preload helpers ───────────────────────────
  add_to_class(:topic, :preload_apk_review_data) { |data| @apk_review_data = data }
  add_to_class(:topic, :preload_apk_community_rating) { |data| @apk_community_rating = data }

  add_to_class(:topic, :apk_review_data) do
    return @apk_review_data if defined?(@apk_review_data)
    review = ApkReview.find_by(topic_id: id)
    @apk_review_data =
      if review
        {
          app_name: review.app_name,
          app_category: review.app_category,
          author_rating: review.author_rating,
          last_access_date: review.last_access_date,
        }
      end
  end

  add_to_class(:topic, :apk_community_rating) do
    return @apk_community_rating if defined?(@apk_community_rating)
    @apk_community_rating = ApkReview.community_rating_for(id)
  end

  # ── Bulk preload for topic lists ────────────────────
  TopicList.on_preload do |topics, topic_list|
    next unless SiteSetting.sideloaded_apps_ranking_enabled

    slug = SiteSetting.sideloaded_apps_category_slug
    apk_topics = topics.select { |t| t.category&.slug == slug }
    next if apk_topics.empty?

    topic_ids = apk_topics.map(&:id)
    reviews = ApkReview.where(topic_id: topic_ids).index_by(&:topic_id)

    # Community ratings: one per user (PluginStore overrides PostCustomField)
    # 1. Reply ratings keyed by (topic_id, user_id)
    reply_ratings_by_topic_user = {}
    PostCustomField
      .joins(:post)
      .where(name: "apk_rating")
      .where(posts: { topic_id: topic_ids, deleted_at: nil })
      .where.not(posts: { post_number: 1 })
      .pluck(Arel.sql("posts.topic_id, posts.user_id, post_custom_fields.value"))
      .each do |tid, uid, val|
        reply_ratings_by_topic_user[[tid, uid]] = val.to_i
      end

    # 2. PluginStore ratings override per user
    key_patterns = topic_ids.map { |tid| "t#{tid}_u%" }
    if key_patterns.any?
      PluginStoreRow.where(plugin_name: "sideloaded_ratings").where(
        key_patterns.map { "key LIKE ?" }.join(" OR "),
        *key_patterns,
      ).pluck(:key, :value).each do |key, val|
        match = key.match(/\At(\d+)_u(\d+)\z/)
        next unless match
        tid = match[1].to_i
        uid = match[2].to_i
        reply_ratings_by_topic_user[[tid, uid]] = val.to_i
      end
    end

    # Group by topic
    ratings_by_topic = {}
    reply_ratings_by_topic_user.each do |(tid, _uid), rating|
      (ratings_by_topic[tid] ||= []) << rating
    end

    apk_topics.each do |topic|
      review = reviews[topic.id]
      topic.preload_apk_review_data(
        if review
          {
            app_name: review.app_name,
            app_category: review.app_category,
            author_rating: review.author_rating,
            last_access_date: review.last_access_date,
          }
        end,
      )

      all_ratings = (ratings_by_topic[topic.id] || []).select { |r| r.between?(1, 5) }

      if all_ratings.any?
        avg = (all_ratings.sum.to_f / all_ratings.size).round(1)
        topic.preload_apk_community_rating({ average: avg, count: all_ratings.size })
      else
        topic.preload_apk_community_rating({ average: 0.0, count: 0 })
      end
    end

    (topics - apk_topics).each do |topic|
      topic.preload_apk_review_data(nil)
      topic.preload_apk_community_rating(nil)
    end
  end

  # ── Topic View serializers ─────────────────────────
  add_to_serializer(:topic_view, :apk_review) do
    return nil unless object.topic.category&.slug == SiteSetting.sideloaded_apps_category_slug

    review = ApkReview.find_by(topic_id: object.topic.id)
    return nil unless review

    ApkReviewSerializer.new(review, root: false).as_json
  end

  add_to_serializer(:topic_view, :apk_user_rating) do
    return nil unless object.topic.category&.slug == SiteSetting.sideloaded_apps_category_slug
    return nil unless scope.user

    ApkReview.user_rating_for(object.topic.id, scope.user.id)
  end

  add_to_serializer(:topic_view, :apk_verification) do
    return nil unless object.topic.category&.slug == SiteSetting.sideloaded_apps_category_slug

    verification = ApkVerification.find_by(topic_id: object.topic.id)
    return nil unless verification

    {
      availability_status: verification.availability_status,
      consistency_status: verification.consistency_status,
      last_checked_at: verification.last_checked_at,
      availability_description: verification.availability_description,
      consistency_description: verification.consistency_description,
      link_type: verification.link_type,
    }
  end

  # ── Topic List Item serializers ─────────────────────
  add_to_serializer(:topic_list_item, :apk_app_name) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.apk_review_data&.dig(:app_name)
  end

  add_to_serializer(:topic_list_item, :apk_app_category) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.apk_review_data&.dig(:app_category)
  end

  add_to_serializer(:topic_list_item, :apk_community_average) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.apk_community_rating&.dig(:average)
  end

  add_to_serializer(:topic_list_item, :apk_community_count) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.apk_community_rating&.dig(:count)
  end

  add_to_serializer(:topic_list_item, :apk_last_access_date) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.apk_review_data&.dig(:last_access_date)
  end

  add_to_serializer(:topic_list_item, :apk_author_is_developer) do
    return false unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.custom_fields["apk_author_is_developer"] == "true"
  end

  add_to_serializer(:topic_list_item, :apk_icon_url) do
    return nil unless object.category&.slug == SiteSetting.sideloaded_apps_category_slug
    url = object.custom_fields["apk_icon_url"].to_s.strip
    url.present? ? url : nil
  end

  add_to_serializer(:topic_view, :apk_author_is_developer) do
    return false unless object.topic.category&.slug == SiteSetting.sideloaded_apps_category_slug
    object.topic.custom_fields["apk_author_is_developer"] == "true"
  end

  add_to_serializer(:topic_view, :apk_icon_url) do
    return nil unless object.topic.category&.slug == SiteSetting.sideloaded_apps_category_slug
    url = object.topic.custom_fields["apk_icon_url"].to_s.strip
    url.present? ? url : nil
  end

  # ── Exclude sideloaded apps from homepage topic list ─
  TopicQuery.add_custom_filter(:exclude_sideloaded_from_homepage) do |results, topic_query|
    if topic_query.options[:category_id].blank? && topic_query.options[:no_subcategories].nil?
      slug = SiteSetting.sideloaded_apps_category_slug
      apk_category = Category.find_by(slug: slug)
      results = results.where.not(category_id: apk_category.id) if apk_category
    end
    results
  end

  # ── Topic list ordering by community rating ─────────
  register_modifier(:topic_query_apply_ordering_result) do |result, sort_column, sort_dir, options, topic_query|
    category_id = topic_query.options[:category_id]
    category_slug = category_id ? Category.where(id: category_id).pick(:slug) : nil

    if category_slug == SiteSetting.sideloaded_apps_category_slug &&
         (sort_column.blank? || sort_column == "default" || sort_column == "community_rating")
      direction = sort_dir == "ASC" ? "ASC" : "DESC"
      result
        .joins(
          "LEFT JOIN (
             SELECT combined.topic_id,
                    AVG(combined.rating) AS community_avg,
                    COUNT(*) AS community_count
             FROM (
               SELECT posts.topic_id, post_custom_fields.value::integer AS rating
               FROM post_custom_fields
               INNER JOIN posts ON posts.id = post_custom_fields.post_id
               WHERE post_custom_fields.name = 'apk_rating'
                 AND posts.deleted_at IS NULL
                 AND posts.post_number > 1
               UNION ALL
               SELECT SUBSTRING(key FROM 't(\\d+)_u')::integer AS topic_id,
                      value::integer AS rating
               FROM plugin_store_rows
               WHERE plugin_name = 'sideloaded_ratings'
             ) combined
             GROUP BY combined.topic_id
           ) community_ratings ON community_ratings.topic_id = topics.id",
        )
        .order(
          Arel.sql(
            "CASE WHEN topics.pinned_at IS NOT NULL THEN 0 ELSE 1 END ASC, " \
            "COALESCE(community_ratings.community_avg, 0) #{direction}",
          ),
        )
    else
      result
    end
  end

  # ── Auto-create ApkReview on topic creation ─────────
  on(:topic_created) do |topic, opts, user|
    next unless SiteSetting.sideloaded_apps_ranking_enabled
    next unless topic.category&.slug == SiteSetting.sideloaded_apps_category_slug

    cf = topic.custom_fields
    app_name = cf["apk_app_name"]
    next if app_name.blank?

    rating = (cf["apk_author_rating"] || 3).to_i.clamp(1, 5)

    app_category = cf["apk_app_category"] || "other"

    apk_link = cf["apk_link"] || ""
    apk_checksum = cf["apk_checksum"]

    screenshot_urls_raw = cf["apk_screenshot_urls"]
    screenshot_urls =
      if screenshot_urls_raw.present?
        begin
          JSON.parse(screenshot_urls_raw)
        rescue JSON::ParserError
          []
        end
      else
        []
      end

    ApkReview.create!(
      topic_id: topic.id,
      user_id: user.id,
      app_name: app_name,
      app_category: app_category,
      apk_link: apk_link,
      apk_version: cf["apk_version"] || "",
      author_rating: rating,
      app_description: cf["apk_description"] || "",
      known_issues: cf["apk_known_issues"],
      apk_checksum: apk_checksum,
      screenshot_urls: screenshot_urls,
      last_access_date: Time.current,
    )

    tag_name = "app-#{app_category}"
    DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), [tag_name], append: true)

    if apk_link.present?
      probe_result = begin
        uri = URI.parse(apk_link)
        FinalDestination::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 5, read_timeout: 5,
        ) do |http|
          head = Net::HTTP::Head.new(uri.request_uri)
          head["User-Agent"] = "Mozilla/5.0 (compatible; DiscourseBot/1.0)"
          head["Accept"] = "*/*"
          resp = http.request(head)

          if resp.code.to_i.in?([403, 405, 501])
            get = Net::HTTP::Get.new(uri.request_uri)
            get["User-Agent"] = "Mozilla/5.0 (compatible; DiscourseBot/1.0)"
            get["Accept"] = "*/*"
            get["Range"] = "bytes=0-0"
            resp = http.request(get)
          end

          content_type = resp["content-type"].to_s.downcase
          is_html = content_type.include?("text/html")
          is_download = resp["content-disposition"].to_s.downcase.include?("attachment") ||
            content_type.include?("application/") ||
            content_type.include?("binary") ||
            apk_link.match?(/\.apk\z/i)

          { available: resp.code.to_i.between?(200, 399), link_type: (is_html && !is_download) ? "webpage" : "file" }
        end
      rescue StandardError
        { available: false, link_type: nil }
      end

      link_available = probe_result[:available]

      ApkVerification.create!(
        topic_id: topic.id,
        availability_status: link_available ? "available" : "unavailable",
        availability_description: link_available ? "Link verified at submission" : "Link was not accessible at submission",
        consistency_status: apk_checksum.present? ? "consistent" : "unknown",
        consistency_description:
          apk_checksum.present? ? "Checksum computed at submission" : "No checksum available",
        last_computed_checksum: apk_checksum,
        link_type: probe_result[:link_type],
        last_checked_at: Time.current,
      )
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to create review for topic #{topic.id}: #{e.message}")
  end

  # ── Handle topics approved from the review queue ────
  on(:approved_post) do |reviewable, post|
    next unless SiteSetting.sideloaded_apps_ranking_enabled
    next unless post.post_number == 1

    topic = post.topic
    next unless topic
    next unless topic.category&.slug == SiteSetting.sideloaded_apps_category_slug

    # Already processed by :topic_created hook (admin bypass)
    next if ApkReview.exists?(topic_id: topic.id)

    payload = reviewable.payload || {}
    topic_opts = payload["topic_opts"] || {}
    cf = topic_opts["custom_fields"] || {}

    app_name = cf["apk_app_name"]
    next if app_name.blank?

    topic.custom_fields.merge!(cf)
    topic.save_custom_fields

    user = post.user
    rating = (cf["apk_author_rating"] || 3).to_i.clamp(1, 5)
    app_category = cf["apk_app_category"] || "other"
    apk_link = cf["apk_link"] || ""
    apk_checksum = cf["apk_checksum"]

    screenshot_urls_raw = cf["apk_screenshot_urls"]
    screenshot_urls =
      if screenshot_urls_raw.present?
        begin
          JSON.parse(screenshot_urls_raw)
        rescue JSON::ParserError
          []
        end
      else
        []
      end

    ApkReview.create!(
      topic_id: topic.id,
      user_id: user.id,
      app_name: app_name,
      app_category: app_category,
      apk_link: apk_link,
      apk_version: cf["apk_version"] || "",
      author_rating: rating,
      app_description: cf["apk_description"] || "",
      known_issues: cf["apk_known_issues"],
      apk_checksum: apk_checksum,
      screenshot_urls: screenshot_urls,
      last_access_date: Time.current,
    )

    tag_name = "app-#{app_category}"
    DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), [tag_name], append: true)

    if apk_link.present?
      probe_result = begin
        uri = URI.parse(apk_link)
        FinalDestination::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 5, read_timeout: 5,
        ) do |http|
          head = Net::HTTP::Head.new(uri.request_uri)
          head["User-Agent"] = "Mozilla/5.0 (compatible; DiscourseBot/1.0)"
          head["Accept"] = "*/*"
          resp = http.request(head)

          if resp.code.to_i.in?([403, 405, 501])
            get = Net::HTTP::Get.new(uri.request_uri)
            get["User-Agent"] = "Mozilla/5.0 (compatible; DiscourseBot/1.0)"
            get["Accept"] = "*/*"
            get["Range"] = "bytes=0-0"
            resp = http.request(get)
          end

          content_type = resp["content-type"].to_s.downcase
          is_html = content_type.include?("text/html")
          is_download = resp["content-disposition"].to_s.downcase.include?("attachment") ||
            content_type.include?("application/") ||
            content_type.include?("binary") ||
            apk_link.match?(/\.apk\z/i)

          { available: resp.code.to_i.between?(200, 399), link_type: (is_html && !is_download) ? "webpage" : "file" }
        end
      rescue StandardError
        { available: false, link_type: nil }
      end

      link_available = probe_result[:available]

      ApkVerification.create!(
        topic_id: topic.id,
        availability_status: link_available ? "available" : "unavailable",
        availability_description: link_available ? "Link verified at submission" : "Link was not accessible at submission",
        consistency_status: apk_checksum.present? ? "consistent" : "unknown",
        consistency_description:
          apk_checksum.present? ? "Checksum computed at submission" : "No checksum available",
        last_computed_checksum: apk_checksum,
        link_type: probe_result[:link_type],
        last_checked_at: Time.current,
      )
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to process approved review for post #{post&.id}: #{e.message}")
  end

  # ── Persist reply star rating + auto-prefix ──────────
  on(:post_created) do |post, opts, user|
    next unless SiteSetting.sideloaded_apps_ranking_enabled
    next if post.post_number == 1
    next unless post.topic&.category&.slug == SiteSetting.sideloaded_apps_category_slug

    is_topic_author = post.topic.user_id == user.id

    # Discourse 3.2+ moved meta_data into topic_opts[:custom_fields]
    rating_raw = opts.dig(:topic_opts, :custom_fields, "apk_rating")
    rating = rating_raw.to_i if rating_raw.present?

    if !is_topic_author && rating&.between?(1, 5)
      # Update standalone rating (PluginStore) — always overwrite
      PluginStore.set("sideloaded_ratings", "t#{post.topic_id}_u#{user.id}", rating)
      post.custom_fields["apk_rating"] = rating
      post.save_custom_fields
      Rails.logger.info("[Sideloaded Apps] Saved/updated rating #{rating} for user #{user.id} on post #{post.id} in topic #{post.topic_id}")
    end

    # Auto-prefix with version (skip for audit posts from review edits)
    next if post.raw.include?("Review updated by")

    review = ApkReview.find_by(topic_id: post.topic_id)
    next unless review

    # Use rating from this reply, or fall back to user's existing rating
    effective_rating = rating || (!is_topic_author ? ApkReview.user_rating_for(post.topic_id, user.id) : nil)

    prefix = "> #{I18n.t("js.sideloaded_apps.reply_version_prefix")} #{review.apk_version}"
    if is_topic_author
      author_stars = "\u2605" * review.author_rating + "\u2606" * (5 - review.author_rating)
      prefix += "\n> #{I18n.t("js.sideloaded_apps.reply_author_rating_prefix")} #{author_stars} · #{I18n.t("js.sideloaded_apps.reply_author_badge")}"
    elsif effective_rating&.between?(1, 5)
      stars = "\u2605" * effective_rating + "\u2606" * (5 - effective_rating)
      prefix += "\n> #{I18n.t("js.sideloaded_apps.reply_user_rating_prefix")} #{stars}"
    end
    prefix += "\n\n"
    unless post.raw.include?("Review for version") || post.raw.include?(I18n.t("js.sideloaded_apps.reply_version_prefix"))
      post.update_column(:raw, "#{prefix}#{post.raw}")
      post.rebake!
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to process reply post #{post.id}: #{e.message}")
  end
end
