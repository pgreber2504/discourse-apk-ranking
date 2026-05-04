import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { cancel, debounce } from "@ember/runloop";
import { service } from "@ember/service";
import PickFilesButton from "discourse/components/pick-files-button";
import { ajax } from "discourse/lib/ajax";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { validateIconUrl } from "../lib/validate-icon-url";
import ApkStarRating from "./apk-star-rating";
import ApkVerificationStatus from "./apk-verification-status";
import ReportOutdatedModal from "./modal/report-outdated";

export default class ApkReviewDisplay extends Component {
  @service modal;
  @service appEvents;
  @service composer;

  editUppyUpload = new UppyUpload(getOwner(this), {
    id: "sideloaded-edit-screenshot-uploader",
    type: "composer",
    validateUploadedFilesOptions: { imagesOnly: true },
    uploadDone: (upload) => {
      this._editScreenshots = [
        ...this._editScreenshots,
        { url: upload.url, original_filename: upload.original_filename },
      ];
    },
  });

  @tracked _communityAvgOverride = null;
  @tracked _communityCountOverride = null;
  @tracked _userRating = null;
  @tracked _ratingSubmitting = false;
  @tracked _lastAccessOverride = null;
  @tracked _downloadChecking = false;

  @tracked _editMode = false;
  @tracked _saving = false;
  @tracked _editVersion = "";
  @tracked _editLink = "";
  @tracked _editDescription = "";
  @tracked _editKnownIssues = "";
  @tracked _editRating = 0;
  @tracked _editChecksum = "";
  @tracked _editScreenshots = [];

  @tracked _editFieldErrors = {};
  @tracked _editLinkValidationStatus = null;
  @tracked _editLinkValidationMessage = "";
  @tracked _editLinkIsDirectDownload = null;
  @tracked _editIconUrl = "";
  @tracked _editIconValidationStatus = null;
  @tracked _editIconValidationMessage = "";
  @tracked _editIconPreviewUrl = null;
  _editIconValidationToken = 0;
  _touchedFields = new Set();
  @tracked _reviewOverride = null;
  @tracked _verificationOverride = null;
  @tracked _reportOutdatedDone = false;

  _editValidateTimer = null;
  _editLinkDebounceTimer = null;
  _editIconDebounceTimer = null;

  constructor() {
    super(...arguments);
    if (!this.args.verification && this.args.review?.topic_id) {
      this._triggerVerification();
    }
    this.appEvents.on("composer:created-post", this, "_onComposerCreatedPost");
  }

  willDestroy() {
    super.willDestroy(...arguments);
    if (this._editValidateTimer) {
      cancel(this._editValidateTimer);
    }
    if (this._editLinkDebounceTimer) {
      cancel(this._editLinkDebounceTimer);
    }
    if (this._editIconDebounceTimer) {
      cancel(this._editIconDebounceTimer);
    }
    this._editIconValidationToken++;
    this.appEvents.off("composer:created-post", this, "_onComposerCreatedPost");
  }

  async _onComposerCreatedPost() {
    const model = this.composer?.model;
    const topicId = model?.topic?.id;
    if (
      !topicId ||
      topicId !== this.review?.topic_id ||
      model?.action !== "reply"
    ) {
      return;
    }

    const md = model.metaData;
    const raw = md?.apk_rating ?? md?.get?.("apk_rating");
    const parsed = raw ? parseInt(raw, 10) : null;
    const newUserRating = parsed >= 1 && parsed <= 5 ? parsed : null;

    if (newUserRating) {
      this._userRating = newUserRating;
    }

    try {
      const result = await ajax(`/sideloaded-apps/reviews/${topicId}`);
      if (result?.review) {
        this._communityAvgOverride = result.review.community_average;
        this._communityCountOverride = result.review.community_count;
      }
    } catch {
      // silent — values will refresh on next page load
    }
  }

