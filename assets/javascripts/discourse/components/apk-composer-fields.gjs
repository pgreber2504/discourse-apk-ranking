import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { cancel, debounce, schedule } from "@ember/runloop";
import { service } from "@ember/service";
import PickFilesButton from "discourse/components/pick-files-button";
import { ajax } from "discourse/lib/ajax";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { validateIconUrl } from "../lib/validate-icon-url";
import ApkStarRating from "./apk-star-rating";

let _pendingApkData = null;
let _validateAllCallback = null;

export function getPendingApkData() {
  return _pendingApkData;
}

export function clearPendingApkData() {
  _pendingApkData = null;
}

export function triggerValidateAll() {
  return _validateAllCallback ? _validateAllCallback() : true;
}

export default class ApkComposerFields extends Component {
  @service currentUser;

  @tracked appName = "";
  @tracked appCategory = "";
  @tracked apkLink = "";
  @tracked apkVersion = "";
  @tracked apkChecksum = "";
  @tracked authorRating = 0;
  @tracked appDescription = "";
  @tracked knownIssues = "";
  @tracked authorIsDeveloper = false;
  @tracked iconUrl = "";

  @tracked linkValidationStatus = null; // null | "checking" | "valid" | "info" | "invalid"
  @tracked linkValidationMessage = "";
  @tracked linkFileSize = null;
  @tracked linkIsDirectDownload = null;
  @tracked iconValidationStatus = null; // null | "checking" | "valid" | "invalid"
  @tracked iconValidationMessage = "";
  @tracked iconPreviewUrl = null;
  @tracked screenshots = [];
  @tracked fieldErrors = {};
  uppyUpload = new UppyUpload(getOwner(this), {
    id: "sideloaded-screenshot-uploader",
    type: "composer",
    validateUploadedFilesOptions: { imagesOnly: true },
    uploadDone: (upload) => {
      this.screenshots = [
        ...this.screenshots,
        { url: upload.url, original_filename: upload.original_filename },
      ];
      this._syncToModel();
    },
  });
  _debounceTimer = null;
  _validateDebounceTimer = null;
  _iconDebounceTimer = null;
  _iconValidationToken = 0;

  constructor() {
    super(...arguments);
    document.body.classList.add("sideloaded-composer-active");
    _validateAllCallback = () => this.validateAll();

    if (_pendingApkData) {
      this._hydrateFromPendingData(_pendingApkData);
    } else {
      try {
        const metaData = this._getModelMetaData();
        if (metaData && this._hasApkData(metaData)) {
          this._hydrateFromMetaData(metaData);
        }
      } catch {
        // ignore: avoid breaking composer when draft metaData is unexpected
      }
    }

    if (this.iconUrl?.trim()) {
      this._validateIcon();
    }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    document.body.classList.remove("sideloaded-composer-active");
    _validateAllCallback = null;
    if (this._debounceTimer) {
      cancel(this._debounceTimer);
    }
    if (this._validateDebounceTimer) {
      cancel(this._validateDebounceTimer);
    }
    if (this._iconDebounceTimer) {
      cancel(this._iconDebounceTimer);
    }
    this._iconValidationToken++;
  }

  _getModelMetaData() {
    const model = this.args?.model;
    if (!model) {
      return null;
    }
    const md = model.metaData ?? model.get?.("metaData");
    return md && typeof md === "object" ? md : null;
  }

  _hasApkData(metaData) {
    const get = (k) => metaData?.get?.(k) ?? metaData?.[k];
    return (
      get("apk_app_name") ||
      get("apk_link") ||
      get("apk_version") ||
      get("apk_description")
    );
  }

  _hydrateFromPendingData(data) {
    this.appName = data.app_name || "";
    this.appCategory = data.app_category || "";
    this.apkLink = data.apk_link || "";
    this.apkVersion = data.apk_version || "";
    this.apkChecksum = data.apk_checksum || "";
    this.authorRating = data.author_rating || 0;
    this.appDescription = data.app_description || "";
    this.knownIssues = data.known_issues || "";
    this.authorIsDeveloper = !!data.author_is_developer;
    this.iconUrl = data.icon_url || "";
    this.linkIsDirectDownload = data.is_direct_download ?? null;
    this.screenshots = data.screenshots || [];
  }

  _get(obj, key) {
    return obj?.get?.(key) ?? obj?.[key];
  }

