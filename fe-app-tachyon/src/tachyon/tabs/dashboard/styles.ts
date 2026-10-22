// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `
@font-face {
    font-family: "Twemoji Country Flags";
    src: url("/luci-static/resources/view/tachyon/fonts/TwemojiCountryFlags.woff2") format("woff2");
    font-display: swap;
    font-style: normal;
    font-weight: normal;
    unicode-range: U+1F1E6-1F1FF, U+1F3F4, U+E0062-E0063, U+E0065, U+E0067, U+E006C, U+E006E, U+E0073-E0074, U+E0077, U+E007F;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node {
    display: block;
    width: 100%;
    max-width: none;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-field,
#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-field > output,
#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-field > div,
#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > div,
#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > output {
    display: block;
    margin-left: 0;
    width: 100%;
    max-width: none;
    flex: 1 1 100%;
    box-sizing: border-box;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard > h3 {
    display: none;
}

.tachyon_dashboard-page {
    display: block;
    width: 100%;
    box-sizing: border-box;
    --dashboard-grid-columns: 4;
    --dashboard-grid-min-width: 180px;
}

.tachyon_dashboard-page__service-stopped {
    display: none;
    width: 100%;
    min-height: 180px;
    margin-top: 10px;
    align-items: center;
    justify-content: center;
    padding: 20px;
    box-sizing: border-box;
    border: 1px dashed var(--border-color-high, #555);
    border-radius: 6px;
    color: var(--text-color-medium, #888);
    background: transparent;
    font-family: inherit;
    font-size: inherit;
    font-weight: inherit;
    line-height: inherit;
    font-style: italic;
    text-align: center;
}

.tachyon_dashboard-page--service-stopped {
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(var(--dashboard-grid-min-width), 1fr));
    gap: 10px;
}

.tachyon_dashboard-page--service-stopped .tachyon_dashboard-page__service-stopped {
    display: flex;
    grid-column: 1 / -1;
}

.tachyon_dashboard-page--service-stopped .tachyon_dashboard-page__content {
    display: none;
}

@media (max-width: 900px) {
    .tachyon_dashboard-page {
        --dashboard-grid-columns: 2;
    }
}

@media (max-width: 560px) {
    .tachyon_dashboard-page {
        --dashboard-grid-columns: 1;
        --dashboard-grid-min-width: 0;
    }
}

.tachyon_dashboard-page__widgets-section {
    margin-top: 10px;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 420px), 1fr));
    grid-gap: 12px;
}

.tachyon-dual-card {
    min-height: 140px;
}

.tachyon-dual-card__header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
    padding-bottom: 5px;
    border-bottom: 1px solid rgba(128, 128, 128, 0.15);
}

.tachyon-dual-card__title-text {
    font-size: 13px;
    font-weight: 700;
    color: var(--text-color-high, inherit);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-dual-card__badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 10px;
    font-size: 11px;
    font-weight: 600;
    background: rgba(16, 185, 129, 0.12);
    color: #10b981;
    border: 1px solid rgba(16, 185, 129, 0.28);
    flex-shrink: 0;
}

.tachyon-dual-card__badge--neutral {
    background: rgba(120, 120, 120, 0.12);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(120, 120, 120, 0.25);
}

.tachyon-dual-card__body {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    align-items: start;
    min-width: 0;
}

.tachyon-dual-card__col {
    min-width: 0;
    display: flex;
    flex-direction: column;
}

.tachyon-dual-card__col:first-child {
    padding-right: 12px;
    border-right: 1px solid rgba(128, 128, 128, 0.12);
}

