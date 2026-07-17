// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-field {
    margin-left: 0;
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard-_mount_node > div {
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-dashboard > h3 {
    display: none;
}

.tachyon_dashboard-page {
    width: 100%;
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
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(var(--dashboard-grid-min-width), 1fr));
    grid-gap: 10px;
}

.tachyon_dashboard-page__widgets-section__item {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    min-width: 0;
}

.tachyon_dashboard-page__widgets-section__item__title {}

.tachyon_dashboard-page__widgets-section__item__row {}

.tachyon_dashboard-page__widgets-section__item__row--success .tachyon_dashboard-page__widgets-section__item__row__value {
    color: var(--success-color-medium, green);
}

.tachyon_dashboard-page__widgets-section__item__row--error .tachyon_dashboard-page__widgets-section__item__row__value {
    color: var(--error-color-medium, red);
}

.tachyon_dashboard-page__widgets-section__item__row__key {}

.tachyon_dashboard-page__widgets-section__item__row__value {}

.tachyon_dashboard-page__outbound-section {
    margin-top: 10px;
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
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
    flex: 0 0 auto;
}

.tachyon_dashboard-page .btn.tachyon_dashboard-page__outbound-section__subscription-update {
    min-width: 130px;
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
    min-width: 99px;
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
    width: max-content;
    max-width: min(28ch, 30%);
    min-width: min-content;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    overflow-wrap: anywhere;
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
    border-color: var(--success-color-medium, green);
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
}

