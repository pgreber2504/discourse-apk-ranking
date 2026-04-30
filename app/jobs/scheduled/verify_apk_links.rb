# frozen_string_literal: true

require "digest"

module ::Jobs
  class VerifyApkLinks < ::Jobs::Scheduled
    every 5.minutes

    def execute(args)
      return unless SiteSetting.sideloaded_apps_ranking_enabled
      return unless SiteSetting.sideloaded_apps_verification_enabled

      interval = SiteSetting.sideloaded_apps_verification_interval_minutes.minutes
      max_size = SiteSetting.sideloaded_apps_max_apk_file_size_mb.megabytes

      ApkReview.where.not(apk_link: [nil, ""]).find_each do |review|
        verification = ApkVerification.find_by(topic_id: review.topic_id)
        next if verification&.last_checked_at && verification.last_checked_at > interval.ago

        verify_single_link(review, max_size)
      rescue => e
        Rails.logger.error("[Sideloaded Apps] Error verifying #{review.apk_link}: #{e.message}")
      end
    end

    private

    def verify_single_link(review, max_size)
      verification = ApkVerification.find_or_initialize_by(topic_id: review.topic_id)

      availability = check_availability(review.apk_link)
      verification.availability_status = availability[:status]
      verification.availability_description = availability[:description]
      verification.last_http_status = availability[:http_status]
      verification.link_type = availability[:link_type] if availability[:link_type].present?

      if availability[:status] == "available"
        review.update_column(:last_access_date, Time.current)
      end

      if verification.link_type == "webpage"
        verification.consistency_status = "unknown"
        verification.consistency_description = "Webpage link — checksum not applicable"
        verification.last_computed_checksum = nil
      elsif availability[:status] == "available" && review.apk_checksum.present?
        consistency = check_consistency(review.apk_link, review.apk_checksum, max_size)
        verification.consistency_status = consistency[:status]
        verification.consistency_description = consistency[:description]
        verification.last_computed_checksum = consistency[:checksum]
      elsif review.apk_checksum.blank?
        verification.consistency_status = "unknown"
        verification.consistency_description = "No checksum available"
      else
        verification.consistency_status = "unknown"
        verification.consistency_description = "Cannot verify — file is unavailable"
      end

      verification.last_checked_at = Time.current
      verification.save!
    end

    def check_availability(url)
      probe = ::DiscourseApkRanking::LinkProbe.probe(url)

      if probe.error
        return { status: "unavailable", description: "Connection error: #{probe.error}", http_status: nil, link_type: nil }
      end

      code = probe.code
      if code.between?(200, 299)
        { status: "available", description: "Link is accessible (HTTP #{code})", http_status: code, link_type: probe.link_type }
      else
        { status: "unavailable", description: "Link returned HTTP #{code}", http_status: code, link_type: probe.link_type }
      end
    end

    def check_consistency(url, original_checksum, max_size)
      sha256 = Digest::SHA256.new
      result =
        ::DiscourseApkRanking::LinkProbe.stream_download(url, max_size: max_size) do |chunk|
          sha256.update(chunk)
        end

      if result.error
        return { status: "inconsistent", description: "Verification error: #{result.error}", checksum: nil }
      end

      unless result.code&.between?(200, 299)
        return { status: "inconsistent", description: "Could not download file (HTTP #{result.code})", checksum: nil }
      end

      if result.truncated
        return { status: "inconsistent", description: "File exceeds maximum size limit", checksum: nil }
      end

      computed = sha256.hexdigest

      if computed == original_checksum
        { status: "consistent", description: "Checksum matches (SHA-256: #{computed[0..11]}...)", checksum: computed }
      else
        { status: "inconsistent", description: "Checksum mismatch — file may have been modified since submission", checksum: computed }
      end
    rescue => e
      { status: "inconsistent", description: "Verification error: #{e.message}", checksum: nil }
    end
  end
end
