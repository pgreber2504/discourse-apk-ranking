import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import ApkComposerFields, {
  clearPendingApkData,
  getPendingApkData,
  triggerValidateAll,
} from "../components/apk-composer-fields";
import ApkReviewDisplay from "../components/apk-review-display";
import ApkStarRating from "../components/apk-star-rating";

// Client-side cache: once a user rates a topic, remember it across
// composer re-opens (the server value only updates on full page reload)
const _userRatingsCache = {};

// Staff can toggle to create normal info posts (tutorial, FAQ) instead of app reviews
let _composerInfoPostMode = false;

export function getComposerInfoPostMode() {
  return _composerInfoPostMode;
}

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  if (!siteSettings.sideloaded_apps_ranking_enabled) {
    return;
  }

  const categorySlug = siteSettings.sideloaded_apps_category_slug;

  // ── 1. NAVIGATION TAB ─────────────────────────────
  api.addNavigationBarItem({
    name: "sideloaded-apps",
    displayName: i18n("sideloaded_apps.nav_label"),
    href: `/c/${categorySlug}`,
    customFilter: (category) => !category,
    forceActive: (category, args, router) =>
      router.currentURL?.includes(`/c/${categorySlug}`),
  });

  // ── 2. HOMEPAGE BANNER ─────────────────────────────
  api.renderInOutlet(
    "discovery-above",
    class SideloadedBanner extends Component {
      static shouldRender(args) {
        return args.category?.slug !== categorySlug;
      }

      get categoryUrl() {
        return `/c/${categorySlug}`;
      }

      <template>
        <div class="sideloaded-apps-banner">
          <div class="sideloaded-apps-banner__content">
            <h3 class="sideloaded-apps-banner__title">{{i18n
                "sideloaded_apps.banner.title"
              }}</h3>
            <p class="sideloaded-apps-banner__text">{{i18n
                "sideloaded_apps.banner.text"
              }}</p>
            <a
              href={{this.categoryUrl}}
              class="btn btn-primary sideloaded-apps-banner__link"
            >
              {{i18n "sideloaded_apps.banner.cta"}}
            </a>
          </div>
        </div>
      </template>
    }
  );

  // ── 2b. CATEGORY FILTER PILLS ───────────────────────
  const APP_CATEGORIES = [
    "communication",
    "social",
    "productivity",
    "utilities",
    "health",
    "finance",
    "entertainment",
    "music",
    "navigation",
    "weather",
    "news",
    "education",
    "other",
  ];

  api.renderInOutlet(
    "discovery-above",
    class SideloadedCategoryFilter extends Component {
      static shouldRender(args) {
        return args.category?.slug === categorySlug;
      }

      @tracked activeCategory = null;

      get pills() {
        return APP_CATEGORIES.map((cat) => ({
          key: cat,
          label: i18n(`sideloaded_apps.categories.${cat}`),
          active: this.activeCategory === cat,
        }));
      }

      _updateBodyClass() {
        document.body.classList.forEach((c) => {
          if (c.startsWith("apk-filter--")) {
            document.body.classList.remove(c);
          }
        });
        if (this.activeCategory) {
          document.body.classList.add(`apk-filter--${this.activeCategory}`);
        }
      }

      @action
      setCategory(cat) {
        this.activeCategory = this.activeCategory === cat ? null : cat;
        this._updateBodyClass();
      }

      @action
      clearCategory() {
        this.activeCategory = null;
        this._updateBodyClass();
      }

      <template>
        <div class="sideloaded-category-filter__container">
          <h3 class="sideloaded-category-filter__title">Sideloaded Apps
            Categories</h3>
          <div class="sideloaded-category-filter">
            <button
              type="button"
              class="sideloaded-category-filter__pill
                {{unless this.activeCategory 'active'}}"
              {{on "click" this.clearCategory}}
            >
              {{i18n "sideloaded_apps.categories.all"}}
            </button>
            {{#each this.pills as |pill|}}
              <button
                type="button"
                class="sideloaded-category-filter__pill
                  {{if pill.active 'active'}}"
                {{on "click" (fn this.setCategory pill.key)}}
              >
                {{pill.label}}
              </button>
            {{/each}}
          </div>
        </div>
      </template>
    }
  );

  // ── 3. "NEW REVIEW" BUTTON LABEL ──────────────────
  api.registerValueTransformer("create-topic-label", ({ value }) => {
    const router = api.container.lookup("service:router");
    const category = router.currentRoute?.attributes?.category;

    if (category?.slug === categorySlug) {
      return "sideloaded_apps.new_review";
    }

    return value;
  });

  // ── 4. COMPOSER: Review form for new topics ────────
  api.renderInOutlet(
    "composer-fields",
    class SideloadedComposerOutlet extends Component {
      static shouldRender(args) {
        if (
          args.model?.action === "createTopic" &&
          args.model?.category?.slug === categorySlug
        ) {
          return true;
        }

        if (
          args.model?.action === "reply" &&
          args.model?.topic?.category?.slug === categorySlug
        ) {
          return true;
        }

        return false;
      }

      @tracked isInfoPostMode = false;

      constructor() {
        super(...arguments);
        _composerInfoPostMode = false;
      }

      willDestroy() {
        super.willDestroy?.(...arguments);
        _composerInfoPostMode = false;
      }

      get isNewTopic() {
        return this.args.outletArgs?.model?.action === "createTopic";
      }

      get isStaff() {
        return api.getCurrentUser()?.staff ?? false;
      }

      get isTopicAuthor() {
        const currentUser = api.getCurrentUser();
        const topicUserId =
          this.args.outletArgs?.model?.topic?.user_id ??
          this.args.outletArgs?.model?.topic?.details?.created_by?.id;
        return currentUser && topicUserId && currentUser.id === topicUserId;
      }

      get existingUserRating() {
        const topicId = this.args.outletArgs?.model?.topic?.id;
        if (topicId && _userRatingsCache[topicId]) {
          return _userRatingsCache[topicId];
        }
        return this.args.outletArgs?.model?.topic?.apk_user_rating;
      }

      @action
      toggleInfoPostMode(event) {
        const checked = event?.target?.checked ?? !this.isInfoPostMode;
        this.isInfoPostMode = checked;
        _composerInfoPostMode = checked;
      }

      <template>
        {{#if this.isNewTopic}}
          {{#if this.isStaff}}
            <div class="sideloaded-composer-mode-toggle">
              <label class="sideloaded-composer-mode-toggle__label">
                <input
                  type="checkbox"
                  checked={{this.isInfoPostMode}}
                  {{on "change" this.toggleInfoPostMode}}
                />
                {{i18n "sideloaded_apps.composer.create_info_post"}}
              </label>
            </div>
          {{/if}}
          {{#if this.isInfoPostMode}}
            <div class="sideloaded-composer-info-hint">
              {{i18n "sideloaded_apps.composer.info_post_hint"}}
            </div>
          {{else}}
            <ApkComposerFields @model={{@outletArgs.model}} />
          {{/if}}
        {{else if this.isTopicAuthor}}
          {{! Author already rated when creating the review — no stars in replies }}
        {{else}}
          <ReplyRatingField
            @model={{@outletArgs.model}}
            @existingRating={{this.existingUserRating}}
          />
        {{/if}}
      </template>
    }
  );

  // ── 5. COMPOSER: Validate before save ──────────────
  api.composerBeforeSave(() => {
    const composerService = api.container.lookup("service:composer");
    const model = composerService?.model;

    const modelCategorySlug =
      model?.category?.slug || model?.topic?.category?.slug;
    if (modelCategorySlug !== categorySlug) {
      return Promise.resolve();
    }

    if (model?.action === "createTopic") {
      if (getComposerInfoPostMode()) {
        return Promise.resolve();
      }

      if (!triggerValidateAll()) {
        return Promise.reject();
      }

      const data = getPendingApkData();
      if (!data?.is_direct_download) {
        return Promise.resolve();
      }

      return ajax("/sideloaded-apps/compute-checksum", {
        type: "POST",
        data: {
          url: data.apk_link,
          user_checksum: data.apk_checksum || "",
        },
      })
        .then((result) => {
          if (!result.valid_download) {
            const dialog = api.container.lookup("service:dialog");
            dialog.alert(
              result.reason ||
                i18n("sideloaded_apps.link_validation.not_a_download")
            );
            return Promise.reject();
          }

          if (result.user_checksum_match === false && data.apk_checksum) {
            const dialog = api.container.lookup("service:dialog");
            dialog.alert(
              i18n("sideloaded_apps.link_validation.checksum_mismatch")
            );
            return Promise.reject();
          }

          model.set("metaData", {
            ...(model.metaData || {}),
            apk_checksum: result.checksum,
          });
        })
        .catch((err) => {
          if (err && err.jqXHR) {
            const dialog = api.container.lookup("service:dialog");
            const msg =
              err.jqXHR?.responseJSON?.error ||
              i18n("sideloaded_apps.link_validation.verification_failed");
            dialog.alert(msg);
          }
          return Promise.reject();
        });
    }

    if (model?.action === "reply") {
      const currentUser = api.getCurrentUser();
      const topicUserId =
        model?.topic?.user_id ?? model?.topic?.details?.created_by?.id;
      const isAuthor =
        currentUser && topicUserId && currentUser.id === topicUserId;

      if (!isAuthor) {
        const topicId = model?.topic?.id;
        const existingRating =
          (topicId && _userRatingsCache[topicId]) ||
          model?.topic?.apk_user_rating;
        if (!existingRating) {
          const rating = model.metaData?.apk_rating;
          if (!rating || rating < 1 || rating > 5) {
            const dialog = api.container.lookup("service:dialog");
            dialog.alert(i18n("sideloaded_apps.reply_rating.validation_error"));
            return Promise.reject();
          }
        }
      }
    }

    return Promise.resolve();
  });

  // ── 6. TOPIC VIEW: Review card in first post ───────
  api.renderAfterWrapperOutlet(
    "post-content-cooked-html",
    class SideloadedReviewInPost extends Component {
      static shouldRender(args) {
        return (
          args.post?.post_number === 1 &&
          args.post?.topic?.category?.slug === categorySlug &&
          args.post?.topic?.apk_review
        );
      }

      constructor() {
        super(...arguments);
        document.body.classList.add("sideloaded-apps-topic");
      }

      willDestroy() {
        super.willDestroy(...arguments);
        document.body.classList.remove("sideloaded-apps-topic");
      }

      get currentUser() {
        return api.getCurrentUser();
      }

      get isAuthor() {
        const user = this.currentUser;
        const topicUserId = this.args.outletArgs?.post?.topic?.user_id;
        return user && topicUserId && user.id === topicUserId;
      }

      get userRating() {
        const topicId = this.args.outletArgs?.post?.topic?.id;
        if (topicId && _userRatingsCache[topicId]) {
          return _userRatingsCache[topicId];
        }
        return this.args.outletArgs?.post?.topic?.apk_user_rating;
      }

      @action
      handleRated(rating) {
        const topicId = this.args.outletArgs?.post?.topic?.id;
        if (topicId) {
          _userRatingsCache[topicId] = rating;
        }
      }

      <template>
        <div class="sideloaded-review-outlet">
          <ApkReviewDisplay
            @review={{@outletArgs.post.topic.apk_review}}
            @verification={{@outletArgs.post.topic.apk_verification}}
            @userRating={{this.userRating}}
            @isAuthor={{this.isAuthor}}
            @currentUser={{this.currentUser}}
            @onRated={{this.handleRated}}
          />
        </div>
      </template>
    }
  );

  // ── 7. TOPIC LIST: Simplify columns ────────────────
  api.registerValueTransformer("topic-list-columns", ({ value: columns }) => {
    const router = api.container.lookup("service:router");
    const currentURL = router.currentURL;

    if (!currentURL?.includes(`/c/${categorySlug}`)) {
      return columns;
    }

    columns.delete("views");
    columns.delete("posters");

    return columns;
  });

  // ── 8. TOPIC LIST: Category -> Logo -> Dev badge (before link) ──────────
  api.renderInOutlet(
    "topic-list-before-link",
    class SideloadedAppListBadge extends Component {
      static shouldRender(args) {
        return !!args.topic?.apk_app_name;
      }

      get topic() {
        return this.args.outletArgs?.topic;
      }

      get topicUrl() {
        return this.topic?.url;
      }

      get appCategory() {
        const cat = this.topic?.apk_app_category;
        if (!cat) {
          return null;
        }
        return i18n(`sideloaded_apps.categories.${cat}`);
      }

      get iconUrl() {
        return this.topic?.apk_icon_url;
      }

      get isDeveloper() {
        return !!this.topic?.apk_author_is_developer;
      }

      <template>
        {{! Order: category app -> logo -> dev badge (topic name from core, then rating in after-title) }}
        {{#if this.appCategory}}
          <span class="sideloaded-app-category-badge">
            {{this.appCategory}}
          </span>
        {{/if}}
        {{#if this.isDeveloper}}
          <span class="sideloaded-dev-badge">{{i18n
              "sideloaded_apps.dev_badge"
            }}</span>
        {{/if}}
        {{#if this.iconUrl}}
          <a
            href={{this.topicUrl}}
            class="sideloaded-topic-list-icon-link"
            data-topic-id={{this.topic.id}}
          >
            <img
              src={{this.iconUrl}}
              alt=""
              class="sideloaded-topic-list-icon"
            />
          </a>
        {{/if}}
      </template>
    }
  );

  // ── 8b. TOPIC LIST: Rating (after title) ──────────
  api.renderInOutlet(
    "topic-list-after-title",
    class SideloadedAppListRating extends Component {
      static shouldRender(args) {
        return !!args.topic?.apk_app_name;
      }

      get topic() {
        return this.args.outletArgs?.topic;
      }

      get communityAvg() {
        const avg = this.topic?.apk_community_average;
        if (avg && avg > 0) {
          return Number(avg).toFixed(1);
        }
        return null;
      }

      get communityCount() {
        return this.topic?.apk_community_count || 0;
      }

      get hasRatings() {
        return this.communityCount > 0;
      }

      <template>
        <span
          class="sideloaded-topic-rating
            {{if this.hasRatings 'has-ratings' 'no-ratings'}}"
          title={{i18n "sideloaded_apps.rating.community"}}
        >
          {{#if this.hasRatings}}
            <span class="sideloaded-topic-rating__stars">★</span>
            <span
              class="sideloaded-topic-rating__value"
            >{{this.communityAvg}}</span>
            <span
              class="sideloaded-topic-rating__count"
            >({{this.communityCount}})</span>
          {{else}}
            <span class="sideloaded-topic-rating__stars">☆</span>
            <span class="sideloaded-topic-rating__value">{{i18n
                "sideloaded_apps.rating.no_ratings"
              }}</span>
          {{/if}}
        </span>
      </template>
    }
  );

  // ── 9b. REVIEW QUEUE: Show full review data ─────────
  api.renderInOutlet(
    "after-reviewable-queued-post-body",
    class SideloadedReviewablePreview extends Component {
      static shouldRender(args) {
        return !!args.model?.apk_review_data;
      }

      get data() {
        return this.args.outletArgs?.model?.apk_review_data;
      }

      get categoryLabel() {
        const cat = this.data?.app_category;
        if (!cat) {
          return null;
        }
        return i18n(`sideloaded_apps.categories.${cat}`);
      }

      get stars() {
        const r = this.data?.author_rating || 0;
        return "★".repeat(r) + "☆".repeat(5 - r);
      }

      get hasScreenshots() {
        return this.data?.screenshot_urls?.length > 0;
      }

      <template>
        <div class="sideloaded-reviewable-preview">
          <h4 class="sideloaded-reviewable-preview__title">
            {{i18n "sideloaded_apps.title"}}
          </h4>

          <div class="sideloaded-reviewable-preview__grid">
            <div class="sideloaded-reviewable-preview__item">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.app_name"
                }}</span>
              <span class="sideloaded-reviewable-preview__value">
                {{#if this.data.icon_url}}
                  <img
                    src={{this.data.icon_url}}
                    alt=""
                    class="sideloaded-reviewable-preview__icon"
                  />
                {{/if}}
                {{this.data.app_name}}
                {{#if this.data.author_is_developer}}
                  <span class="sideloaded-dev-badge">{{i18n
                      "sideloaded_apps.dev_badge"
                    }}</span>
                {{/if}}
              </span>
            </div>

            <div class="sideloaded-reviewable-preview__item">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.app_category"
                }}</span>
              <span
                class="sideloaded-reviewable-preview__value"
              >{{this.categoryLabel}}</span>
            </div>

            <div class="sideloaded-reviewable-preview__item">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.apk_version"
                }}</span>
              <span
                class="sideloaded-reviewable-preview__value"
              >{{this.data.apk_version}}</span>
            </div>

            <div class="sideloaded-reviewable-preview__item">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.apk_link"
                }}</span>
              <a
                href={{this.data.apk_link}}
                target="_blank"
                rel="noopener noreferrer"
                class="sideloaded-reviewable-preview__link"
              >{{this.data.apk_link}}</a>
            </div>

            <div class="sideloaded-reviewable-preview__item">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.author_rating"
                }}</span>
              <span
                class="sideloaded-reviewable-preview__stars"
              >{{this.stars}}</span>
            </div>

            {{#if this.data.apk_checksum}}
              <div class="sideloaded-reviewable-preview__item">
                <span class="sideloaded-reviewable-preview__label">{{i18n
                    "sideloaded_apps.form.checksum"
                  }}</span>
                <code
                  class="sideloaded-reviewable-preview__checksum"
                >{{this.data.apk_checksum}}</code>
              </div>
            {{/if}}
          </div>

          {{#if this.data.app_description}}
            <div class="sideloaded-reviewable-preview__section">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.description"
                }}</span>
              <p
                class="sideloaded-reviewable-preview__text"
              >{{this.data.app_description}}</p>
            </div>
          {{/if}}

          {{#if this.data.known_issues}}
            <div class="sideloaded-reviewable-preview__section">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.known_issues"
                }}</span>
              <p
                class="sideloaded-reviewable-preview__text"
              >{{this.data.known_issues}}</p>
            </div>
          {{/if}}

          {{#if this.hasScreenshots}}
            <div class="sideloaded-reviewable-preview__section">
              <span class="sideloaded-reviewable-preview__label">{{i18n
                  "sideloaded_apps.form.screenshots"
                }}</span>
              <div class="sideloaded-reviewable-preview__screenshots">
                {{#each this.data.screenshot_urls as |url|}}
                  <img
                    src={{url}}
                    alt="Screenshot"
                    class="sideloaded-reviewable-preview__screenshot"
                    loading="lazy"
                  />
                {{/each}}
              </div>
            </div>
          {{/if}}
        </div>
      </template>
    }
  );

  // ── 9. BODY CLASS for category ─────────────────────
  api.onPageChange((url) => {
    if (url.includes(`/c/${categorySlug}`)) {
      document.body.classList.add("sideloaded-apps-category");
    } else {
      document.body.classList.remove("sideloaded-apps-category");
    }

    if (url.includes("/t/")) {
      clearPendingApkData();
    }
  });
});

// ── Reply Rating Field (inline component) ────────────
class ReplyRatingField extends Component {
  @tracked rating = 0;
  @tracked _justRated = false;

  constructor() {
    super(...arguments);
    document.body.classList.add("sideloaded-reply-composer");
  }

  willDestroy() {
    super.willDestroy(...arguments);
    document.body.classList.remove("sideloaded-reply-composer");
  }

  get hasExistingRating() {
    return !!this.args.existingRating || this._justRated;
  }

  get displayRating() {
    if (this.args.existingRating) {
      return this.args.existingRating;
    }
    return this.rating;
  }

  @action
  setRating(value) {
    if (this.args.existingRating || this._justRated) {
      return;
    }
    this.rating = value;
    this._justRated = true;
    const model = this.args.model;
    if (model) {
      model.set("metaData", {
        ...(model.metaData || {}),
        apk_rating: value,
      });

      const topicId = model.topic?.id;
      if (topicId) {
        _userRatingsCache[topicId] = value;
      }
    }
  }

  <template>
    <div class="sideloaded-reply-rating">
      {{#if this.hasExistingRating}}
        <label class="sideloaded-reply-rating__label">
          {{i18n "sideloaded_apps.reply_rating.your_rating"}}
        </label>
        <ApkStarRating @rating={{this.displayRating}} @interactive={{false}} />
        <span class="sideloaded-reply-rating__help">
          {{i18n "sideloaded_apps.reply_rating.already_rated"}}
        </span>
      {{else}}
        <label class="sideloaded-reply-rating__label">
          {{i18n "sideloaded_apps.reply_rating.title"}}
        </label>
        <ApkStarRating
          @rating={{this.displayRating}}
          @interactive={{true}}
          @onRate={{this.setRating}}
        />
        <span class="sideloaded-reply-rating__help">
          {{i18n "sideloaded_apps.reply_rating.help"}}
        </span>
      {{/if}}
    </div>
  </template>
}
