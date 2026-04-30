# frozen_string_literal: true

# name: discourse-apk-ranking
# about: Sideloaded Apps Ranking - community-driven app rating system for Mudita Kompakt
# version: 0.3.0
# authors: Mudita
# url: https://github.com/mudita/discourse-apk-ranking
# required_version: 2.7.0

enabled_site_setting :sideloaded_apps_ranking_enabled

register_asset "stylesheets/sideloaded-apps.scss"

module ::DiscourseApkRanking
  # HTML-comment markers used to fence auto-generated content in post raw.
  # Anything between the markers is treated as plugin-owned and gets
  # restored on every edit (see plugin.rb `on(:post_edited)` handler).
  PREFIX_START = "<!-- apk-prefix-start -->"
  PREFIX_END = "<!-- apk-prefix-end -->"
  AUDIT_START = "<!-- apk-audit-start -->"
  AUDIT_END = "<!-- apk-audit-end -->"

  # Strip every plugin-owned block (both reply-prefix and audit) from a
  # raw string. Used when surfacing raw to the composer so the user
  # never sees the markers — server-side hooks always re-apply the
  # canonical block on save, so the round-trip stays consistent.
  def self.strip_plugin_markers(raw)
    return raw if raw.blank?
    raw
      .gsub(/#{Regexp.escape(PREFIX_START)}.*?#{Regexp.escape(PREFIX_END)}\s*/m, "")
      .gsub(/#{Regexp.escape(AUDIT_START)}.*?#{Regexp.escape(AUDIT_END)}\s*/m, "")
      .sub(/\A\s+/, "")
  end

  def self.contains_markers?(raw)
    s = raw.to_s
    s.include?(PREFIX_START) || s.include?(AUDIT_START)
  end
end

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
  require_relative "lib/link_probe"
  require_relative "app/models/apk_review"
  require_relative "app/models/apk_verification"
  require_relative "app/controllers/apk_reviews_controller"
  require_relative "app/serializers/apk_review_serializer"
  require_relative "app/jobs/scheduled/verify_apk_links"

  register_post_custom_field_type("apk_rating", :integer)
  register_post_custom_field_type("apk_audit_raw", :string)

  # Hide plugin-owned marker blocks from the composer when a post is
  # loaded for editing. Server-side `on(:post_edited)` always re-applies
  # the canonical block on save, so stripping here does not affect
  # persistence — it only prevents the user from seeing or deleting the
  # HTML-comment markers in the editor.
  reloadable_patch do
    PostSerializer.prepend(
      Module.new do
        def raw
          original = super
          return original unless ::DiscourseApkRanking.contains_markers?(original)
          ::DiscourseApkRanking.strip_plugin_markers(original)
        end
      end,
    )
  end

  # ── Helper: protect screenshot uploads from cleanup ──
  # Discourse deletes uploads without UploadReference records.
  # Screenshots stored only in ApkReview.screenshot_urls would be
  # considered orphaned, so we create UploadReference entries linking
  # each upload to the topic's first post.
  def self.ensure_screenshot_upload_references(topic_id, screenshot_urls)
    return if screenshot_urls.blank?

    post = Post.find_by(topic_id: topic_id, post_number: 1)
    return unless post

    upload_ids = screenshot_urls.filter_map do |url|
      sha1 = Upload.sha1_from_short_url(url) || Upload.sha1_from_long_url(url)
      upload = sha1 && Upload.find_by(sha1: sha1)
      upload ||= Upload.find_by("url LIKE ?", "%#{url.split("/").last(3).join("/")}")
      upload&.id
    end

    return if upload_ids.empty?

    existing_ids = UploadReference.where(target: post).pluck(:upload_id)
    new_ids = upload_ids - existing_ids

    new_ids.each do |uid|
      UploadReference.create!(upload_id: uid, target: post)
    rescue ActiveRecord::RecordNotUnique
      # already exists — safe to ignore
    end
  rescue => e
    Rails.logger.warn("[Sideloaded Apps] Failed to create upload references for topic #{topic_id}: #{e.message}")
  end

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

  # ── Topic list ordering ─────────────────────────────
  register_modifier(:topic_query_apply_ordering_result) do |result, sort_column, sort_dir, options, topic_query|
    category_id = topic_query.options[:category_id]
    category_slug = category_id ? Category.where(id: category_id).pick(:slug) : nil

    next result unless category_slug == SiteSetting.sideloaded_apps_category_slug

    direction = sort_dir == "ASC" ? "ASC" : "DESC"
    pinned_first = "CASE WHEN topics.pinned_at IS NOT NULL THEN 0 ELSE 1 END ASC"

    if sort_column == "default"
      # Clicking the "Topic" column header → sort alphabetically by title
      result.order(Arel.sql("#{pinned_first}, LOWER(topics.title) #{direction}"))
    elsif sort_column == "community_rating"
      # Explicit click on the Community Rating column
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
            "#{pinned_first}, COALESCE(community_ratings.community_avg, 0) #{direction}",
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

    ensure_screenshot_upload_references(topic.id, screenshot_urls)

    tag_name = "app-#{app_category}"
    DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), [tag_name], append: true)

    if apk_link.present?
      probe = ::DiscourseApkRanking::LinkProbe.probe(apk_link, open_timeout: 5, read_timeout: 5)
      link_available = probe.error.nil? && probe.code&.between?(200, 299)

      ApkVerification.create!(
        topic_id: topic.id,
        availability_status: link_available ? "available" : "unavailable",
        availability_description: link_available ? "Link verified at submission" : "Link was not accessible at submission",
        consistency_status: apk_checksum.present? ? "consistent" : "unknown",
        consistency_description:
          apk_checksum.present? ? "Checksum computed at submission" : "No checksum available",
        last_computed_checksum: apk_checksum,
        link_type: probe.link_type,
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

    ensure_screenshot_upload_references(topic.id, screenshot_urls)

    tag_name = "app-#{app_category}"
    DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), [tag_name], append: true)

    if apk_link.present?
      probe = ::DiscourseApkRanking::LinkProbe.probe(apk_link, open_timeout: 5, read_timeout: 5)
      link_available = probe.error.nil? && probe.code&.between?(200, 299)

      ApkVerification.create!(
        topic_id: topic.id,
        availability_status: link_available ? "available" : "unavailable",
        availability_description: link_available ? "Link verified at submission" : "Link was not accessible at submission",
        consistency_status: apk_checksum.present? ? "consistent" : "unknown",
        consistency_description:
          apk_checksum.present? ? "Checksum computed at submission" : "No checksum available",
        last_computed_checksum: apk_checksum,
        link_type: probe.link_type,
        last_checked_at: Time.current,
      )
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to process approved review for post #{post&.id}: #{e.message}")
  end

  # ── Helpers for reply auto-prefix (version + rating) ──
  def self.apk_reply_prefix_for(post, user, override_rating: nil)
    review = ApkReview.find_by(topic_id: post.topic_id)
    return nil unless review

    is_topic_author = post.topic.user_id == user.id
    effective_rating =
      override_rating ||
      (!is_topic_author ? ApkReview.user_rating_for(post.topic_id, user.id) : nil)

    lines = ["> #{I18n.t("js.sideloaded_apps.reply_version_prefix")} #{review.apk_version}"]
    if is_topic_author
      author_stars = "\u2605" * review.author_rating + "\u2606" * (5 - review.author_rating)
      lines << "> #{I18n.t("js.sideloaded_apps.reply_author_rating_prefix")} #{author_stars} · #{I18n.t("js.sideloaded_apps.reply_author_badge")}"
    elsif effective_rating&.between?(1, 5)
      stars = "\u2605" * effective_rating + "\u2606" * (5 - effective_rating)
      lines << "> #{I18n.t("js.sideloaded_apps.reply_user_rating_prefix")} #{stars}"
    end

    "#{::DiscourseApkRanking::PREFIX_START}\n#{lines.join("\n")}\n#{::DiscourseApkRanking::PREFIX_END}\n\n"
  end

  # Normalize typographic quotes (Discourse's typographer rewrites
  # straight ASCII apostrophes to curly ones in stored raw, so a naive
  # string compare against the I18n key would miss them).
  def self.apk_normalize_quotes(str)
    str.to_s.tr("\u2018\u2019\u201B\u2032", "'").tr("\u201C\u201D\u2033", '"')
  end

  # Strip the auto-prefix block from `raw`. Primary strategy: cut
  # everything between the HTML-comment markers, regardless of the
  # content inside (so user edits within the block disappear on save).
  # Fallback: for posts created before the marker was introduced (or if
  # a user deleted the markers), drop any line containing one of the
  # prefix labels.
  def self.apk_strip_reply_prefix(raw)
    return raw if raw.blank?

    cleaned =
      raw.gsub(
        /#{Regexp.escape(::DiscourseApkRanking::PREFIX_START)}.*?#{Regexp.escape(::DiscourseApkRanking::PREFIX_END)}\s*/m,
        "",
      )

    version_key = apk_normalize_quotes(I18n.t("js.sideloaded_apps.reply_version_prefix"))
    user_key = apk_normalize_quotes(I18n.t("js.sideloaded_apps.reply_user_rating_prefix"))
    author_key = apk_normalize_quotes(I18n.t("js.sideloaded_apps.reply_author_rating_prefix"))
    prefix_keys = [version_key, user_key, author_key, "Review for version"].uniq

    kept = cleaned.lines.reject do |line|
      stripped = apk_normalize_quotes(line.strip.sub(/\A>+\s*/, ""))
      next false if stripped.empty?
      prefix_keys.any? { |k| stripped.include?(k) }
    end

    # Drop leading blank lines and collapse any run of 3+ consecutive
    # newlines (left where a prefix block was removed) into 2.
    kept.join.sub(/\A\s+/, "").gsub(/\n{3,}/, "\n\n")
  end

  # Remove the audit block (wrapped by AUDIT markers) from `raw`. Any
  # user-added content outside the markers survives and is returned.
  def self.apk_strip_audit_block(raw)
    return raw if raw.blank?
    raw
      .gsub(
        /#{Regexp.escape(::DiscourseApkRanking::AUDIT_START)}.*?#{Regexp.escape(::DiscourseApkRanking::AUDIT_END)}\s*/m,
        "",
      )
      .sub(/\A\s+/, "")
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
    next if post.raw.include?(::DiscourseApkRanking::AUDIT_START) || post.raw.include?("Review updated by")

    prefix = apk_reply_prefix_for(post, user, override_rating: rating)
    next unless prefix

    body = apk_strip_reply_prefix(post.raw)
    new_raw = "#{prefix}#{body}"
    if new_raw != post.raw
      post.update_column(:raw, new_raw)
      post.rebake!
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to process reply post #{post.id}: #{e.message}")
  end

  # ── Re-apply auto-prefix on every edit ───────────────
  # Users must not be able to alter version/rating text or tamper with
  # the audit block by editing the post.
  on(:post_edited) do |post, _topic_changed, _revisor|
    next unless SiteSetting.sideloaded_apps_ranking_enabled
    next if post.post_number == 1
    next unless post.topic&.category&.slug == SiteSetting.sideloaded_apps_category_slug

    # Audit post (review edit history): restore canonical audit block
    # from the custom field, keep any user-added body below.
    audit_canonical = post.custom_fields["apk_audit_raw"]
    if audit_canonical.present?
      body = apk_strip_audit_block(post.raw)
      canonical = audit_canonical.sub(/\s*\z/, "")
      new_raw = body.blank? ? "#{canonical}\n" : "#{canonical}\n\n#{body}"

      if new_raw != post.raw
        post.update_column(:raw, new_raw)
        post.rebake!
      end
      next
    end

    prefix = apk_reply_prefix_for(post, post.user)
    next unless prefix

    body = apk_strip_reply_prefix(post.raw)
    new_raw = "#{prefix}#{body}"

    if new_raw != post.raw
      post.update_column(:raw, new_raw)
      post.rebake!
    end
  rescue => e
    Rails.logger.error("[Sideloaded Apps] Failed to re-apply prefix on edited post #{post&.id}: #{e.message}")
  end
end