  async _triggerVerification() {
    try {
      const result = await ajax("/sideloaded-apps/verify-now", {
        type: "POST",
        data: { topic_id: this.args.review.topic_id },
      });
      if (result.verification) {
        this._verificationOverride = result.verification;
      }
      if (result.last_access_date) {
        this._lastAccessOverride = result.last_access_date;
      }
    } catch {
      // silent — badge will stay "Unverified"
    }
  }

  get review() {
    return this._reviewOverride || this.args.review;
  }

  get currentVerification() {
    return this._verificationOverride || this.args.verification;
  }

  get categoryLabel() {
    if (!this.review?.app_category) {
      return "";
    }
    return i18n(`sideloaded_apps.categories.${this.review.app_category}`);
  }

  get hasScreenshots() {
    return this.review?.screenshot_urls?.length > 0;
  }

  get formattedLastAccess() {
    const date = this._lastAccessOverride || this.review?.last_access_date;
    if (!date) {
      return null;
    }
    return new Date(date).toLocaleDateString();
  }

  get communityAvg() {
    if (this._communityAvgOverride !== null) {
      const v = this._communityAvgOverride;
      return v > 0 ? Number(v).toFixed(1) : null;
    }
    const avg = this.review?.community_average;
    if (!avg || avg === 0) {
      return null;
    }
    return Number(avg).toFixed(1);
  }

  get communityCount() {
    if (this._communityCountOverride !== null) {
      return this._communityCountOverride;
    }
    return this.review?.community_count || 0;
  }

  get userRating() {
    return this._userRating ?? this.args.userRating;
  }

  get isAuthor() {
    return this.args.isAuthor;
  }

  get canRate() {
    return this.args.currentUser && !this.isAuthor;
  }

  get hasRated() {
    return !!this.userRating;
  }

  get canEdit() {
    if (!this.args.currentUser) {
      return false;
    }
    if (this.isAuthor) {
      return true;
    }
    return this.args.currentUser.staff;
  }

  get canReportOutdated() {
    return this.args.currentUser && !this.isAuthor && !this._reportOutdatedDone;
  }

  @action
  handleReportOutdated(event) {
    event?.preventDefault();
    if (!this.canReportOutdated) {
      return;
    }
    this.modal.show(ReportOutdatedModal, {
      model: {
        topic_id: this.review.topic_id,
        onSuccess: () => {
          this._reportOutdatedDone = true;
        },
      },
    });
  }

  @action
  async handleDownload(event) {
    event.preventDefault();
    if (this._downloadChecking) {
      return;
    }
    this._downloadChecking = true;
    try {
      const result = await ajax("/sideloaded-apps/track-download", {
        type: "POST",
        data: { topic_id: this.review.topic_id },
      });
      if (result.last_access_date) {
        this._lastAccessOverride = result.last_access_date;
      }
    } catch {
      // Even if tracking fails, still open the link
    } finally {
      this._downloadChecking = false;
      window.open(this.review.apk_link, "_blank", "noopener,noreferrer");
    }
  }

  @action
  async submitRating(value) {
    if (this._ratingSubmitting) {
      return;
    }
    this._ratingSubmitting = true;
    try {
      const result = await ajax("/sideloaded-apps/rate", {
        type: "POST",
        data: { topic_id: this.review.topic_id, rating: value },
      });
      this._userRating = result.user_rating;
      this._communityAvgOverride = result.community_average;
      this._communityCountOverride = result.community_count;
      this.args.onRated?.(result.user_rating);
    } catch (e) {
      if (e.jqXHR?.responseJSON?.user_rating) {
        this._userRating = e.jqXHR.responseJSON.user_rating;
      }
    } finally {
      this._ratingSubmitting = false;
    }
  }