.tachyon-dual-card__column-title {
    font-size: 10.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    color: var(--text-color-medium, #94a3b8);
    margin-bottom: 5px;
    padding-bottom: 3px;
    border-bottom: 1px dashed rgba(128, 128, 128, 0.2);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

@media (max-width: 768px) {
    .tachyon-dual-card__body {
        grid-template-columns: 1fr;
        gap: 12px;
    }
    .tachyon-dual-card__col:first-child {
        padding-right: 0;
        border-right: none;
        padding-bottom: 10px;
        border-bottom: 1px solid rgba(128, 128, 128, 0.12);
    }
}

.tachyon_dashboard-page__widgets-section__item {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 6px;
    padding: 12px;
    min-width: 0;
    background: rgba(128, 128, 128, 0.03);
    display: flex;
    flex-direction: column;
}

.tachyon_dashboard-page__widgets-section__item__title {
    font-size: 13px;
    font-weight: 700;
    color: var(--text-color-high, inherit);
    margin-bottom: 6px;
    display: block;
    border-bottom: 1px solid rgba(128, 128, 128, 0.15);
    padding-bottom: 4px;
}

.tachyon_dashboard-page__widgets-section__item__row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    line-height: 1.5;
    margin-top: 3px;
    min-width: 0;
}

.tachyon_dashboard-page__widgets-section__item__row--success .tachyon_dashboard-page__widgets-section__item__row__value {
    color: var(--success-color-medium, green);
}

.tachyon_dashboard-page__widgets-section__item__row--error .tachyon_dashboard-page__widgets-section__item__row__value {
    color: var(--error-color-medium, red);
}

.tachyon_dashboard-page__widgets-section__item__row__key {
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon_dashboard-page__widgets-section__item__row__value {
    text-align: right;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-variant-numeric: tabular-nums;
}

.tachyon-stat--down {
    color: #10b981 !important;
    font-weight: 600;
}

.tachyon-stat--up {
    color: #3b82f6 !important;
    font-weight: 600;
}

.tachyon-stat--session {
    font-size: 12px;
    opacity: 0.85;
}

.tachyon-stat--bold {
    font-weight: 700;
    color: var(--text-color-high, inherit);
}

.tachyon_dashboard-page__top-domains-container {
    margin-top: 10px;
    padding-top: 10px;
    border-top: 1px solid rgba(128, 128, 128, 0.15);
}

.tachyon_dashboard-page__top-domains-header {
    font-size: 12px;
    font-weight: 600;
    opacity: 0.75;
    margin-bottom: 6px;
}

.tachyon_dashboard-page__top-domains-list {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon_dashboard-page__top-domain-chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    background: rgba(128, 128, 128, 0.12);
    border-radius: 6px;
    padding: 3px 8px;
    font-size: 12px;
    color: var(--text-color-high);
}

.tachyon_dashboard-page__top-domain-chip__icon {
    font-size: 11px;
    opacity: 0.8;
}

.tachyon_dashboard-page__top-domain-chip__badge {
    font-size: 11px;
    opacity: 0.7;
    background: rgba(0, 0, 0, 0.15);
    padding: 1px 4px;
    border-radius: 4px;
}

.tachyon_dashboard-page__outbound-section {
    margin-top: 10px;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    width: 100%;
    box-sizing: border-box;
}

/* The runtime quarantined this section: sing-box refused the config it
   produced, so the section is not loaded while everything else runs. */
.tachyon_dashboard-page__outbound-section--error {
    border-color: var(--error-color-medium, red);
}

.tachyon_dashboard-page__outbound-section__config-error-badge {
    flex-shrink: 0;
    padding: 1px 6px;
    border-radius: 4px;
    background: var(--error-color-medium, red);
    color: #fff;
    font-size: 11px;
    font-weight: 700;
    cursor: help;
}

.tachyon_dashboard-page__outbound-section__title-section {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px 10px;
    min-width: 0;
}

.tachyon_dashboard-page__outbound-section__title-section__title {
    color: var(--text-color-high);
    font-weight: 700;
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__outbound-section__title-section__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    flex: 0 1 auto;
    flex-wrap: wrap;
}

.tachyon_dashboard-page .btn.tachyon_dashboard-page__outbound-section__subscription-update {
    min-width: 0;
    width: auto;
    min-height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
}

.tachyon_dashboard-page__outbound-section__subscription-update svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_dashboard-page__outbound-section__subscription-update[disabled] {
    cursor: not-allowed;
    opacity: 0.65;
}

.tachyon_dashboard-page .btn.dashboard-sections-grid-item-test-latency {
    min-width: 0;
    width: auto;
    min-height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
}

.tachyon_dashboard-page .btn.dashboard-sections-grid-item-test-latency svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_dashboard-page .btn.dashboard-sections-grid-item-test-latency[disabled] {
    cursor: not-allowed;
    opacity: 0.65;
}

.tachyon_dashboard-page__sections-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 16px;
    margin-bottom: 4px;
    padding: 0 2px;
    gap: 12px;
    min-width: 0;
}

.tachyon_dashboard-page__sections-header__title {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text-color-high);
    font-size: 15px;
    font-weight: 700;
    letter-spacing: 0.2px;
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__sections-header__title svg {
    flex-shrink: 0;
    opacity: 0.85;
}

.tachyon_dashboard-page__sections-header__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    flex-shrink: 0;
}