  _hydrateFromMetaData(metaData) {
    if (!metaData) {
      return;
    }
    this.appName = this._get(metaData, "apk_app_name") || "";
    this.appCategory = this._get(metaData, "apk_app_category") || "";
    this.apkLink = this._get(metaData, "apk_link") || "";
    this.apkVersion = this._get(metaData, "apk_version") || "";
    this.apkChecksum = this._get(metaData, "apk_checksum") || "";
    const r = this._get(metaData, "apk_author_rating");
    this.authorRating = r ? parseInt(r, 10) || 0 : 0;
    this.appDescription = this._get(metaData, "apk_description") || "";
    this.knownIssues = this._get(metaData, "apk_known_issues") || "";
    this.authorIsDeveloper =
      this._get(metaData, "apk_author_is_developer") === "true";
    this.iconUrl = this._get(metaData, "apk_icon_url") || "";
    const urlsRaw = this._get(metaData, "apk_screenshot_urls");
    if (typeof urlsRaw === "string" && urlsRaw) {
      try {
        const urls = JSON.parse(urlsRaw);
        this.screenshots = Array.isArray(urls)
          ? urls.map((u) => ({ url: u, original_filename: "" }))
          : [];
      } catch {
        this.screenshots = [];
      }
    } else {
      this.screenshots = [];
    }
  }

  _normalizeChecksum(raw) {
    return (raw ?? "")
      .trim()
      .replace(/^sha-?256\s*[:=]\s*/i, "")
      .replace(/\s+/g, "")
      .toLowerCase();
  }

  _computeFieldError(field) {
    const name = this.appName?.trim() ?? "";
    const link = this.apkLink?.trim() ?? "";
    const version = this.apkVersion?.trim() ?? "";
    const desc = this.appDescription?.trim() ?? "";

    // Accepts 1, 1.2, 1.2.3, v1.2.3, 1.2.3-beta, 1.2.3+build.5, 1.2.3 (456)
    const versionPattern =
      /^v?\d+(?:\.\d+){0,4}(?:[-+][0-9A-Za-z][0-9A-Za-z.+-]*)?(?:\s*\(\d+\))?$/;

    switch (field) {
      case "appName":
        if (!name) {
          return i18n("sideloaded_apps.form.validation.required");
        }
        if (name.length < 2) {
          return i18n("sideloaded_apps.form.validation.app_name_min");
        }
        if (name.length > 100) {
          return i18n("sideloaded_apps.form.validation.app_name_max");
        }
        return null;
      case "appCategory":
        if (!this.appCategory) {
          return i18n("sideloaded_apps.form.validation.category_required");
        }
        return null;
      case "apkLink":
        if (!link) {
          return i18n("sideloaded_apps.form.validation.required");
        }
        if (!link.match(/^https?:\/\/.+/)) {
          return i18n("sideloaded_apps.form.validation.apk_link_url");
        }
        return null;
      case "apkVersion":
        if (!version) {
          return i18n("sideloaded_apps.form.validation.apk_version_required");
        }
        if (!versionPattern.test(version)) {
          return i18n("sideloaded_apps.form.validation.apk_version_invalid");
        }
        return null;
      case "apkChecksum": {
        const rawChecksum = this.apkChecksum?.trim() ?? "";
        if (!rawChecksum) {
          return null;
        }
        const normalized = this._normalizeChecksum(rawChecksum);
        if (!/^[a-f0-9]{64}$/.test(normalized)) {
          return i18n("sideloaded_apps.form.validation.checksum_invalid");
        }
        return null;
      }
      case "authorRating":
        if (
          !this.authorRating ||
          this.authorRating < 1 ||
          this.authorRating > 5
        ) {
          return i18n("sideloaded_apps.form.validation.rating_required");
        }
        return null;
      case "appDescription":
        if (!desc) {
          return i18n("sideloaded_apps.form.validation.required");
        }
        if (desc.length < 20) {
          return i18n("sideloaded_apps.form.validation.description_min");
        }
        return null;
      default:
        return null;
    }
  }

  _validateField(field) {
    this.fieldErrors = {
      ...this.fieldErrors,
      [field]: this._computeFieldError(field),
    };
  }