  @action
  enterEditMode() {
    this._editVersion = this.review.apk_version || "";
    this._editLink = this.review.apk_link || "";
    this._editDescription = this.review.app_description || "";
    this._editKnownIssues = this.review.known_issues || "";
    this._editRating = this.review.author_rating || 0;
    this._editChecksum = this.review.apk_checksum || "";
    this._editScreenshots = (this.review.screenshot_urls || []).map((url) => ({
      url,
      original_filename: url.split("/").pop(),
    }));
    this._editIconUrl = this.review.icon_url || "";
    this._editIconValidationStatus = null;
    this._editIconValidationMessage = "";
    this._editIconPreviewUrl = null;
    this._editFieldErrors = {};
    this._touchedFields = new Set();
    this._editLinkValidationStatus = null;
    this._editLinkValidationMessage = "";
    const linkType = this.currentVerification?.link_type;
    this._editLinkIsDirectDownload =
      linkType === "file" ? true : linkType === "webpage" ? false : null;
    this._editMode = true;

    if (this._editIconUrl.trim()) {
      this._validateEditIcon();
    }
  }

  @action
  cancelEdit() {
    this._editFieldErrors = {};
    this._touchedFields = new Set();
    this._editLinkValidationStatus = null;
    this._editLinkValidationMessage = "";
    this._editIconValidationStatus = null;
    this._editIconValidationMessage = "";
    this._editIconPreviewUrl = null;
    this._editIconValidationToken++;
    this._editMode = false;
  }

  _normalizeChecksum(raw) {
    return (raw ?? "")
      .trim()
      .replace(/^sha-?256\s*[:=]\s*/i, "")
      .replace(/\s+/g, "")
      .toLowerCase();
  }

  _validateEditField(field) {
    if (!this._touchedFields.has(field)) {
      return;
    }

    let error = null;
    switch (field) {
      case "_editVersion": {
        const version = this._editVersion.trim();
        if (!version) {
          error = i18n("sideloaded_apps.form.validation.apk_version_required");
        } else {
          const versionPattern =
            /^v?\d+(?:\.\d+){0,4}(?:[-+][0-9A-Za-z][0-9A-Za-z.+-]*)?(?:\s*\(\d+\))?$/;
          if (!versionPattern.test(version)) {
            error = i18n("sideloaded_apps.form.validation.apk_version_invalid");
          }
        }
        break;
      }
      case "_editLink":
        if (!this._editLink.trim()) {
          error = i18n("sideloaded_apps.form.validation.required");
        } else if (!this._editLink.trim().match(/^https?:\/\/.+/)) {
          error = i18n("sideloaded_apps.form.validation.apk_link_url");
        }
        break;
      case "_editChecksum": {
        if (this.isEditChecksumDisabled) {
          break;
        }
        const normalized = this._normalizeChecksum(this._editChecksum);
        if (normalized && !/^[a-f0-9]{64}$/.test(normalized)) {
          error = i18n("sideloaded_apps.form.validation.checksum_invalid");
        }
        break;
      }
      case "_editDescription":
        if (!this._editDescription.trim()) {
          error = i18n("sideloaded_apps.form.validation.required");
        } else if (this._editDescription.trim().length < 20) {
          error = i18n("sideloaded_apps.form.validation.description_min");
        }
        break;
      case "_editRating":
        if (!this._editRating || this._editRating < 1 || this._editRating > 5) {
          error = i18n("sideloaded_apps.form.validation.rating_required");
        }
        break;
      default:
        break;
    }
    this._editFieldErrors = { ...this._editFieldErrors, [field]: error };
  }

  @action
  normalizeEditChecksum() {
    const normalized = this._normalizeChecksum(this._editChecksum);
    if (normalized && /^[a-f0-9]{64}$/.test(normalized)) {
      this._editChecksum = normalized;
    }
    this._touchedFields.add("_editChecksum");
    this._validateEditField("_editChecksum");
  }

  @action
  validateEditField(field) {
    this._touchedFields.add(field);
    this._validateEditField(field);
  }

  _scheduleEditValidate(field) {
    if (this._editValidateTimer) {
      cancel(this._editValidateTimer);
    }
    this._editValidateTimer = debounce(
      this,
      this._validateEditField,
      field,
      400
    );
  }

  get _hasEditErrors() {
    return (
      Object.values(this._editFieldErrors).some(Boolean) ||
      this._editLinkValidationStatus === "invalid" ||
      (this._editIconUrl?.trim() && this._editIconValidationStatus === "invalid")
    );
  }

