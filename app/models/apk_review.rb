# frozen_string_literal: true

class ::ApkReview < ActiveRecord::Base
  self.table_name = "apk_reviews"

  belongs_to :topic, class_name: "::Topic"
  belongs_to :user, class_name: "::User"
  has_one :verification, class_name: "::ApkVerification", foreign_key: :topic_id, primary_key: :topic_id

  validates :topic_id, presence: true, uniqueness: true
  validates :user_id, presence: true
  validates :app_name, presence: true, length: { maximum: 255 }
  validates :app_category, presence: true, length: { maximum: 100 }
  validates :apk_link, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }
  validates :apk_version, presence: true, length: { maximum: 50 }
  validates :author_rating, presence: true, inclusion: { in: 1..5 }
  validates :app_description, presence: true

  APP_CATEGORIES = %w[
    communication
    social
    productivity
    utilities
    health
    finance
    entertainment
    music
    navigation
    weather
    news
    education
    other
  ].freeze

  def self.app_categories
    APP_CATEGORIES
  end

  # Community average: one rating per user (PluginStore is source of truth,
  # PostCustomField is fallback for users who rated before PluginStore migration)
  def self.community_rating_for(topic_id)
    ratings_by_user = {}

    # 1. Collect reply ratings keyed by user_id
    PostCustomField
      .joins(:post)
      .where(name: "apk_rating")
      .where(posts: { topic_id: topic_id, deleted_at: nil })
      .where.not(posts: { post_number: 1 })
      .pluck(Arel.sql("posts.user_id"), :value)
      .each { |uid, val| ratings_by_user[uid] = val.to_i }

    # 2. PluginStore ratings override (source of truth)
    PluginStoreRow
      .where(plugin_name: "sideloaded_ratings")
      .where("key LIKE ?", "t#{topic_id}_u%")
      .pluck(:key, :value)
      .each do |key, val|
        uid = key.match(/\At\d+_u(\d+)\z/)&.captures&.first&.to_i
        next unless uid
        ratings_by_user[uid] = val.to_i
      end

    all_ratings = ratings_by_user.values.select { |r| r.between?(1, 5) }
    if all_ratings.any?
      { average: (all_ratings.sum.to_f / all_ratings.size).round(1), count: all_ratings.size }
    else
      { average: 0.0, count: 0 }
    end
  end

  def self.user_rating_for(topic_id, user_id)
    return nil unless user_id

    standalone = PluginStore.get("sideloaded_ratings", "t#{topic_id}_u#{user_id}")
    return standalone.to_i if standalone.present?

    PostCustomField
      .joins(:post)
      .where(name: "apk_rating")
      .where(posts: { topic_id: topic_id, user_id: user_id, deleted_at: nil })
      .where.not(posts: { post_number: 1 })
      .pick(:value)
      &.to_i
  end

  def self.standalone_ratings_for(topic_id)
    PluginStoreRow
      .where(plugin_name: "sideloaded_ratings")
      .where("key LIKE ?", "t#{topic_id}_u%")
      .pluck(:key, :value)
      .each_with_object({}) { |(key, val), h| h[key] = val.to_i }
      .select { |_, v| v.between?(1, 5) }
  end
end