  validateAll() {
    const FIELDS = [
      "appName",
      "appCategory",
      "apkLink",
      "apkVersion",
      "apkChecksum",
      "authorRating",
      "appDescription",
    ];

    const errors = {};
    for (const field of FIELDS) {
      errors[field] = this._computeFieldError(field);
    }

    // Overlay link validation status on the apkLink error (if no format error already)
    if (!errors.apkLink) {
      if (this.linkValidationStatus === "invalid") {
        errors.apkLink = i18n(
          "sideloaded_apps.link_validation.cannot_submit_invalid"
        );
      } else if (this.linkValidationStatus === "checking") {
        errors.apkLink = i18n("sideloaded_apps.link_validation.still_checking");
      }
    }

    // Icon URL is optional, but if provided it must resolve to a real image
    if (this.iconUrl?.trim()) {
      if (this.iconValidationStatus === "invalid") {
        errors.iconUrl = i18n(
          "sideloaded_apps.icon_validation.cannot_submit_invalid"
        );
      } else if (this.iconValidationStatus === "checking") {
        errors.iconUrl = i18n("sideloaded_apps.icon_validation.still_checking");
      }
    }

    this.fieldErrors = errors;

    const hasErrors = Object.values(errors).some(Boolean);
    if (hasErrors) {
      schedule("afterRender", () => {
        const firstErrorField = document.querySelector(
          ".sideloaded-form__field.--has-error"
        );
        firstErrorField?.scrollIntoView({
          behavior: "smooth",
          block: "center",
        });
      });
    }
    return !hasErrors;
  }

  @action
  validateField(field) {
    this._validateField(field);
  }

  _scheduleValidate(field) {
    if (this._validateDebounceTimer) {
      cancel(this._validateDebounceTimer);
    }
    this._validateDebounceTimer = debounce(
      this,
      this._validateField,
      field,
      400
    );
  }

  _validateLink() {
    const url = this.apkLink.trim();
    if (!url || !url.match(/^https?:\/\/.+/)) {
      this.linkValidationStatus = null;
      this.linkValidationMessage = "";
      this.linkFileSize = null;
      this.linkIsDirectDownload = null;
      return;
    }

    this.linkValidationStatus = "checking";
    this.linkValidationMessage = "";

    ajax("/sideloaded-apps/validate-link", {
      type: "POST",
      data: { url },
    })
      .then((result) => {
        if (!result.valid) {
          this.linkValidationStatus = "invalid";
          this.linkFileSize = null;
          this.linkIsDirectDownload = false;
          this.linkValidationMessage =
            result.reason ||
            i18n("sideloaded_apps.link_validation.verification_failed");
        } else if (result.is_direct_download) {
          this.linkValidationStatus = "valid";
          this.linkFileSize = result.file_size;
          this.linkIsDirectDownload = true;
          this.linkValidationMessage = i18n(
            "sideloaded_apps.link_validation.valid"
          );
        } else {
          this.linkValidationStatus = "info";
          this.linkFileSize = null;
          this.linkIsDirectDownload = false;
          this.linkValidationMessage = i18n(
            "sideloaded_apps.link_validation.webpage_link"
          );
        }
        this._syncToModel();
      })
      .catch(() => {
        this.linkValidationStatus = "invalid";
        this.linkFileSize = null;
        this.linkIsDirectDownload = false;
        this.linkValidationMessage = i18n(
          "sideloaded_apps.link_validation.verification_failed"
        );
      });
  }

  _validateIcon() {
    const url = this.iconUrl.trim();
    const token = ++this._iconValidationToken;

    this.iconValidationStatus = "checking";
    this.iconValidationMessage = "";

    validateIconUrl(url).then((result) => {
      if (token !== this._iconValidationToken) {
        return;
      }
      if (result === "empty") {
        this.iconValidationStatus = null;
        this.iconValidationMessage = "";
        this.iconPreviewUrl = null;
      } else if (result === "valid") {
        this.iconValidationStatus = "valid";
        this.iconValidationMessage = i18n(
          "sideloaded_apps.icon_validation.valid"
        );
        this.iconPreviewUrl = url;
      } else {
        this.iconValidationStatus = "invalid";
        this.iconValidationMessage = i18n(
          `sideloaded_apps.icon_validation.${
            result === "invalid_url" ? "invalid_url" : "invalid"
          }`
        );
        this.iconPreviewUrl = null;
      }
    });
  }

  get model() {
    return this.args.model;
  }

  get isChecksumDisabled() {
    return this.linkIsDirectDownload === false;
  }