  _validateEditLink() {
    const url = this._editLink.trim();
    if (!url || !url.match(/^https?:\/\/.+/)) {
      this._editLinkValidationStatus = null;
      this._editLinkValidationMessage = "";
      return;
    }

    if (url === (this.review.apk_link || "")) {
      this._editLinkValidationStatus = null;
      this._editLinkValidationMessage = "";
      return;
    }

    this._editLinkValidationStatus = "checking";
    this._editLinkValidationMessage = "";

    ajax("/sideloaded-apps/validate-link", {
      type: "POST",
      data: { url },
    })
      .then((result) => {
        if (!result.valid) {
          this._editLinkValidationStatus = "invalid";
          this._editLinkIsDirectDownload = null;
          this._editLinkValidationMessage =
            result.reason ||
            i18n("sideloaded_apps.link_validation.verification_failed");
        } else if (result.is_direct_download) {
          this._editLinkValidationStatus = "valid";
          this._editLinkIsDirectDownload = true;
          this._editLinkValidationMessage = i18n(
            "sideloaded_apps.link_validation.valid"
          );
        } else {
          this._editLinkValidationStatus = "info";
          this._editLinkIsDirectDownload = false;
          this._editLinkValidationMessage = i18n(
            "sideloaded_apps.link_validation.webpage_link"
          );
        }
      })
      .catch(() => {
        this._editLinkValidationStatus = "invalid";
        this._editLinkIsDirectDownload = null;
        this._editLinkValidationMessage = i18n(
          "sideloaded_apps.link_validation.verification_failed"
        );
      });
  }

  _validateEditIcon() {
    const url = this._editIconUrl.trim();
    const token = ++this._editIconValidationToken;

    this._editIconValidationStatus = "checking";
    this._editIconValidationMessage = "";

    validateIconUrl(url).then((result) => {
      if (token !== this._editIconValidationToken) {
        return;
      }
      if (result === "empty") {
        this._editIconValidationStatus = null;
        this._editIconValidationMessage = "";
        this._editIconPreviewUrl = null;
      } else if (result === "valid") {
        this._editIconValidationStatus = "valid";
        this._editIconValidationMessage = i18n(
          "sideloaded_apps.icon_validation.valid"
        );
        this._editIconPreviewUrl = url;
      } else {
        this._editIconValidationStatus = "invalid";
        this._editIconValidationMessage = i18n(
          `sideloaded_apps.icon_validation.${
            result === "invalid_url" ? "invalid_url" : "invalid"
          }`
        );
        this._editIconPreviewUrl = null;
      }
    });
  }

  get isEditChecksumDisabled() {
    return this._editLinkIsDirectDownload === false;
  }

  @action
  updateEditField(field, event) {
    this[field] = event.target.value;
    this._touchedFields.add(field);
    const fieldsToValidateOnChange = [
      "_editVersion",
      "_editLink",
      "_editDescription",
      "_editChecksum",
    ];
    if (fieldsToValidateOnChange.includes(field)) {
      this._scheduleEditValidate(field);
    }
    if (field === "_editLink") {
      if (this._editLinkDebounceTimer) {
        cancel(this._editLinkDebounceTimer);
      }
      this._editLinkDebounceTimer = debounce(this, this._validateEditLink, 800);
    }
    if (field === "_editIconUrl") {
      if (this._editIconDebounceTimer) {
        cancel(this._editIconDebounceTimer);
      }
      this._editIconDebounceTimer = debounce(this, this._validateEditIcon, 600);
    }
  }

  @action
  setEditRating(value) {
    this._editRating = value;
    this._touchedFields.add("_editRating");
    this._validateEditField("_editRating");
  }

  @action
  removeEditScreenshot(index) {
    this._editScreenshots = this._editScreenshots.filter((_, i) => i !== index);
  }