.tachyon_dashboard-page .btn#dashboard-test-all-sections-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    white-space: nowrap;
    vertical-align: middle;
    padding: 4px 14px;
    height: 30px;
    min-height: 28px;
    font-size: 13px;
}

#dashboard-test-all-sections-button svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 15px;
}

#dashboard-test-all-sections-button[disabled] {
    cursor: not-allowed;
    opacity: 0.65;
}

@media (max-width: 480px) {
    .tachyon_dashboard-page__sections-header {
        flex-wrap: wrap;
        gap: 8px;
    }
}

.tachyon_dashboard-page__outbound-grid {
    margin-top: 5px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(var(--dashboard-grid-min-width), 1fr));
    grid-gap: 10px;
}

.tachyon_dashboard-page__subscription-meta {
    --subscription-meta-action-size: 28px;
    --subscription-meta-action-gap: 6px;
    grid-column: 1 / -1;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 8px 10px;
    background: var(--background-color-high, transparent);
}

.tachyon_dashboard-page__subscription-meta--collapsible {
    cursor: pointer;
    user-select: none;
    transition: border-color 0.2s ease, background-color 0.2s ease;
}

.tachyon_dashboard-page__subscription-meta--collapsible:hover {
    border-color: var(--primary-color-high, dodgerblue);
}

.tachyon_dashboard-page__source-group--manual {
    border-style: dashed;
}

.tachyon_dashboard-page__source-group__count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 1px 6px;
    border-radius: 10px;
    font-size: 11px;
    font-weight: 600;
    background: rgba(128, 128, 128, 0.18);
    color: var(--text-color-medium, #888);
    flex-shrink: 0;
}

.tachyon_dashboard-page__source-group__active-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 1px 7px;
    border-radius: 4px;
    font-size: 12px;
    font-weight: 600;
    color: var(--success-color-medium, #4caf50);
    background: rgba(76, 175, 80, 0.14);
    border: 1px solid rgba(76, 175, 80, 0.3);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 240px;
}

.tachyon_dashboard-page__subscription-meta__main {
    display: flex;
    align-items: center;
    gap: 6px 10px;
    min-width: 0;
}

.tachyon_dashboard-page__subscription-meta__heading {
    flex: 0 0 auto;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    white-space: nowrap;
}

.tachyon_dashboard-page__subscription-meta__title {
    flex: 0 1 auto;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    word-break: break-word;
}

.tachyon_dashboard-page__subscription-meta__facts {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 5px 12px;
}

.tachyon_dashboard-page__subscription-meta__fact {
    display: flex;
    align-items: baseline;
    gap: 4px;
    min-width: 0;
    line-height: 1.25;
}

.tachyon_dashboard-page__subscription-meta__fact-key {
    color: var(--text-color-medium);
    font-size: 12px;
    white-space: nowrap;
}