.tachyon_dashboard-page__outbound-grid__item__header b {
    min-width: 0;
    line-height: 1.25;
    overflow-wrap: anywhere;
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

.tachyon_dashboard-page__urltest-details {
    box-sizing: border-box;
    width: min(760px, calc(100vw - 56px));
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
    display: grid;
    gap: 6px;
    width: calc(100% + 14px);
    box-sizing: border-box;
    max-height: min(46vh, 460px);
    overflow-x: hidden;
    overflow-y: auto;
    padding-right: 14px;
    scrollbar-gutter: auto;
}

.tachyon_dashboard-page__urltest-details__row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(54px, max-content) 20px;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-width: 0;
    padding: 7px 8px;
    box-sizing: border-box;
    border: 1px solid transparent;
    border-bottom: 1px solid var(--border-color-low, #eee);
    border-radius: 4px;
}

.tachyon_dashboard-page__urltest-details__row--active {
    border-color: var(--success-color-low, #2d7d46);
    background: transparent;
}

.tachyon_dashboard-page__urltest-details__row-name,
.tachyon_dashboard-page__urltest-details__row-meta {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    line-height: 1.3;
}

.tachyon_dashboard-page__urltest-details__row-name {
    flex-wrap: wrap;
}

.tachyon_dashboard-page__urltest-details__row-name b {
    min-width: 0;
    overflow-wrap: anywhere;
    line-height: 1.3;
}

.tachyon_dashboard-page__urltest-details__priority-name {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 2px 0;
}

.tachyon_dashboard-page__urltest-details__priority-number {
    margin-right: 6px;
    color: var(--text-color-medium, #aaa);
    font-family: monospace;
    font-size: 13px;
    font-weight: 600;
}

.tachyon_dashboard-page__urltest-details__priority-level {
    margin-right: 8px;
    padding: 2px 6px;
    border-radius: 4px;
    color: var(--text-color-medium, #aaa);
    background: rgba(128, 128, 128, 0.15);
    font-size: 11px;
    font-weight: 400;
}

.tachyon_dashboard-page__urltest-details__country-badge {
    display: inline-flex;
    align-items: center;
    user-select: none;
    margin-right: 6px;
    padding: 2px 4px;
    border: 1px solid rgba(128, 128, 128, 0.25);
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    line-height: 1;
}

.tachyon_dashboard-page__urltest-details__priority-node {
    color: var(--text-color-high, #fff);
    font-weight: 600;
}

.tachyon_dashboard-page__urltest-details__row-type,
.tachyon_dashboard-page__urltest-details__row-meta {
    color: var(--text-color-medium, #666);
}

.tachyon_dashboard-page__urltest-details__row-type {
    white-space: nowrap;
    line-height: 1.3;
}

.tachyon_dashboard-page__urltest-details__row-meta {
    justify-content: flex-end;
    white-space: nowrap;
}

.tachyon_dashboard-page__urltest-details__copy-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 20px;
    width: 20px;
    min-width: 20px;
    height: 20px;
    padding: 0;
    box-sizing: border-box;
}

.tachyon_dashboard-page__urltest-details__copy-button svg {
    width: 12px;
    height: 12px;
}

.tachyon_dashboard-page__urltest-details__copy-placeholder {
    display: block;
    width: 20px;
    min-width: 20px;
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
    justify-content: flex-end;
    margin-top: 14px;
}

@media (max-width: 560px) {
    .tachyon_dashboard-page__urltest-details__params {
        grid-template-columns: 1fr;
    }

    .tachyon_dashboard-page__urltest-details__row {
        grid-template-columns: minmax(0, 1fr) 20px;
    }

    .tachyon_dashboard-page__urltest-details__row-meta {
        grid-column: 1 / -1;
        justify-content: flex-start;
    }
}

/* ─── Advanced Settings Panel ────────────────────────────────────── */

.tachyon_adv {
    margin-top: 20px;
    width: 100%;
}

.tachyon_adv__details {
    border: 1px solid var(--border-color, #dee2e6);
    border-radius: 6px;
    overflow: hidden;
}

.tachyon_adv__summary {
    padding: 12px 16px;
    font-weight: 600;
    font-size: 0.95rem;
    cursor: pointer;
    user-select: none;
    background: var(--section-header-bg, rgba(0,0,0,0.03));
    border-bottom: 1px solid transparent;
    list-style: none;
}

.tachyon_adv__details[open] .tachyon_adv__summary {
    border-bottom-color: var(--border-color, #dee2e6);
}

.tachyon_adv__summary::-webkit-details-marker { display: none; }
.tachyon_adv__summary::before {
    content: '▶ ';
    font-size: 0.75em;
    opacity: 0.6;
    transition: transform 0.15s;
}
.tachyon_adv__details[open] .tachyon_adv__summary::before {
    content: '▼ ';
}

.tachyon_adv__inner {
    padding: 0;
}

.tachyon_adv__body {
    display: flex;
    flex-direction: column;
    gap: 0;
}

.tachyon_adv__loading {
    padding: 20px 16px;
    opacity: 0.6;
}

.tachyon_adv__section {
    padding: 16px;
}

.tachyon_adv__section-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 10px;
}

.tachyon_adv__section-icon {
    font-size: 1.1rem;
}

.tachyon_adv__section-title {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
}

.tachyon_adv__divider {
    margin: 0;
    border: none;
    border-top: 1px solid var(--border-color, #dee2e6);
}

.tachyon_adv__row {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
    margin-bottom: 8px;
}

.tachyon_adv__label {
    font-weight: 500;
    min-width: 60px;
}

.tachyon_adv__badge {
    padding: 2px 10px;
    border-radius: 12px;
    font-size: 0.85rem;
    font-weight: 500;
}

.tachyon_adv__badge--ok {
    background: var(--success-bg, #d4edda);
    color: var(--success-fg, #155724);
}

.tachyon_adv__badge--err {
    background: var(--danger-bg, #f8d7da);
    color: var(--danger-fg, #721c24);
}

.tachyon_adv__ctrl-btn {
    margin-left: auto;
}

.tachyon_adv__hint {
    margin: 0 0 10px 0;
    font-size: 0.85rem;
    opacity: 0.75;
}

.tachyon_adv__sub-hint {
    margin: 8px 0 6px 0;
    font-size: 0.82rem;
    opacity: 0.7;
}

.tachyon_adv__toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    font-weight: 500;
}

.tachyon_adv__priority-list {
    margin: 8px 0 12px 0;
    border: 1px solid var(--border-color, #dee2e6);
    border-radius: 4px;
    overflow: hidden;
}

.tachyon_adv__priority-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 7px 10px;
    border-bottom: 1px solid var(--border-color, #dee2e6);
}

.tachyon_adv__priority-row:last-child {
    border-bottom: none;
}

.tachyon_adv__priority-row--off {
    opacity: 0.5;
}

.tachyon_adv__priority-label {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    flex: 1;
}

.tachyon_adv__priority-name {
    font-family: monospace;
    font-size: 0.9rem;
}

.tachyon_adv__priority-name--off {
    text-decoration: line-through;
}

.tachyon_adv__arrows {
    display: flex;
    gap: 4px;
}

.tachyon_adv__arrow {
    padding: 1px 7px;
    font-size: 0.75rem;
    line-height: 1.4;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 3px;
    background: transparent;
    cursor: pointer;
}

.tachyon_adv__arrow:disabled {
    opacity: 0.3;
    cursor: default;
}

.tachyon_adv__save-btn {
    margin-top: 10px;
}

/* Per-device routing */
.tachyon_adv__device-block {
    margin-bottom: 16px;
    padding: 12px;
    border: 1px solid var(--border-color, #dee2e6);
    border-radius: 5px;
}

.tachyon_adv__device-name {
    font-family: monospace;
    font-weight: 600;
    margin-bottom: 6px;
    font-size: 0.95rem;
}

.tachyon_adv__device-label {
    display: block;
    font-size: 0.85rem;
    opacity: 0.75;
    margin-bottom: 4px;
}

.tachyon_adv__device-ta {
    width: 100%;
    max-width: 360px;
    font-family: monospace;
    font-size: 0.875rem;
    resize: vertical;
}

`;