  @action
  async saveEdit() {
    if (this._saving) {
      return;
    }

    const allEditFields = [
      "_editVersion",
      "_editLink",
      "_editDescription",
      "_editRating",
      "_editChecksum",
    ];
    allEditFields.forEach((f) => {
      this._touchedFields.add(f);
      this._validateEditField(f);
    });
    if (this._hasEditErrors) {
      return;
    }

    if (this._editLinkValidationStatus === "checking") {
      const dialog =
        window.__container__?.lookup("service:dialog") ||
        window.Discourse?.__container__?.lookup("service:dialog");
      if (dialog) {
        dialog.alert(i18n("sideloaded_apps.link_validation.still_checking"));
      }
      return;
    }

    if (
      this._editIconUrl?.trim() &&
      this._editIconValidationStatus === "checking"
    ) {
      const dialog =
        window.__container__?.lookup("service:dialog") ||
        window.Discourse?.__container__?.lookup("service:dialog");
      if (dialog) {
        dialog.alert(i18n("sideloaded_apps.icon_validation.still_checking"));
      }
      return;
    }

    this._saving = true;

    try {
      const updateData = {
        apk_version: this._editVersion.trim(),
        apk_link: this._editLink.trim(),
        app_description: this._editDescription.trim(),
        known_issues: this._editKnownIssues.trim(),
        author_rating: this._editRating,
        apk_checksum: this.isEditChecksumDisabled
          ? ""
          : this._editChecksum.trim(),
        screenshot_urls: this._editScreenshots.map((s) => s.url),
        icon_url: this._editIconUrl.trim(),
      };

      const newLink = this._editLink.trim();
      const newChecksum = this._editChecksum.trim();
      const linkChanged = newLink !== (this.review.apk_link || "");
      const checksumChanged = newChecksum !== (this.review.apk_checksum || "");
      let isDirectDownload = this._editLinkIsDirectDownload;

      if (linkChanged && newLink) {
        const validation = await ajax("/sideloaded-apps/validate-link", {
          type: "POST",
          data: { url: newLink },
        });

        if (!validation.valid) {
          throw new Error(
            validation.reason ||
              i18n("sideloaded_apps.link_validation.verification_failed")
          );
        }

        isDirectDownload = validation.is_direct_download;
      }

      if (newLink && isDirectDownload && (linkChanged || checksumChanged)) {
        const checksumResult = await ajax("/sideloaded-apps/compute-checksum", {
          type: "POST",
          data: {
            url: newLink,
            user_checksum: newChecksum,
          },
        });

        if (!checksumResult.valid_download) {
          throw new Error(
            checksumResult.reason ||
              i18n("sideloaded_apps.link_validation.not_a_download")
          );
        }

        if (newChecksum && checksumResult.user_checksum_match === false) {
          throw new Error(
            i18n("sideloaded_apps.link_validation.checksum_mismatch")
          );
        }

        updateData.apk_checksum = checksumResult.checksum;
      }

      const result = await ajax(
        `/sideloaded-apps/reviews/${this.review.topic_id}`,
        {
          type: "PUT",
          data: { review: updateData },
        }
      );

      this._reviewOverride = result.review;
      if (result.verification) {
        this._verificationOverride = result.verification;
      }
      if (this.isEditChecksumDisabled) {
        this._editChecksum = "";
      }
      this._editMode = false;
    } catch (e) {
      const msg =
        e.message ||
        e.jqXHR?.responseJSON?.error ||
        e.jqXHR?.responseJSON?.errors?.join(", ") ||
        i18n("sideloaded_apps.link_validation.verification_failed");
      const dialog =
        window.__container__?.lookup("service:dialog") ||
        window.Discourse?.__container__?.lookup("service:dialog");
      if (dialog) {
        dialog.alert(msg);
      }
    } finally {
      this._saving = false;
    }
  }