.tachyon_dashboard-page__subscription-meta__fact-value {
    color: var(--text-color-high);
    font-weight: 600;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__subscription-meta__actions {
    flex: 0 0 auto;
    margin-left: auto;
    display: flex;
    justify-content: flex-end;
    gap: var(--subscription-meta-action-gap);
}

.tachyon_dashboard-page .btn.tachyon_dashboard-page__subscription-meta__action {
    width: var(--subscription-meta-action-size);
    height: var(--subscription-meta-action-size);
    min-width: var(--subscription-meta-action-size);
    min-height: var(--subscription-meta-action-size);
    padding: 2px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
}

.tachyon_dashboard-page__subscription-meta__action svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_dashboard-page__subscription-meta__announce {
    margin: 6px 0 0;
    border-left: 3px solid var(--primary-color-medium, dodgerblue);
    padding: 4px 8px;
    background: var(--background-color-low, rgba(0, 0, 0, 0.04));
    color: var(--text-color-medium);
    font-style: italic;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

@media (max-width: 700px) {
    .tachyon_dashboard-page__subscription-meta__main {
        align-items: flex-start;
        flex-wrap: wrap;
    }

    .tachyon_dashboard-page__subscription-meta__heading,
    .tachyon_dashboard-page__subscription-meta__title {
        order: 1;
    }

    .tachyon_dashboard-page__subscription-meta__actions {
        order: 2;
    }

    .tachyon_dashboard-page__subscription-meta__facts {
        order: 3;
        flex-basis: 100%;
    }

    .tachyon_dashboard-page__subscription-meta__title {
        max-width: calc(100% - 42px);
    }
}

.tachyon_dashboard-page__outbound-grid__item {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    transition: border 0.2s ease;
    min-width: 0;
    position: relative;
}

.tachyon_dashboard-page__outbound-grid__item--selectable {
    cursor: pointer;
}

.tachyon_dashboard-page__outbound-grid__item--selectable:hover {
    border-color: var(--primary-color-high, dodgerblue);
}

.tachyon_dashboard-page__outbound-grid__item--active {
    border-color: #10b981 !important;
    box-shadow: 0 0 0 1.5px #10b981, 0 3px 12px rgba(16, 185, 129, 0.25) !important;
}

.tachyon_dashboard-page__outbound-grid__item--active:hover {
    border-color: #10b981 !important;
    box-shadow: 0 0 0 2px #10b981, 0 4px 14px rgba(16, 185, 129, 0.35) !important;
}

.tachyon_dashboard-page__outbound-grid__item--disabled {
    cursor: default;
}

.tachyon_dashboard-page__outbound-grid__item--switching {
    border-color: transparent !important;
    overflow: hidden;
    cursor: wait;
}

.tachyon_dashboard-page__outbound-grid__item__snake {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
    z-index: 9999;
    box-sizing: border-box;
}

.tachyon_dashboard-page__outbound-grid__item__snake rect {
    stroke: var(--primary-color-high, dodgerblue);
    stroke-width: 4;
    animation: tachyon-dashboard-selector-snake-svg 1.2s linear infinite;
}

@keyframes tachyon-dashboard-selector-snake-svg {
    0% {
        stroke-dasharray: 30 70;
        stroke-dashoffset: 100;
    }
    100% {
        stroke-dasharray: 30 70;
        stroke-dashoffset: 0;
    }
}

.tachyon_dashboard-page__outbound-grid__item__header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
}

.tachyon_dashboard-page__outbound-grid__item__title-wrapper {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    min-width: 0;
    flex: 1 1 auto;
}

.tachyon_dashboard-page__outbound-grid__item__header b {
    min-width: 0;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__outbound-grid__item__prefix-badge {
    display: inline-flex;
    align-items: center;
    font-size: 11px;
    font-weight: 500;
    line-height: 1.3;
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.2);
    color: var(--text-color-medium, #999);
    max-width: 100%;
    overflow-wrap: anywhere;
    word-break: break-word;
}

.tachyon_dashboard-page__outbound-grid__item__selected-badge {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
    padding: 2px 7px;
    border-radius: 10px;
    background: #10b981;
    color: #ffffff;
    letter-spacing: 0.3px;
    box-shadow: 0 1px 4px rgba(16, 185, 129, 0.35);
    white-space: nowrap;
}

.tachyon_proto-popover-trigger {
    position: relative;
    cursor: help;
}

.tachyon_proto-popover {
    display: none;
    position: absolute;
    left: 0;
    bottom: calc(100% + 6px);
    z-index: 10050;
    min-width: 220px;
    max-width: 310px;
    padding: 8px 10px;
    border-radius: 6px;
    background: rgba(20, 24, 33, 0.97);
    color: #f1f5f9;
    border: 1px solid rgba(255, 255, 255, 0.16);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
    font-size: 11.5px;
    line-height: 1.4;
    text-align: left;
    pointer-events: none;
    white-space: normal;
}

.tachyon_proto-popover-trigger:hover .tachyon_proto-popover {
    display: block;
}

.tachyon_proto-popover__header {
    font-weight: 700;
    font-size: 12px;
    color: #60a5fa;
    border-bottom: 1px solid rgba(255, 255, 255, 0.12);
    padding-bottom: 4px;
    margin-bottom: 5px;
    word-break: break-word;
}

.tachyon_proto-popover__row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 10px;
    padding: 1.5px 0;
}

.tachyon_proto-popover__label {
    color: #94a3b8;
    font-weight: 500;
    flex: 0 0 auto;
}

.tachyon_proto-popover__val {
    color: #f8fafc;
    font-family: monospace;
    font-weight: 600;
    text-align: right;
    word-break: break-all;
}

.tachyon_dashboard-page .btn.tachyon_dashboard-page__outbound-grid__item__copy-button {
    width: 22px;
    height: 22px;
    min-width: 22px;
    min-height: 22px;
    padding: 1px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
}

.tachyon_dashboard-page__outbound-grid__item__copy-button svg {
    width: 13px;
    height: 13px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_dashboard-page__outbound-grid__item__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: 10px;
    min-width: 0;
}

.tachyon_dashboard-page__outbound-grid__item__type {
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__outbound-grid__item__latency--empty {
    color: var(--primary-color-low, lightgray);
}

.tachyon_dashboard-page__outbound-grid__item__latency--green {
    color: var(--success-color-medium, green);
}

.tachyon_dashboard-page__outbound-grid__item__latency--yellow {
    color: var(--warn-color-medium, orange);
}

.tachyon_dashboard-page__outbound-grid__item__latency--red {
    color: var(--error-color-medium, red);
}

.tachyon_dashboard-page__outbound-grid__item__latency--clickable {
    cursor: pointer;
    user-select: none;
    transition: opacity 0.15s ease, background-color 0.15s ease;
    border-radius: 4px;
    padding: 1px 4px;
}

.tachyon_dashboard-page__outbound-grid__item__latency--clickable:hover {
    opacity: 0.8;
    background: rgba(128, 128, 128, 0.15);
}

.tachyon_dashboard-page__outbound-grid__item__latency--testing {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    opacity: 0.8;
}

.tachyon_dashboard-page__outbound-grid__item__latency--testing svg {
    width: 12px;
    height: 12px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_dashboard-page__urltest-details {
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    padding-top: 10px;
}

.tachyon_dashboard-page__urltest-details__params {
    display: grid;
    grid-template-columns: minmax(120px, max-content) minmax(0, 1fr);
    gap: 8px 16px;
    margin: 0 0 18px;
}

.tachyon_dashboard-page__urltest-details__param {
    display: contents;
}

.tachyon_dashboard-page__urltest-details__param dt {
    color: var(--text-color-medium, #666);
    line-height: 1.35;
}

.tachyon_dashboard-page__urltest-details__param dd {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    margin: 0;
}

.tachyon_dashboard-page__urltest-details__param dd span {
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__urltest-details__url {
    min-width: 0;
    color: var(--primary-color-high, #337ab7);
    text-decoration: none;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__urltest-details__url:hover {
    text-decoration: underline;
}

.tachyon_dashboard-page__urltest-details__selected-value {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    max-width: 100%;
    padding: 0;
    border: 0;
    color: inherit;
    background: transparent;
    box-sizing: border-box;
    line-height: 1.3;
}

.tachyon_dashboard-page__urltest-details__selected-name {
    min-width: 0;
    font-weight: 600;
    overflow-wrap: anywhere;
}

.tachyon_dashboard-page__urltest-details__selected-type {
    color: var(--text-color-medium, #666);
}

.tachyon_dashboard-page__urltest-details__outbounds-title {
    margin-bottom: 8px;
    font-weight: 600;
}

.tachyon_dashboard-page__urltest-details__table {
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 100%;
    box-sizing: border-box;
    max-height: min(48vh, 480px);
    overflow-x: hidden;
    overflow-y: auto;
    padding-right: 4px;
}

.tachyon_dashboard-page__urltest-details__row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    width: 100%;
    min-width: 0;
    padding: 8px 10px;
    box-sizing: border-box;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.15));
    border-radius: 6px;
    background: var(--background-color-card, rgba(128, 128, 128, 0.04));
    transition: background 0.15s ease, border-color 0.15s ease;
}

.tachyon_dashboard-page__urltest-details__row:hover {
    background: rgba(128, 128, 128, 0.08);
}

.tachyon_dashboard-page__urltest-details__row--active {
    border-color: #4caf50;
    background: rgba(76, 175, 80, 0.08);
}

.tachyon_dashboard-page__urltest-details__row-name {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    flex: 1 1 auto;
    overflow: hidden;
}

.tachyon_dashboard-page__urltest-details__row-name b {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 13px;
    line-height: 1.3;
}

.tachyon_dashboard-page__urltest-details__priority-name {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_dashboard-page__urltest-details__priority-number {
    margin-right: 4px;
    color: var(--text-color-medium, #aaa);
    font-family: monospace;
    font-size: 12px;
    font-weight: 600;
}

.tachyon_dashboard-page__urltest-details__priority-level {
    padding: 1px 6px;
    border-radius: 4px;
    color: var(--text-color-medium, #aaa);
    background: rgba(128, 128, 128, 0.15);
    font-size: 11px;
    font-weight: 400;
    white-space: nowrap;
}

.tachyon_dashboard-page__urltest-details__country-badge {
    display: inline-flex;
    align-items: center;
    user-select: none;
    padding: 2px 4px;
    border: 1px solid rgba(128, 128, 128, 0.25);
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    line-height: 1;
    flex-shrink: 0;
}

.tachyon_dashboard-page__flag-emoji,
.tachyon_dashboard-page__country-chip__flag,
.tachyon_dashboard-page__urltest-details__country-badge {
    font-family: "Twemoji Country Flags", "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif;
    font-style: normal;
    font-weight: normal;
}

.tachyon_dashboard-page__urltest-details__priority-node {
    color: var(--text-color-high, #fff);
    font-weight: 600;
}

.tachyon_dashboard-page__urltest-details__row-type {
    font-size: 11px;
    color: var(--text-color-medium, #888);
    background: rgba(128, 128, 128, 0.12);
    padding: 1px 6px;
    border-radius: 4px;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon_dashboard-page__urltest-details__row-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
}

.tachyon_dashboard-page__urltest-details__row-meta {
    display: flex;
    align-items: center;
    white-space: nowrap;
    min-width: 48px;
    justify-content: flex-end;
    font-weight: 500;
    font-size: 12px;
}

.tachyon_dashboard-page__urltest-details__select-btn {
    padding: 2px 10px !important;
    font-size: 12px !important;
    height: 26px !important;
    line-height: 20px !important;
    white-space: nowrap !important;
    border-radius: 4px !important;
    cursor: pointer;
}

.tachyon_dashboard-page__urltest-details__active-badge {
    display: inline-flex !important;
    align-items: center !important;
    gap: 4px !important;
    padding: 3px 8px !important;
    font-size: 11px !important;
    font-weight: 600 !important;
    color: #4caf50 !important;
    background: rgba(76, 175, 80, 0.15) !important;
    border: 1px solid rgba(76, 175, 80, 0.3) !important;
    border-radius: 4px !important;
    white-space: nowrap !important;
}

.tachyon_dashboard-page__urltest-details__copy-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 24px;
    width: 24px;
    min-width: 24px;
    height: 24px;
    padding: 0;
    box-sizing: border-box;
    border-radius: 4px;
    opacity: 0.7;
    transition: opacity 0.15s ease;
}

.tachyon_dashboard-page__urltest-details__copy-button:hover {
    opacity: 1;
}

.tachyon_dashboard-page__urltest-details__copy-button svg {
    width: 14px;
    height: 14px;
}

.tachyon_dashboard-page__urltest-details__copy-placeholder {
    display: block;
    width: 24px;
    min-width: 24px;
    height: 1px;
}

.tachyon_dashboard-page__urltest-details__empty {
    margin-top: 4px;
    padding: 24px 0;
    border: 1px dashed var(--border-color-high, #555);
    border-radius: 4px;
    color: var(--text-color-medium, #888);
    background: rgba(128, 128, 128, 0.02);
    font-style: italic;
    text-align: center;
}

.tachyon_dashboard-page__urltest-details__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-top: 16px;
    padding-top: 12px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
}

@media (max-width: 560px) {
    .tachyon_dashboard-page__urltest-details__params {
        grid-template-columns: 1fr;
    }

    .tachyon_dashboard-page__urltest-details__row {
        flex-wrap: wrap;
        gap: 6px;
    }

    .tachyon_dashboard-page__urltest-details__row-actions {
        width: 100%;
        justify-content: flex-end;
    }
}

.tachyon_dashboard-page__country-chips-container {
    grid-column: 1 / -1;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 2px 0 6px 0;
}

.tachyon_dashboard-page__region-bar {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    align-items: center;
}

.tachyon_dashboard-page__region-tab {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 8px;
    font-size: 11px;
    font-weight: 600;
    line-height: 1.2;
    border-radius: 6px;
    border: 1px solid var(--border-color-medium, rgba(120, 120, 120, 0.28));
    background: var(--background-color-medium, rgba(120, 120, 120, 0.06));
    color: var(--text-color-medium, inherit);
    cursor: pointer;
    transition: all 0.15s ease;
    user-select: none;
    box-sizing: border-box;
}

.tachyon_dashboard-page__region-tab:hover {
    background: var(--background-color-high, rgba(120, 120, 120, 0.16));
    border-color: var(--border-color-high, rgba(120, 120, 120, 0.45));
}

.tachyon_dashboard-page__region-tab--active {
    background: var(--primary-color-low, rgba(37, 99, 235, 0.16)) !important;
    border-color: var(--primary-color, #2563eb) !important;
    color: var(--primary-color, #2563eb) !important;
    font-weight: 700;
}

.tachyon_dashboard-page__region-tab__name {
    font-weight: 600;
    font-size: 11px;
}

.tachyon_dashboard-page__country-chip-divider {
    width: 2px;
    height: 18px;
    background: var(--border-color-high, rgba(120, 120, 120, 0.4));
    margin: 0 3px;
    border-radius: 1px;
    flex-shrink: 0;
}

.tachyon_dashboard-page__country-chips {
    grid-column: 1 / -1;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    align-items: center;
    padding: 2px 0 2px 0;
}

.tachyon_dashboard-page__country-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    font-size: 12px;
    font-weight: 500;
    line-height: 1.2;
    border-radius: 16px;
    border: 1px solid var(--border-color-medium, rgba(120, 120, 120, 0.35));
    background: var(--background-color-medium, rgba(120, 120, 120, 0.08));
    color: var(--text-color-high, inherit);
    cursor: pointer;
    transition: all 0.15s ease;
    user-select: none;
    box-sizing: border-box;
}

.tachyon_dashboard-page__country-chip:hover {
    background: var(--background-color-high, rgba(120, 120, 120, 0.22));
    border-color: var(--border-color-high, rgba(120, 120, 120, 0.6));
}

.tachyon_dashboard-page__country-chip--active {
    background: var(--primary-color, #2563eb) !important;
    color: #ffffff !important;
    border-color: var(--primary-color, #2563eb) !important;
    box-shadow: 0 2px 6px rgba(37, 99, 235, 0.35);
}

.tachyon_dashboard-page__country-chip--active:hover {
    background: var(--primary-color-hover, #1d4ed8) !important;
    border-color: var(--primary-color-hover, #1d4ed8) !important;
}

.tachyon_dashboard-page__country-chip__flag {
    font-size: 16px;
    line-height: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

.tachyon_dashboard-page__country-chip__name {
    font-weight: 600;
    font-size: 12px;
    line-height: 1.2;
}

.tachyon_dashboard-page__country-chip__count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
    padding: 2px 6px;
    border-radius: 10px;
    background: rgba(128, 128, 128, 0.22);
    color: var(--text-color-high, currentColor);
    min-width: 16px;
    text-align: center;
}

.tachyon_dashboard-page__country-chip--active .tachyon_dashboard-page__country-chip__count {
    background: rgba(255, 255, 255, 0.28);
    color: #ffffff;
}

.tachyon_dashboard-page__country-chip__latency {
    display: inline-flex;
    align-items: center;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
    padding: 2px 6px;
    border-radius: 10px;
}

.tachyon_dashboard-page__country-chip__latency--fast {
    background: rgba(16, 185, 129, 0.18);
    color: #10b981;
}

.tachyon_dashboard-page__country-chip__latency--medium {
    background: rgba(245, 158, 11, 0.2);
    color: #f59e0b;
}

.tachyon_dashboard-page__country-chip__latency--slow {
    background: rgba(239, 68, 68, 0.2);
    color: #ef4444;
}

.tachyon_dashboard-page__country-chip--active .tachyon_dashboard-page__country-chip__latency {
    background: rgba(255, 255, 255, 0.28) !important;
    color: #ffffff !important;
}

.tachyon_dashboard-page__country-meta {
    margin-top: 6px;
    margin-bottom: 2px;
}

.tachyon_dashboard-page__auto-groups {
    grid-column: 1 / -1;
    width: 100%;
    margin-bottom: 8px;
    padding: 10px 12px 12px 12px;
    border-radius: 6px;
    background: rgba(120, 120, 120, 0.05);
    border: 1px dashed var(--border-color-medium, rgba(120, 120, 120, 0.25));
    box-sizing: border-box;
}

.tachyon_dashboard-page__auto-groups__header {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.5px;
    text-transform: uppercase;
    color: var(--text-color-medium, rgba(160, 160, 160, 0.9));
    margin-bottom: 10px;
    padding-left: 2px;
}

.tachyon_dashboard-page__auto-groups__icon {
    display: inline-flex;
    align-items: center;
    font-size: 13px;
    color: #f59e0b;
}

.tachyon_dashboard-page__auto-groups__count {
    font-size: 11px;
    padding: 0 5px;
    border-radius: 8px;
    background: rgba(120, 120, 120, 0.18);
    color: var(--text-color-high, inherit);
    font-weight: 600;
}

.tachyon_dashboard-page__auto-groups-grid {
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(var(--dashboard-grid-min-width), 1fr));
    grid-gap: 10px;
}

.tachyon_dashboard-page__outbound-grid__item--auto-group {
    background: var(--background-color-medium, rgba(120, 120, 120, 0.08));
    border-color: var(--border-color-medium, rgba(120, 120, 120, 0.35));
}

.tachyon_dashboard-page__outbound-grid__item--auto-group.tachyon_dashboard-page__outbound-grid__item--active {
    border-color: #10b981 !important;
    background: rgba(16, 185, 129, 0.08) !important;
    box-shadow: 0 0 0 1.5px #10b981, 0 3px 12px rgba(16, 185, 129, 0.25) !important;
}

.tachyon-service-key {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-weight: 600;
    font-size: 12px;
    min-width: 0;
}

.tachyon-service-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
    display: inline-block;
}

.tachyon-service-dot--online {
    background: #10b981;
    box-shadow: 0 0 6px rgba(16, 185, 129, 0.7);
}

.tachyon-service-dot--offline {
    background: #ef4444;
    box-shadow: 0 0 5px rgba(239, 68, 68, 0.5);
}

.tachyon-service-name {
    color: var(--text-color-high, inherit);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-service-value {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
    justify-content: flex-end;
}

.tachyon-service-pill {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 1px 6px;
    border-radius: 10px;
    font-size: 11px;
    font-weight: 600;
    line-height: 1.35;
    font-variant-numeric: tabular-nums;
    box-sizing: border-box;
    white-space: nowrap;
    text-align: center;
}

.tachyon-service-pill--ram {
    background: rgba(16, 185, 129, 0.12);
    color: #10b981;
    border: 1px solid rgba(16, 185, 129, 0.28);
    width: 58px;
    min-width: 58px;
}

.tachyon-service-pill--uptime {
    background: rgba(120, 120, 120, 0.12);
    color: var(--text-color-medium, #94a3b8);
    font-weight: 500;
    width: 68px;
    min-width: 68px;
}

.tachyon-service-pill--version {
    background: rgba(120, 120, 120, 0.12);
    color: var(--text-color-medium, #94a3b8);
    font-weight: 500;
    padding: 1px 7px;
}

.tachyon-service-pill--active {
    background: rgba(16, 185, 129, 0.12);
    color: #10b981;
    border: 1px solid rgba(16, 185, 129, 0.28);
    padding: 1px 8px;
}

.tachyon-service-pill--stopped {
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
    border: 1px solid rgba(239, 68, 68, 0.28);
    padding: 1px 9px;
    width: auto;
}

.tachyon-service-pill--empty {
    opacity: 0.35;
    background: transparent !important;
    border-color: transparent !important;
}

`;