  get appCategories() {
    return [
      {
        value: "communication",
        label: i18n("sideloaded_apps.categories.communication"),
      },
      {
        value: "productivity",
        label: i18n("sideloaded_apps.categories.productivity"),
      },
      {
        value: "utilities",
        label: i18n("sideloaded_apps.categories.utilities"),
      },
      { value: "health", label: i18n("sideloaded_apps.categories.health") },
      { value: "finance", label: i18n("sideloaded_apps.categories.finance") },
      {
        value: "entertainment",
        label: i18n("sideloaded_apps.categories.entertainment"),
      },
      { value: "music", label: i18n("sideloaded_apps.categories.music") },
      {
        value: "navigation",
        label: i18n("sideloaded_apps.categories.navigation"),
      },
      { value: "weather", label: i18n("sideloaded_apps.categories.weather") },
      { value: "news", label: i18n("sideloaded_apps.categories.news") },
      {
        value: "education",
        label: i18n("sideloaded_apps.categories.education"),
      },
      { value: "other", label: i18n("sideloaded_apps.categories.other") },
    ];
  }

  _syncToModel() {
    const name = this.appName.trim();
    const version = this.apkVersion.trim();

    if (!this.model) {
      return;
    }

    const authorName =
      this.currentUser?.username || this.currentUser?.name || "Author";
    if (name) {
      this.model.set("title", `${name} review by ${authorName}`);
    }

    const parts = [`**${name || "App"}** — Community App Review`];
    if (version) {
      parts.push(`Version: ${version}`);
    }
    if (this.appDescription.trim()) {
      parts.push(`\n${this.appDescription.trim()}`);
    }
    this.model.set("reply", parts.join("\n"));

    this.model.notifyPropertyChange("reply");
    this.model.notifyPropertyChange("title");

    const normalizedChecksum = this._normalizeChecksum(this.apkChecksum);
    const isWebpage = this.linkIsDirectDownload === false;
    const checksumForSave = isWebpage
      ? ""
      : /^[a-f0-9]{64}$/.test(normalizedChecksum)
        ? normalizedChecksum
        : this.apkChecksum.trim();

    _pendingApkData = {
      app_name: this.appName.trim(),
      app_category: this.appCategory,
      apk_link: this.apkLink.trim(),
      apk_version: this.apkVersion.trim(),
      apk_checksum: checksumForSave,
      author_rating: this.authorRating,
      app_description: this.appDescription.trim(),
      known_issues: this.knownIssues.trim(),
      is_direct_download: this.linkIsDirectDownload,
      link_validation_status: this.linkValidationStatus,
      screenshots: this.screenshots,
      author_is_developer: this.authorIsDeveloper,
      icon_url: this.iconUrl.trim(),
    };

    const screenshotUrls = this.screenshots.map((s) => s.url);

    this.model?.set("metaData", {
      apk_app_name: name,
      apk_app_category: this.appCategory,
      apk_link: this.apkLink.trim(),
      apk_version: version,
      apk_author_rating: String(this.authorRating),
      apk_description: this.appDescription.trim(),
      apk_known_issues: this.knownIssues.trim(),
      apk_checksum: checksumForSave,
      apk_screenshot_urls: JSON.stringify(screenshotUrls),
      apk_author_is_developer: this.authorIsDeveloper ? "true" : "false",
      apk_icon_url: this.iconUrl.trim() || "",
    });
  }

  @action
  updateField(field, event) {
    this[field] = event.target.value;
    this._syncToModel();

    if (field === "apkLink") {
      this._debounceTimer = debounce(this, this._validateLink, 800);
    }

    if (field === "iconUrl") {
      this._iconDebounceTimer = debounce(this, this._validateIcon, 600);
    }

    const validateOnChange = [
      "appName",
      "apkLink",
      "apkVersion",
      "apkChecksum",
      "appDescription",
    ];
    if (validateOnChange.includes(field)) {
      this._scheduleValidate(field);
    } else if (field === "appCategory") {
      this.validateField(field);
    }
  }

  @action
  normalizeChecksumField() {
    const raw = this.apkChecksum?.trim() ?? "";
    if (raw) {
      const normalized = this._normalizeChecksum(raw);
      if (/^[a-f0-9]{64}$/.test(normalized) && normalized !== raw) {
        this.apkChecksum = normalized;
        this._syncToModel();
      }
    }
    this.validateField("apkChecksum");
  }

  @action
  setRating(value) {
    this.authorRating = value;
    this._syncToModel();
    this.validateField("authorRating");
  }

  @action
  removeScreenshot(index) {
    this.screenshots = this.screenshots.filter((_, i) => i !== index);
    this._syncToModel();
  }