  <template>
    {{#if this.review}}
      <div
        class="sideloaded-review-display
          {{if this._editMode 'sideloaded-review-display--editing'}}"
      >
        <div class="sideloaded-review-display__header">
          {{#if this.review.icon_url}}
            <img
              src={{this.review.icon_url}}
              alt=""
              class="sideloaded-review-display__app-icon"
            />
          {{/if}}
          <h3
            class="sideloaded-review-display__app-name"
          >{{this.review.app_name}}</h3>
          {{#if this.review.author_is_developer}}
            <span
              class="sideloaded-review-display__dev-badge"
              title={{i18n "sideloaded_apps.form.author_is_developer"}}
            >DEV</span>
          {{/if}}
          <span
            class="sideloaded-review-display__category-badge"
          >{{this.categoryLabel}}</span>
          <div class="sideloaded-review-display__header-actions">
            {{#if this.canEdit}}
              {{#unless this._editMode}}
                <button
                  type="button"
                  class="btn btn-small sideloaded-review-display__edit-btn"
                  {{on "click" this.enterEditMode}}
                >
                  {{i18n "sideloaded_apps.edit_review.button"}}
                </button>
              {{/unless}}
            {{/if}}
            {{#if this.canReportOutdated}}
              <button
                type="button"
                class="btn btn-default btn-small sideloaded-review-display__report-outdated"
                {{on "click" this.handleReportOutdated}}
              >
                {{i18n "sideloaded_apps.report_outdated"}}
              </button>
            {{/if}}
          </div>
        </div>

        {{#if this._editMode}}
          <div class="sideloaded-review-display__edit-form">
            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.apk_version"}}</label>
              <input
                type="text"
                value={{this._editVersion}}
                {{on "input" (fn this.updateEditField "_editVersion")}}
                {{on "blur" (fn this.validateEditField "_editVersion")}}
              />
              {{#if this._editFieldErrors._editVersion}}
                <span
                  class="sideloaded-form__error"
                >{{this._editFieldErrors._editVersion}}</span>
              {{/if}}
            </div>

            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.apk_link"}}</label>
              <input
                type="url"
                value={{this._editLink}}
                {{on "input" (fn this.updateEditField "_editLink")}}
                {{on "blur" (fn this.validateEditField "_editLink")}}
              />
              {{#if (eq this._editLinkValidationStatus "checking")}}
                <span class="sideloaded-link-status --checking">
                  {{i18n "sideloaded_apps.link_validation.checking"}}
                </span>
              {{else if (eq this._editLinkValidationStatus "valid")}}
                <span class="sideloaded-link-status --valid">
                  ✓
                  {{this._editLinkValidationMessage}}
                </span>
              {{else if (eq this._editLinkValidationStatus "info")}}
                <span class="sideloaded-link-status --info">
                  ℹ
                  {{this._editLinkValidationMessage}}
                </span>
              {{else if (eq this._editLinkValidationStatus "invalid")}}
                <span class="sideloaded-link-status --invalid">
                  ✗
                  {{this._editLinkValidationMessage}}
                </span>
              {{/if}}
              {{#if this._editFieldErrors._editLink}}
                <span
                  class="sideloaded-form__error"
                >{{this._editFieldErrors._editLink}}</span>
              {{/if}}
            </div>

            {{#unless this.isEditChecksumDisabled}}
              <div class="sideloaded-form__field">
                <label>{{i18n "sideloaded_apps.form.checksum"}}</label>
                <input
                  type="text"
                  autocomplete="off"
                  value={{this._editChecksum}}
                  {{on "input" (fn this.updateEditField "_editChecksum")}}
                  {{on "blur" this.normalizeEditChecksum}}
                />
                {{#if this._editFieldErrors._editChecksum}}
                  <span
                    class="sideloaded-form__error"
                  >{{this._editFieldErrors._editChecksum}}</span>
                {{/if}}
              </div>
            {{/unless}}

            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.author_rating"}}</label>
              <ApkStarRating
                @rating={{this._editRating}}
                @interactive={{true}}
                @onRate={{this.setEditRating}}
              />
              {{#if this._editFieldErrors._editRating}}
                <span
                  class="sideloaded-form__error"
                >{{this._editFieldErrors._editRating}}</span>
              {{/if}}
            </div>

            <div
              class="sideloaded-form__field sideloaded-form__field--icon-url"
            >
              <label>{{i18n "sideloaded_apps.form.icon_url"}}</label>
              <div class="sideloaded-icon-url-row">
                <div class="sideloaded-icon-url-row__input">
                  <input
                    type="url"
                    value={{this._editIconUrl}}
                    placeholder={{i18n "sideloaded_apps.form.icon_url"}}
                    aria-label={{i18n "sideloaded_apps.form.icon_url"}}
                    {{on "input" (fn this.updateEditField "_editIconUrl")}}
                  />
                  <span class="sideloaded-form__help">{{i18n
                      "sideloaded_apps.form.icon_url_help"
                    }}</span>
                  {{#if (eq this._editIconValidationStatus "checking")}}
                    <span class="sideloaded-link-status --checking">
                      {{i18n "sideloaded_apps.icon_validation.checking"}}
                    </span>
                  {{else if (eq this._editIconValidationStatus "valid")}}
                    <span class="sideloaded-link-status --valid">
                      ✓
                      {{this._editIconValidationMessage}}
                    </span>
                  {{else if (eq this._editIconValidationStatus "invalid")}}
                    <span class="sideloaded-link-status --invalid">
                      ✗
                      {{this._editIconValidationMessage}}
                    </span>
                  {{/if}}
                </div>
                {{#if this._editIconPreviewUrl}}
                  <div class="sideloaded-icon-preview">
                    <img
                      src={{this._editIconPreviewUrl}}
                      alt={{i18n "sideloaded_apps.icon_validation.preview_alt"}}
                      class="sideloaded-icon-preview__img"
                    />
                  </div>
                {{/if}}
              </div>
            </div>

            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.description"}}</label>
              <textarea
                rows="5"
                {{on "input" (fn this.updateEditField "_editDescription")}}
                {{on "blur" (fn this.validateEditField "_editDescription")}}
              >{{this._editDescription}}</textarea>
              {{#if this._editFieldErrors._editDescription}}
                <span
                  class="sideloaded-form__error"
                >{{this._editFieldErrors._editDescription}}</span>
              {{/if}}
            </div>

            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.known_issues"}}</label>
              <textarea
                rows="3"
                {{on "input" (fn this.updateEditField "_editKnownIssues")}}
              >{{this._editKnownIssues}}</textarea>
            </div>

            <div class="sideloaded-form__field">
              <label>{{i18n "sideloaded_apps.form.screenshots"}}</label>
              {{#if this._editScreenshots.length}}
                <div class="sideloaded-screenshot-preview">
                  {{#each this._editScreenshots as |shot index|}}
                    <div class="sideloaded-screenshot-preview__item">
                      <img
                        src={{shot.url}}
                        alt={{shot.original_filename}}
                        class="sideloaded-screenshot-preview__img"
                      />
                      <button
                        type="button"
                        class="sideloaded-screenshot-preview__remove"
                        title={{i18n "sideloaded_apps.form.remove_screenshot"}}
                        {{on "click" (fn this.removeEditScreenshot index)}}
                      >&times;</button>
                    </div>
                  {{/each}}
                </div>
              {{/if}}
              <div class="sideloaded-screenshot-upload">
                <PickFilesButton
                  @registerFileInput={{this.editUppyUpload.setup}}
                  @fileInputId="sl-edit-screenshot-upload"
                  @fileInputClass="hidden-upload-field"
                  @allowMultiple={{true}}
                  @acceptedFormatsOverride=".jpg,.jpeg,.png,.gif,.webp"
                  @showButton={{true}}
                  @onFilesPicked={{true}}
                  @label="sideloaded_apps.form.add_screenshot"
                  @icon="image"
                />
              </div>
            </div>

            <div class="sideloaded-review-display__edit-actions">
              <button
                type="button"
                class="btn btn-primary"
                disabled={{this._saving}}
                {{on "click" this.saveEdit}}
              >
                {{#if this._saving}}
                  {{i18n "sideloaded_apps.edit_review.saving"}}
                {{else}}
                  {{i18n "sideloaded_apps.edit_review.save"}}
                {{/if}}
              </button>
              <button
                type="button"
                class="btn btn-default"
                disabled={{this._saving}}
                {{on "click" this.cancelEdit}}
              >
                {{i18n "sideloaded_apps.edit_review.cancel"}}
              </button>
            </div>
          </div>
        {{else}}
          <div class="sideloaded-review-display__info-grid">
            <div class="sideloaded-review-display__info-item">
              <span class="sideloaded-review-display__label">{{i18n
                  "sideloaded_apps.form.apk_version"
                }}</span>
              <span
                class="sideloaded-review-display__value"
              >{{this.review.apk_version}}</span>
            </div>

            <div class="sideloaded-review-display__info-item">
              <span class="sideloaded-review-display__label">{{i18n
                  "sideloaded_apps.rating.author"
                }}</span>
              <ApkStarRating
                @rating={{this.review.author_rating}}
                @interactive={{false}}
              />
            </div>

            <div class="sideloaded-review-display__info-item">
              <span class="sideloaded-review-display__label">{{i18n
                  "sideloaded_apps.rating.community"
                }}</span>
              {{#if this.communityAvg}}
                <span class="sideloaded-review-display__avg-rating">
                  <span class="sideloaded-review-display__avg-stars">★</span>
                  <span
                    class="sideloaded-review-display__avg-value"
                  >{{this.communityAvg}}</span>
                  <span class="sideloaded-review-display__avg-count">
                    ({{this.communityCount}}
                    {{i18n "sideloaded_apps.rating.count"}})
                  </span>
                </span>
              {{else}}
                <span class="sideloaded-review-display__avg-rating --empty">
                  {{i18n "sideloaded_apps.rating.no_ratings"}}
                </span>
              {{/if}}
            </div>

            {{#if this.canRate}}
              <div class="sideloaded-review-display__info-item">
                <span class="sideloaded-review-display__label">{{i18n
                    "sideloaded_apps.inline_rating.your_rating"
                  }}</span>
                <ApkStarRating
                  @rating={{this.userRating}}
                  @interactive={{true}}
                  @onRate={{this.submitRating}}
                />
              </div>
            {{/if}}

          </div>

          <div class="sideloaded-review-display__download">
            <div class="sideloaded-review-display__download-row">
              <button
                type="button"
                class="btn btn-primary sideloaded-review-display__download-btn"
                disabled={{this._downloadChecking}}
                {{on "click" this.handleDownload}}
              >
                {{#if this._downloadChecking}}
                  {{i18n "sideloaded_apps.download_checking"}}
                {{else}}
                  {{i18n "sideloaded_apps.download_apk"}}
                {{/if}}
              </button>
              <ApkVerificationStatus
                @verification={{this.currentVerification}}
                @alwaysShow={{true}}
              />
            </div>

            <div class="sideloaded-review-display__download-meta">
              {{#if this.review.apk_checksum}}
                <div class="sideloaded-review-display__download-meta-item">
                  <span
                    class="sideloaded-review-display__download-meta-label"
                  >{{i18n "sideloaded_apps.form.checksum_label"}}</span>
                  <span
                    class="sideloaded-review-display__checksum"
                  >{{this.review.apk_checksum}}</span>
                </div>
              {{/if}}
            </div>
          </div>

          {{#if this.review.app_description}}
            <div class="sideloaded-review-display__description">
              <p>{{this.review.app_description}}</p>
            </div>
          {{/if}}

          {{#if this.hasScreenshots}}
            <div class="sideloaded-review-display__screenshots">
              <h4>{{i18n "sideloaded_apps.form.screenshots"}}</h4>
              <div class="sideloaded-review-display__screenshot-grid">
                {{#each this.review.screenshot_urls as |url|}}
                  <a href={{url}} target="_blank" rel="noopener noreferrer">
                    <img
                      src={{url}}
                      alt="Screenshot"
                      class="sideloaded-review-display__screenshot"
                      loading="lazy"
                    />
                  </a>
                {{/each}}
              </div>
            </div>
          {{/if}}

          {{#if this.review.known_issues}}
            <div class="sideloaded-review-display__known-issues">
              <h4>{{i18n "sideloaded_apps.form.known_issues"}}</h4>
              <p>{{this.review.known_issues}}</p>
            </div>
          {{/if}}
        {{/if}}
      </div>
    {{/if}}
  </template>
}