  @action
  toggleAuthorIsDeveloper(event) {
    this.authorIsDeveloper = event.target.checked;
    this._syncToModel();
  }

  <template>
    <div class="sideloaded-composer-fields">
      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.appName '--has-error'}}"
      >
        <input
          id="sl-composer-app-name"
          type="text"
          value={{this.appName}}
          aria-label={{i18n "sideloaded_apps.form.app_name"}}
          placeholder={{i18n "sideloaded_apps.form.app_name"}}
          {{on "input" (fn this.updateField "appName")}}
          {{on "blur" (fn this.validateField "appName")}}
        />
        {{#if this.fieldErrors.appName}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.appName}}</span>
        {{/if}}
      </div>

      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.appCategory '--has-error'}}"
      >
        <select
          id="sl-composer-app-category"
          aria-label={{i18n "sideloaded_apps.form.app_category"}}
          {{on "change" (fn this.updateField "appCategory")}}
          {{on "blur" (fn this.validateField "appCategory")}}
        >
          <option value="">{{i18n
              "sideloaded_apps.form.app_category"
            }}</option>
          {{#each this.appCategories as |cat|}}
            <option
              value={{cat.value}}
              selected={{eq cat.value this.appCategory}}
            >
              {{cat.label}}
            </option>
          {{/each}}
        </select>
        {{#if this.fieldErrors.appCategory}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.appCategory}}</span>
        {{/if}}
      </div>

      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.apkLink '--has-error'}}"
      >
        <input
          id="sl-composer-apk-link"
          type="url"
          value={{this.apkLink}}
          aria-label={{i18n "sideloaded_apps.form.apk_link"}}
          placeholder={{i18n "sideloaded_apps.form.apk_link"}}
          {{on "input" (fn this.updateField "apkLink")}}
          {{on "blur" (fn this.validateField "apkLink")}}
        />
        <span class="sideloaded-form__help">{{i18n
            "sideloaded_apps.form.apk_link_help"
          }}</span>
        {{#if (eq this.linkValidationStatus "checking")}}
          <span class="sideloaded-link-status --checking">
            {{i18n "sideloaded_apps.link_validation.checking"}}
          </span>
        {{else if (eq this.linkValidationStatus "valid")}}
          <span class="sideloaded-link-status --valid">
            ✓
            {{this.linkValidationMessage}}
            {{#if this.linkFileSize}}
              ({{i18n
                "sideloaded_apps.link_validation.file_size_bytes"
                count=this.linkFileSize
              }})
            {{/if}}
          </span>
        {{else if (eq this.linkValidationStatus "info")}}
          <span class="sideloaded-link-status --info">
            ℹ
            {{this.linkValidationMessage}}
          </span>
        {{else if (eq this.linkValidationStatus "invalid")}}
          <span class="sideloaded-link-status --invalid">
            ✗
            {{this.linkValidationMessage}}
          </span>
        {{/if}}
        {{#if this.fieldErrors.apkLink}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.apkLink}}</span>
        {{/if}}
      </div>

      {{#unless this.isChecksumDisabled}}
        <div
          class="sideloaded-form__field
            {{if this.fieldErrors.apkChecksum '--has-error'}}"
        >
          <input
            id="sl-composer-checksum"
            type="text"
            value={{this.apkChecksum}}
            aria-label={{i18n "sideloaded_apps.form.checksum"}}
            placeholder={{i18n "sideloaded_apps.form.checksum"}}
            autocomplete="off"
            spellcheck="false"
            {{on "input" (fn this.updateField "apkChecksum")}}
            {{on "blur" this.normalizeChecksumField}}
          />
          <span class="sideloaded-form__help">{{i18n
              "sideloaded_apps.form.checksum_help"
            }}</span>
          {{#if this.fieldErrors.apkChecksum}}
            <span
              class="sideloaded-form__error"
            >{{this.fieldErrors.apkChecksum}}</span>
          {{/if}}
        </div>
      {{/unless}}

      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.apkVersion '--has-error'}}"
      >
        <input
          id="sl-composer-apk-version"
          type="text"
          value={{this.apkVersion}}
          aria-label={{i18n "sideloaded_apps.form.apk_version"}}
          placeholder={{i18n "sideloaded_apps.form.apk_version"}}
          {{on "input" (fn this.updateField "apkVersion")}}
          {{on "blur" (fn this.validateField "apkVersion")}}
        />
        {{#if this.fieldErrors.apkVersion}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.apkVersion}}</span>
        {{/if}}
      </div>

      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.authorRating '--has-error'}}"
      >
        <label>{{i18n "sideloaded_apps.form.author_rating"}}</label>
        <ApkStarRating
          @rating={{this.authorRating}}
          @interactive={{true}}
          @onRate={{this.setRating}}
        />
        <span class="sideloaded-form__help">{{i18n
            "sideloaded_apps.form.author_rating_help"
          }}</span>
        {{#if this.fieldErrors.authorRating}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.authorRating}}</span>
        {{/if}}
      </div>

      <div class="sideloaded-form__field sideloaded-form__field--checkbox">
        <label>
          <input
            type="checkbox"
            checked={{this.authorIsDeveloper}}
            {{on "change" this.toggleAuthorIsDeveloper}}
          />
          {{i18n "sideloaded_apps.form.author_is_developer"}}
        </label>
      </div>

      <div
        class="sideloaded-form__field sideloaded-form__field--icon-url
          {{if this.fieldErrors.iconUrl '--has-error'}}"
      >
        <div class="sideloaded-icon-url-row">
          <div class="sideloaded-icon-url-row__input">
            <input
              id="sl-composer-icon-url"
              type="url"
              value={{this.iconUrl}}
              aria-label={{i18n "sideloaded_apps.form.icon_url"}}
              placeholder={{i18n "sideloaded_apps.form.icon_url"}}
              {{on "input" (fn this.updateField "iconUrl")}}
            />
            <span class="sideloaded-form__help">{{i18n
                "sideloaded_apps.form.icon_url_help"
              }}</span>
            {{#if (eq this.iconValidationStatus "checking")}}
              <span class="sideloaded-link-status --checking">
                {{i18n "sideloaded_apps.icon_validation.checking"}}
              </span>
            {{else if (eq this.iconValidationStatus "valid")}}
              <span class="sideloaded-link-status --valid">
                ✓
                {{this.iconValidationMessage}}
              </span>
            {{else if (eq this.iconValidationStatus "invalid")}}
              <span class="sideloaded-link-status --invalid">
                ✗
                {{this.iconValidationMessage}}
              </span>
            {{/if}}
            {{#if this.fieldErrors.iconUrl}}
              <span
                class="sideloaded-form__error"
              >{{this.fieldErrors.iconUrl}}</span>
            {{/if}}
          </div>
          {{#if this.iconPreviewUrl}}
            <div class="sideloaded-icon-preview">
              <img
                src={{this.iconPreviewUrl}}
                alt={{i18n "sideloaded_apps.icon_validation.preview_alt"}}
                class="sideloaded-icon-preview__img"
              />
            </div>
          {{/if}}
        </div>
      </div>

      <div
        class="sideloaded-form__field
          {{if this.fieldErrors.appDescription '--has-error'}}"
      >
        <textarea
          id="sl-composer-description"
          rows="5"
          aria-label={{i18n "sideloaded_apps.form.description"}}
          placeholder={{i18n "sideloaded_apps.form.description"}}
          {{on "input" (fn this.updateField "appDescription")}}
          {{on "blur" (fn this.validateField "appDescription")}}
        >{{this.appDescription}}</textarea>
        {{#if this.fieldErrors.appDescription}}
          <span
            class="sideloaded-form__error"
          >{{this.fieldErrors.appDescription}}</span>
        {{/if}}
      </div>

      <div class="sideloaded-form__field">
        <textarea
          id="sl-composer-known-issues"
          rows="3"
          aria-label={{i18n "sideloaded_apps.form.known_issues"}}
          placeholder={{i18n "sideloaded_apps.form.known_issues"}}
          {{on "input" (fn this.updateField "knownIssues")}}
        >{{this.knownIssues}}</textarea>
      </div>

      <div class="sideloaded-form__field">
        <label>{{i18n "sideloaded_apps.form.screenshots"}}</label>
        <span class="sideloaded-form__help">{{i18n
            "sideloaded_apps.form.screenshots_help"
          }}</span>

        {{#if this.screenshots.length}}
          <div class="sideloaded-screenshot-preview">
            {{#each this.screenshots as |shot index|}}
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
                  {{on "click" (fn this.removeScreenshot index)}}
                >&times;</button>
              </div>
            {{/each}}
          </div>
        {{/if}}

        <div class="sideloaded-screenshot-upload">
          <PickFilesButton
            @registerFileInput={{this.uppyUpload.setup}}
            @fileInputId="sl-screenshot-upload"
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
    </div>
  </template>
}
