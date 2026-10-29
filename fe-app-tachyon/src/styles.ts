// language=CSS
import { DashboardTab } from './tachyon/tabs/dashboard';
import { DiagnosticTab } from './tachyon/tabs/diagnostic';
import { MonitoringTab } from './tachyon/tabs/monitoring';
import { UpdatesTab } from './tachyon/tabs/updates';
import { PartialStyles } from './partials';
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from './constants';

export const GlobalStyles = `
${DashboardTab.styles}
${DiagnosticTab.styles}
${MonitoringTab.styles}
${UpdatesTab.styles}
${PartialStyles}

/* Scroll stability & theme anchoring isolation + Soft Violet Brand Accent */
[id^="cbi-${TACHYON_CBI_PREFIX}"],
.tachyon-view,
#modal_overlay,
.cbi-modal,
.tachyon-wizard,
#view > .cbi-page-actions {
    overflow-anchor: none !important;
    --tachyon-violet: #9482e0;
    --tachyon-violet-strong: #816ed4;
    --tachyon-violet-soft: rgba(148, 130, 224, 0.12);
    --tachyon-violet-border: rgba(148, 130, 224, 0.32);
    --primary-color-high: #9482e0;
    --primary-color-medium: #816ed4;
    --focus-color-rgb: 148, 130, 224;
}

/* Unified calm native button styling across Tachyon (eliminates bright cyan/green/orange/red LuCI button fills) */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button,
.tachyon-view .btn,
.tachyon-view .cbi-button,
#modal_overlay .btn,
#modal_overlay .cbi-button,
.cbi-modal .btn,
.cbi-modal .cbi-button,
#view > .cbi-page-actions .btn,
#view > .cbi-page-actions .cbi-button {
    background: var(--background-color-low, rgba(148, 163, 184, 0.08)) !important;
    border: 1px solid var(--border-color-medium, rgba(148, 163, 184, 0.24)) !important;
    color: var(--text-color-high, inherit) !important;
    box-shadow: none !important;
    text-shadow: none !important;
    outline: none !important;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button:hover:not(:disabled),
.tachyon-view .btn:hover:not(:disabled),
.tachyon-view .cbi-button:hover:not(:disabled),
#modal_overlay .btn:hover:not(:disabled),
#modal_overlay .cbi-button:hover:not(:disabled),
.cbi-modal .btn:hover:not(:disabled),
.cbi-modal .cbi-button:hover:not(:disabled),
#view > .cbi-page-actions .btn:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button:hover:not(:disabled) {
    background: rgba(148, 130, 224, 0.10) !important;
    border-color: rgba(148, 130, 224, 0.38) !important;
    color: var(--text-color-high, inherit) !important;
    box-shadow: none !important;
}

/* Primary / Tachyon-accented actions (Save, Apply, Positive) */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-apply,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-save,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-positive,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action.important,
#modal_overlay .cbi-button-apply,
#modal_overlay .cbi-button-save,
#modal_overlay .cbi-button-positive,
#modal_overlay .cbi-button-action.important,
.cbi-modal .cbi-button-apply,
.cbi-modal .cbi-button-save,
.cbi-modal .cbi-button-positive,
.cbi-modal .cbi-button-action.important,
#view > .cbi-page-actions .cbi-button-apply,
#view > .cbi-page-actions .cbi-button-save,
#view > .cbi-page-actions .cbi-button-positive,
#view > .cbi-page-actions .cbi-button-action.important {
    background: rgba(148, 130, 224, 0.14) !important;
    border-color: rgba(148, 130, 224, 0.38) !important;
    color: #b4a5f0 !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-apply:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-save:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-positive:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action.important:hover:not(:disabled),
#modal_overlay .cbi-button-apply:hover:not(:disabled),
#modal_overlay .cbi-button-save:hover:not(:disabled),
#modal_overlay .cbi-button-positive:hover:not(:disabled),
#modal_overlay .cbi-button-action.important:hover:not(:disabled),
.cbi-modal .cbi-button-apply:hover:not(:disabled),
.cbi-modal .cbi-button-save:hover:not(:disabled),
.cbi-modal .cbi-button-positive:hover:not(:disabled),
.cbi-modal .cbi-button-action.important:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-apply:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-save:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-positive:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-action.important:hover:not(:disabled) {
    background: rgba(148, 130, 224, 0.22) !important;
    border-color: rgba(148, 130, 224, 0.52) !important;
    color: #d8cff8 !important;
}

/* Negative / Remove buttons stay calm neutral until hovered */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-remove:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-negative:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-reset:hover:not(:disabled),
#modal_overlay .cbi-button-remove:hover:not(:disabled),
#modal_overlay .cbi-button-negative:hover:not(:disabled),
.cbi-modal .cbi-button-remove:hover:not(:disabled),
.cbi-modal .cbi-button-negative:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-reset:hover:not(:disabled),
#view > .cbi-page-actions .cbi-button-negative:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.12) !important;
    border-color: rgba(239, 68, 68, 0.42) !important;
    color: #fca5a5 !important;
}

/* Override LuCI Bootstrap default cyan/blue button hover & focus border/shadow on custom Tachyon buttons */
[id^="cbi-${TACHYON_CBI_PREFIX}"] button:not(.cbi-button),
[id^="cbi-${TACHYON_CBI_PREFIX}"] button:not(.cbi-button):hover,
[id^="cbi-${TACHYON_CBI_PREFIX}"] button:not(.cbi-button):focus,
[id^="cbi-${TACHYON_CBI_PREFIX}"] button:not(.cbi-button):active,
.tachyon-sidebar button,
.tachyon-sidebar button:hover,
.tachyon-sidebar button:focus,
.tachyon-sidebar button:active,
#modal_overlay button:not(.cbi-button),
#modal_overlay button:not(.cbi-button):hover,
#modal_overlay button:not(.cbi-button):focus,
#modal_overlay button:not(.cbi-button):active,
.cbi-modal button:not(.cbi-button),
.cbi-modal button:not(.cbi-button):hover,
.cbi-modal button:not(.cbi-button):focus,
.cbi-modal button:not(.cbi-button):active {
    --focus-color-rgb: 148, 130, 224 !important;
    outline: none !important;
    box-shadow: none !important;
}

.tachyon-mode-switcher__btn:hover,
.tachyon-mode-switcher__btn:focus,
.tachyon-studio-view-btn:hover,
.tachyon-studio-view-btn:focus,
.tachyon-nodes-block__section-tab:hover,
.tachyon-nodes-block__section-tab:focus,
.tachyon-dash-view-chip:hover,
.tachyon-dash-view-chip:focus,
.tachyon-dash-width-btn:hover,
.tachyon-dash-width-btn:focus,
.tachyon-node-card__copy-btn:hover,
.tachyon-node-card__copy-btn:focus,
.tachyon-node-card__latency:hover,
.tachyon-node-card__latency:focus,
.tachyon-sidebar__collapse-btn:hover,
.tachyon-sidebar__collapse-btn:focus {
    border-color: transparent !important;
    box-shadow: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] [data-fs-floor] {
    min-height: auto !important;
}

/* Hide extra H3 for settings tab */
#cbi-${TACHYON_CBI_PREFIX}-settings > h3 {
    display: none;
}

/* Hide extra H3 for rules tab */
#cbi-${TACHYON_CBI_PREFIX}-section > h3:nth-child(1) {
    display: none;
}

/* Vertical align for remove rule action button */
#cbi-${TACHYON_CBI_PREFIX}-section > .cbi-section-remove {
    margin-bottom: -32px;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-actions > div {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-actions {
    text-align: right;
}

/* Rule reorder visuals */
#cbi-${TACHYON_CBI_PREFIX}-section {
    position: relative;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row {
    position: relative;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.placeholder {
    opacity: 1;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.placeholder em {
    font-style: italic;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.drag-over-above::after,
#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.drag-over-below::after {
    content: '';
    position: absolute;
    left: 10px;
    right: 10px;
    height: 2px;
    border-radius: 2px;
    background: #9482e0;
    pointer-events: none;
    z-index: 2;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.drag-over-above::after {
    top: -1px;
}

#cbi-${TACHYON_CBI_PREFIX}-section .cbi-section-table-row.drag-over-below::after {
    bottom: -1px;
}

/* Centered class helper */
.centered {
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Rotate class helper */
.rotate {
    animation: spin 1s linear infinite;
}

@keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
}

/* Skeleton styles*/
.skeleton {
    background-color: var(--background-color-low, #e0e0e0);
    border-radius: 4px;
    position: relative;
    overflow: hidden;
}

.skeleton::after {
    content: '';
    position: absolute;
    top: 0;
    left: -150%;
    width: 150%;
    height: 100%;
    background: linear-gradient(
            90deg,
            transparent,
            rgba(255, 255, 255, 0.4),
            transparent
    );
    animation: skeleton-shimmer 1.6s infinite;
}

@keyframes skeleton-shimmer {
    100% {
        left: 150%;
    }
}
/* Toast */
.toast-container {
    position: fixed;
    bottom: 30px;
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    z-index: 9999;
    font-family: system-ui, sans-serif;
}

.toast {
    opacity: 0;
    transform: translateY(10px);
    transition: opacity 0.3s ease, transform 0.3s ease;
    padding: 10px 16px;
    border-radius: 6px;
    color: #fff;
    font-size: 14px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
    min-width: 220px;
    max-width: 340px;
    text-align: center;
}

.toast-success {
    background-color: #28a745;
}

.toast-error {
    background-color: #dc3545;
}

.toast.visible {
    opacity: 1;
    transform: translateY(0);
}

/* Tachyon Mobile & Responsive Layout Enhancements */
@media (max-width: 768px) {
    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-section-table,
    .tachyon-view .cbi-section-table {
        display: block;
        width: 100%;
        overflow-x: auto;
        -webkit-overflow-scrolling: touch;
        border-collapse: collapse;
    }

    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-section-table-cell,
    .tachyon-view .cbi-section-table-cell {
        min-width: 0;
        word-break: break-word;
        overflow-wrap: anywhere;
    }

    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-section-actions,
    .tachyon-view .cbi-section-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 6px;
    }

    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-dropdown,
    .tachyon-view .cbi-dropdown {
        max-width: 100%;
    }

    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-textarea,
    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-text,
    [id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-select,
    .tachyon-view .cbi-input-textarea,
    .tachyon-view .cbi-input-text,
    .tachyon-view .cbi-input-select {
        max-width: 100%;
        box-sizing: border-box;
    }
}

/* Tachyon modal sizing by content type */

/* Compact modals: UrlTest details, priority info */
.modal:has(.tachyon_dashboard-page__urltest-details),
.cbi-modal:has(.tachyon_dashboard-page__urltest-details) {
    width: min(94vw, 680px) !important;
    max-width: min(94vw, 680px) !important;
    box-sizing: border-box;
    margin: 10px auto;
}

/* Medium modals: Support, Service check, DNS benchmark, Updates, AI Chat, Server info */
.modal:has(.tachyon-support-modal),
.cbi-modal:has(.tachyon-support-modal),
.modal:has(.tachyon-service-check-modal),
.cbi-modal:has(.tachyon-service-check-modal),
.modal:has(.tachyon-dns-benchmark-modal),
.cbi-modal:has(.tachyon-dns-benchmark-modal),
.modal:has(.tachyon-update-progress-modal),
.cbi-modal:has(.tachyon-update-progress-modal),
.modal:has(.tachyon-ai-chat-modal),
.cbi-modal:has(.tachyon-ai-chat-modal),
.modal.fkp-server-info-dialog,
.cbi-modal.fkp-server-info-dialog,
.modal:has(.fkp-server-info-modal),
.cbi-modal:has(.fkp-server-info-modal) {
    width: min(94vw, 880px) !important;
    max-width: min(94vw, 880px) !important;
    box-sizing: border-box;
    margin: 10px auto;
}

.modal .fkp-server-info-modal,
.cbi-modal .fkp-server-info-modal {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box;
    margin: 0 !important;
}

/* Wide modals: Strategy Fuzzer, Leak detection */
.modal:has(.tachyon-strategy-fuzzer-modal),
.cbi-modal:has(.tachyon-strategy-fuzzer-modal),
.modal:has(.tachyon-leak-check-modal),
.cbi-modal:has(.tachyon-leak-check-modal) {
    width: min(96vw, 1200px) !important;
    max-width: min(96vw, 1200px) !important;
    box-sizing: border-box;
    margin: 10px auto;
}

/* General Tachyon modals: comfortable width on desktop, full-width on mobile */
.modal:has([class*="tachyon"]),
.cbi-modal:has([class*="tachyon"]) {
    width: min(94vw, 820px) !important;
    max-width: min(94vw, 820px) !important;
    box-sizing: border-box;
    margin: 10px auto;
}

/* Tablet / mobile: let the overlay use nearly the whole viewport */
@media (max-width: 900px) {
    .modal:has([class*="tachyon"]),
    .cbi-modal:has([class*="tachyon"]),
    .modal:has(.fkp-server-info-modal),
    .cbi-modal:has(.fkp-server-info-modal) {
        width: 96vw !important;
        max-width: 96vw !important;
    }
}

/* Phones: edge-to-edge with small gutters */
@media (max-width: 640px) {
    .modal:has([class*="tachyon"]),
    .cbi-modal:has([class*="tachyon"]),
    .modal:has(.fkp-server-info-modal),
    .cbi-modal:has(.fkp-server-info-modal) {
        width: calc(100vw - 16px) !important;
        max-width: calc(100vw - 16px) !important;
        margin: 8px auto;
    }
}

/* Header language selector */
.tachyon-map-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
}

.tachyon-lang-selector {
    position: relative;
    display: inline-flex;
    align-items: center;
    margin-left: auto;
    font-size: 13px;
    font-weight: 500;
    line-height: 1.2;
}

.tachyon-lang-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    border-radius: 6px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.35));
    background: var(--background-color-high, rgba(128, 128, 128, 0.08));
    color: inherit;
    cursor: pointer;
    font-size: 12px;
    font-weight: 600;
    transition: background-color 0.15s ease, border-color 0.15s ease;
}

.tachyon-lang-btn:hover:not(:disabled) {
    background: var(--background-color-low, rgba(128, 128, 128, 0.16));
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-lang-btn:disabled {
    opacity: 0.65;
    cursor: wait;
}

.tachyon-lang-flag {
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon-lang-code {
    letter-spacing: 0.03em;
}

.tachyon-lang-caret {
    font-size: 10px;
    opacity: 0.7;
}

.tachyon-lang-menu {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    min-width: 210px;
    padding: 6px;
    border-radius: 8px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.3));
    background: var(--background-color-high, #fff);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18);
    z-index: 1000;
}

.tachyon-lang-menu[hidden] {
    display: none !important;
}

.tachyon-lang-menu__header {
    padding: 4px 8px 6px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.6;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.15));
    margin-bottom: 4px;
}

.tachyon-lang-option {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 7px 8px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: inherit;
    text-align: left;
    cursor: pointer;
    transition: background-color 0.12s ease;
}

.tachyon-lang-option:hover {
    background: var(--background-color-low, rgba(128, 128, 128, 0.12));
}

.tachyon-lang-option.is-active {
    background: rgba(139, 92, 246, 0.1);
}

.tachyon-lang-option__text {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
}

.tachyon-lang-option__native {
    font-size: 13px;
    font-weight: 600;
}

.tachyon-lang-option__sub {
    font-size: 11px;
    opacity: 0.65;
}

.tachyon-lang-option__badge {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 4px;
    white-space: nowrap;
}

.tachyon-lang-option__badge--active {
    color: #b4a5f0;
}

.tachyon-lang-option__badge--install {
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
}

/* ==========================================================================
   Tachyon App Shell (Sidebar + Topbar + Simple / Advanced UI Mode)
   Uses native LuCI CSS variables (--background-color-*, --border-color-*, --primary-color-*)
   ========================================================================== */

.tachyon-hidden-luci-tabs,
#cbi-tachyon > h2,
#cbi-tachyon > .cbi-map-descr,
#cbi-tachyon > .cbi-tabmenu,
.tachyon-workspace-body > h2,
.tachyon-workspace-body > .cbi-map-descr,
.tachyon-workspace-body > .cbi-tabmenu,
.tachyon-workspace-body .cbi-tabmenu:not(.tachyon-sec-modal-tabs),
.tachyon-main-workspace > .cbi-tabmenu,
.cbi-map-tabbed > .cbi-tabmenu,
#cbi-tachyon-settings .cbi-tabmenu,
.cbi-section > .cbi-tabmenu,
.cbi-section-node > .cbi-tabmenu,
#cbi-tachyon-schedule > h3,
#cbi-tachyon-profile > h3,
#cbi-tachyon-guest_mode > h3,
#cbi-tachyon-server > h3,
#cbi-tachyon-telegram > h3,
#cbi-tachyon-settings > h3,
#cbi-tachyon-section > h3,
#cbi-tachyon-condition > h3,
#cbi-tachyon-outbound_source > h3,
#cbi-tachyon-balancer > h3,
.tachyon-section-subpane > .cbi-section > h3,
.tachyon-subtab-container > .cbi-section > h3,
#cbi-tachyon-schedule > .cbi-section-descr,
#cbi-tachyon-profile > .cbi-section-descr,
#cbi-tachyon-guest_mode > .cbi-section-descr,
#cbi-tachyon-server > .cbi-section-descr,
#cbi-tachyon-telegram > .cbi-section-descr,
#cbi-tachyon-settings > .cbi-section-descr,
#cbi-tachyon-section > .cbi-section-descr,
#cbi-tachyon-condition > .cbi-section-descr,
#cbi-tachyon-outbound_source > .cbi-section-descr,
#cbi-tachyon-balancer > .cbi-section-descr,
.tachyon-section-subpane > .cbi-section-descr,
.tachyon-section-subpane > .cbi-section > .cbi-section-descr {
    display: none !important;
}

.cbi-section,
.cbi-section-node,
.tachyon-subtab-container {
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
    overflow: visible !important;
}

.cbi-section-table {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box;
}

.cbi-section-table th,
.cbi-section-table .th {
    white-space: nowrap !important;
    word-break: normal !important;
    overflow-wrap: normal !important;
    vertical-align: middle;
}

.cbi-section-table td,
.cbi-section-table .td {
    white-space: normal !important;
    word-break: normal;
    overflow-wrap: break-word;
    vertical-align: middle;
}

.cbi-section-table .cbi-section-actions,
.cbi-section-table .cbi-section-actions * {
    white-space: nowrap !important;
    word-break: normal !important;
}

.cbi-map-tabbed {
    min-width: 0;
    max-width: 100%;
    width: 100%;
    box-sizing: border-box;
}

.cbi-map-tabbed > .cbi-section[data-tab-active="false"],
.cbi-map-tabbed > .cbi-section.cbi-tab-disabled,
.tachyon-workspace-body > .cbi-section[data-tab-active="false"],
.tachyon-workspace-body > .cbi-section.cbi-tab-disabled {
    display: none !important;
    padding: 0 !important;
    margin: 0 !important;
    border: none !important;
}

/* Keep LuCI top navigation bar and its dropdown menus above Tachyon stacking contexts */
body > header,
header,
#topmenu,
#mainmenu,
header .dropdown-menu {
    z-index: 1200 !important;
}

#maincontent {
    position: relative;
    z-index: 1;
}

#cbi-tachyon {
    position: relative;
    z-index: 1;
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
}

.tachyon-shell-layout {
    display: flex;
    align-items: stretch;
    gap: 14px;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    min-height: 0;
    box-sizing: border-box;
    margin-top: 6px;
}

#view > .cbi-page-actions,
#cbi-tachyon ~ .cbi-page-actions {
    position: sticky;
    bottom: 10px;
    z-index: 40;
    display: flex !important;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 8px;
    margin: 12px 0 8px 228px;
    padding: 10px 14px !important;
    border-radius: 12px;
    background: var(--background-color-high, rgba(255, 255, 255, 0.94)) !important;
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.24)) !important;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
    box-sizing: border-box;
    text-align: right;
    transition: margin 0.18s ease;
}

#view > .cbi-page-actions::before,
#view > .cbi-page-actions::after,
#cbi-tachyon ~ .cbi-page-actions::before,
#cbi-tachyon ~ .cbi-page-actions::after {
    display: none !important;
    content: none !important;
}

#cbi-tachyon[data-sidebar-collapsed="true"] ~ .cbi-page-actions {
    margin-left: 82px;
}

#cbi-tachyon[data-sidebar-pos="right"] ~ .cbi-page-actions {
    margin-left: 0;
    margin-right: 228px;
}

#cbi-tachyon[data-sidebar-pos="right"][data-sidebar-collapsed="true"] ~ .cbi-page-actions {
    margin-left: 0;
    margin-right: 82px;
}

#view > .cbi-page-actions .cbi-button,
#view > .cbi-page-actions .btn,
#cbi-tachyon ~ .cbi-page-actions .cbi-button,
#cbi-tachyon ~ .cbi-page-actions .btn {
    margin: 0 !important;
    border-radius: 8px !important;
    font-weight: 700 !important;
    font-size: 12.5px !important;
    padding: 6px 14px !important;
    word-break: normal !important;
}

.tachyon-shell-layout[data-sidebar-pos="right"],
#cbi-tachyon[data-sidebar-pos="right"] > .tachyon-shell-layout {
    flex-direction: row-reverse;
}

.tachyon-sidebar {
    width: 228px;
    min-width: 228px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 14px;
    padding: 10px 8px;
    box-sizing: border-box;
    position: sticky;
    top: 12px;
    align-self: flex-start;
    max-height: calc(100vh - 28px);
    overflow-y: auto;
    overflow-x: hidden;
    transition: width 0.18s ease, min-width 0.18s ease, padding 0.18s ease;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar {
    width: 68px;
    min-width: 68px;
    padding: 12px 8px;
    align-items: center;
}

.tachyon-sidebar__brand {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 8px 12px;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    margin-bottom: 10px;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand {
    flex-direction: column;
    justify-content: center;
    gap: 6px;
    padding: 4px 0 10px;
    width: 100%;
}

.tachyon-sidebar__logo,
.tachyon-sidebar__logo-wrap {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    cursor: pointer;
}

.tachyon-sidebar__brand-text {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
    line-height: 1.2;
}

.tachyon-sidebar__collapse-btn {
    padding: 4px 8px;
    border-radius: 7px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: transparent;
    color: inherit;
    font-size: 13px;
    font-weight: 700;
    cursor: pointer;
    opacity: 0.75;
    flex-shrink: 0;
}

.tachyon-sidebar__collapse-btn:hover {
    opacity: 1;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text {
    display: none;
}

.tachyon-sidebar__brand-title {
    font-size: 16px;
    font-weight: 800;
    letter-spacing: -0.01em;
}

.tachyon-sidebar__brand-sub {
    font-size: 11px;
    opacity: 0.65;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-sidebar__mode-switcher {
    display: flex;
    width: 100%;
    margin-bottom: 8px;
    box-sizing: border-box;
}

.tachyon-sidebar__mode-switcher .tachyon-mode-switcher__btn {
    flex: 1 1 0%;
    text-align: center;
    padding: 5px 6px;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__mode-switcher,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__mode-switcher,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__footer-tools,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__footer-tools {
    display: none !important;
}

.tachyon-sidebar__footer-tools {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    width: 100%;
}

.tachyon-sidebar__cta-wrap {
    padding: 0 2px 10px;
    width: 100%;
    box-sizing: border-box;
}

.tachyon-sidebar__wizard-btn {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 8.5px 12px;
    border-radius: 10px;
    border: 1px solid rgba(148, 130, 224, 0.32) !important;
    background: rgba(148, 130, 224, 0.14) !important;
    color: #9c8be3 !important;
    font-size: 13px;
    font-weight: 700;
    cursor: pointer;
    box-shadow: none !important;
    transition: background-color 0.15s ease, border-color 0.15s ease;
}

.tachyon-sidebar__wizard-btn:hover,
.tachyon-sidebar__wizard-btn:focus {
    background: rgba(148, 130, 224, 0.20) !important;
    border-color: rgba(148, 130, 224, 0.45) !important;
    box-shadow: none !important;
}

.tachyon-sidebar__wizard-btn-plus {
    font-size: 16px;
    line-height: 1;
    font-weight: 800;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__wizard-btn-text,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__wizard-text,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__wizard-text {
    display: none;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__wizard-btn,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__wizard-btn {
    padding: 9px 0;
}

.tachyon-sidebar__nav {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    width: 100%;
}

.tachyon-sidebar__menu-block {
    display: flex;
    flex-direction: column;
    gap: 2px;
    width: 100%;
}

.tachyon-sidebar__group {
    display: flex;
    flex-direction: column;
    gap: 3px;
}

.tachyon-sidebar__group-title {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    opacity: 0.55;
    padding: 4px 10px 2px;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__group-title,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__group-title {
    display: none;
}

.tachyon-sidebar__item,
.tachyon-sidebar__nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 8.5px 10px;
    border: 1px solid transparent;
    border-radius: 9px;
    background: transparent;
    color: inherit;
    font-size: 13px;
    font-weight: 600;
    text-align: left;
    cursor: pointer;
    box-sizing: border-box;
    transition: background-color 0.12s ease, border-color 0.12s ease, color 0.12s ease;
}

.tachyon-sidebar__item:hover,
.tachyon-sidebar__nav-item:hover {
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border-color: transparent !important;
    box-shadow: none !important;
}

.tachyon-sidebar__item:focus,
.tachyon-sidebar__nav-item:focus,
.tachyon-sidebar__subitem:focus {
    outline: none !important;
    box-shadow: none !important;
    border-color: transparent !important;
}

.tachyon-sidebar__item.is-active,
.tachyon-sidebar__nav-item.is-active,
.tachyon-sidebar__item.is-active:hover,
.tachyon-sidebar__nav-item.is-active:hover,
.tachyon-sidebar__item.is-active:focus,
.tachyon-sidebar__nav-item.is-active:focus {
    background: rgba(148, 130, 224, 0.11) !important;
    border-color: rgba(148, 130, 224, 0.26) !important;
    color: #9c8be3 !important;
    box-shadow: none !important;
    font-weight: 700;
}

.tachyon-sidebar__nav-parent.has-active-child,
.tachyon-sidebar__nav-parent.has-active-child:hover,
.tachyon-sidebar__nav-parent.has-active-child:focus {
    background: rgba(148, 130, 224, 0.06) !important;
    border-color: transparent !important;
    color: #9c8be3 !important;
    box-shadow: none !important;
    font-weight: 700;
}

.tachyon-sidebar__nav-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-sidebar__nav-count {
    font-size: 10px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 999px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.14));
    opacity: 0.72;
}

.tachyon-sidebar__chevron {
    flex-shrink: 0;
    opacity: 0.65;
    transform: rotate(-90deg);
    transition: transform 0.16s ease, opacity 0.16s ease;
}

.tachyon-sidebar__chevron.is-open {
    transform: rotate(0deg);
    opacity: 0.95;
}

.tachyon-sidebar__submenu {
    display: none;
    flex-direction: column;
    gap: 2px;
    margin: 2px 0 4px 6px;
    padding-left: 6px;
    border-left: 1.5px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
}

.tachyon-sidebar__submenu.is-open {
    display: flex;
}

.tachyon-sidebar__subitem {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    padding: 6px 8px;
    border: 1px solid transparent;
    border-radius: 8px;
    background: transparent;
    color: inherit;
    font-size: 12.5px;
    font-weight: 500;
    text-align: left;
    cursor: pointer;
    opacity: 0.78;
    box-sizing: border-box;
    transition: background-color 0.12s ease, opacity 0.12s ease, color 0.12s ease;
}

.tachyon-sidebar__subitem:hover {
    opacity: 1;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border-color: transparent !important;
    box-shadow: none !important;
}

.tachyon-sidebar__subitem.is-active,
.tachyon-sidebar__subitem.is-active:hover,
.tachyon-sidebar__subitem.is-active:focus {
    opacity: 1;
    font-weight: 700;
    color: #9c8be3 !important;
    background: rgba(148, 130, 224, 0.11) !important;
    border-color: rgba(148, 130, 224, 0.24) !important;
    box-shadow: none !important;
}

.tachyon-sidebar__subitem-dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: currentColor;
    opacity: 0.5;
    flex-shrink: 0;
}

.tachyon-sidebar__subitem.is-active .tachyon-sidebar__subitem-dot {
    opacity: 1;
    transform: scale(1.25);
}

.tachyon-sidebar__subitem-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-sidebar__item-icon,
.tachyon-sidebar__icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    opacity: 0.85;
}

.tachyon-sidebar__item.is-active .tachyon-sidebar__item-icon,
.tachyon-sidebar__nav-item.is-active .tachyon-sidebar__icon {
    opacity: 1;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__item,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-item,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-item {
    justify-content: center;
    padding: 9px 0;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__item-label,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-label,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-count,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__chevron,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__submenu,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-label,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__nav-count,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__chevron,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__submenu {
    display: none !important;
}

.tachyon-sidebar__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    padding-top: 10px;
    margin-top: 12px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    width: 100%;
}

.tachyon-sidebar__status-card {
    display: flex;
    flex-direction: column;
    gap: 3px;
    width: 100%;
    padding: 6px 8px;
    border-radius: 8px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    box-sizing: border-box;
}

.tachyon-sidebar__status-row {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: 12px;
    font-weight: 700;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__status-row,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__status-row {
    justify-content: center;
}

.tachyon-sidebar__status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
}

.tachyon-sidebar__status-dot--ok {
    background: #10b981;
}

.tachyon-sidebar__status-dot--warn {
    background: #f59e0b;
}

.tachyon-sidebar__status-dot--err {
    background: #ef4444;
}

.tachyon-sidebar__status-meta {
    font-size: 11px;
    opacity: 0.65;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__status-label,
.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__status-meta,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__status-label,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__status-meta {
    display: none;
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__footer,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__footer {
    flex-direction: column;
}

.tachyon-sidebar__tool-btn,
.tachyon-topbar__icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 5px;
    padding: 6px 10px;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: transparent;
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.82;
    transition: opacity 0.12s ease, background-color 0.12s ease;
}

.tachyon-sidebar__tool-btn:hover,
.tachyon-topbar__icon-btn:hover {
    opacity: 1;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__tool-label {
    display: none;
}

.tachyon-shell-main,
.tachyon-main-workspace {
    flex: 1 1 0%;
    min-width: 0;
    max-width: 100%;
    display: flex;
    flex-direction: column;
    gap: 10px;
    box-sizing: border-box;
}

.tachyon-topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding: 8px 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 12px;
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    min-width: 0;
}

.tachyon-topbar__left {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    min-width: 0;
}

.tachyon-topbar__right,
.tachyon-topbar__controls {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    min-width: 0;
}

.tachyon-mode-switcher {
    display: inline-flex;
    align-items: center;
    padding: 3px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.12));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
}

.tachyon-mode-switcher__btn {
    padding: 5px 11px;
    border: none;
    border-radius: 7px;
    background: transparent;
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.72;
    white-space: nowrap;
    transition: background-color 0.14s ease, opacity 0.14s ease, color 0.14s ease;
}

.tachyon-mode-switcher__btn:hover {
    opacity: 1;
}

.tachyon-mode-switcher__btn.is-active {
    background: rgba(148, 130, 224, 0.16);
    color: #b4a5f0;
    opacity: 1;
    font-weight: 700;
    box-shadow: none;
}

.tachyon-topbar__eco-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 11px;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-topbar__eco-btn:hover {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-topbar__eco-btn.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-topbar__eco-btn:disabled {
    opacity: 0.6;
    cursor: wait;
}

.tachyon-topbar__wizard-btn {
    padding: 5px 11px;
    border-radius: 8px;
    border: 1px solid rgba(148, 130, 224, 0.36);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-size: 12px;
    font-weight: 700;
    white-space: nowrap;
    cursor: pointer;
}

.tachyon-topbar__wizard-btn:hover {
    background: rgba(148, 130, 224, 0.22);
    border-color: rgba(148, 130, 224, 0.48);
}

.tachyon-topbar__lang-slot .tachyon-lang-switcher {
    margin-left: 0;
}

/* ==========================================================================
   Dashboard Top KPI Grid + Live Traffic Chart + Split Overview
   ========================================================================== */

/* Uniform 10px spacing and 2-column modular widget grid on Dashboard */
.tachyon_dashboard-page__content {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    align-items: stretch;
}

.tachyon_dashboard-page__content > * {
    grid-column: 1 / -1;
    min-width: 0;
}

.tachyon_dashboard-page__content > .tachyon-dashboard-widget-slot--half {
    grid-column: span 1;
}

.tachyon_dashboard-page__content > .tachyon-dashboard-widget-slot--full {
    grid-column: 1 / -1;
}

.tachyon-dashboard-widget-slot {
    display: flex;
    flex-direction: column;
    min-width: 0;
    margin: 0 !important;
}

.tachyon-dashboard-widget-slot > * {
    flex: 1;
    margin-top: 0 !important;
    margin-bottom: 0 !important;
}

#dashboard-sections-grid.tachyon-dashboard-widget-slot {
    gap: 10px;
}

#dashboard-sections-grid.tachyon-dashboard-widget-slot > * {
    flex: 0 0 auto;
}

.tachyon_dashboard-page__widgets-section {
    display: contents !important;
    margin: 0 !important;
}

.tachyon-dashboard-widget-slot:empty,
.tachyon-dashboard-widget-slot[hidden],
#dashboard-kpi-row:empty,
#dashboard-overview-row:empty,
#dashboard-router-services-strip:empty,
#dashboard-widget-inbounds:empty,
#dashboard-connections-grid:empty,
#dashboard-sections-grid:empty {
    display: none !important;
}

#dashboard-kpi-row,
#dashboard-overview-row,
#dashboard-router-services-strip,
#dashboard-widget-inbounds,
#dashboard-connections-grid,
#dashboard-sections-grid {
    margin-top: 0 !important;
    margin-bottom: 0 !important;
}

#dashboard-widget-inbounds > *,
#dashboard-connections-grid > .tachyon_dashboard-page__outbound-section,
#dashboard-sections-grid > .tachyon-routing-sections-block {
    margin-top: 0 !important;
    margin-bottom: 0 !important;
}

.tachyon-kpi-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    margin-bottom: 0;
}

.tachyon-kpi-card {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    justify-content: space-between;
    gap: 5px;
    padding: 10px 12px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
    min-width: 0;
}

.tachyon-kpi-card__top {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
}

.tachyon-kpi-card__icon-ring {
    width: 24px;
    height: 24px;
    border-radius: 7px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
    flex-shrink: 0;
}

.tachyon-kpi-card__mid {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    min-width: 0;
}

.tachyon-kpi-card__left,
.tachyon-kpi-card__info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
}

.tachyon-kpi-card__label,
.tachyon-kpi-card__title {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.02em;
    opacity: 0.68;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
    flex: 1;
}

.tachyon-kpi-card__value {
    font-size: 18px;
    font-weight: 800;
    line-height: 1.15;
    letter-spacing: -0.01em;
    white-space: nowrap;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-card__sub {
    font-size: 10.5px;
    opacity: 0.72;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
}

.tachyon-kpi-card__spark {
    flex-shrink: 0;
    width: 52px;
    height: 20px;
    overflow: hidden;
}

.tachyon-kpi-card__spark svg {
    width: 100%;
    height: auto;
    display: block;
}

.tachyon-overview-split {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 10px;
    margin-bottom: 0;
    align-items: stretch;
}

#dashboard-overview-row > #dashboard-traffic-chart-card,
#dashboard-overview-row > #dashboard-widget-system-services,
.tachyon-overview-split__chart,
.tachyon-overview-split__system {
    min-width: 0;
    display: flex;
    flex-direction: column;
}

#dashboard-overview-row > #dashboard-traffic-chart-card > *,
#dashboard-overview-row > #dashboard-widget-system-services > *,
.tachyon-overview-split__system > * {
    flex: 1;
    height: 100%;
    margin-bottom: 0 !important;
}

.tachyon-dual-card--single-col .tachyon-dual-card__body {
    grid-template-columns: minmax(0, 1fr) !important;
    gap: 6px;
}

.tachyon-dual-card--single-col .tachyon-dual-card__col:first-child {
    padding-right: 0 !important;
    border-right: none !important;
    padding-bottom: 0 !important;
    border-bottom: none !important;
}

.tachyon-router-services-slot {
    width: 100%;
    margin-bottom: 0;
}

.tachyon-router-services-slot:empty {
    display: none;
}

.tachyon-router-services-bar {
    display: flex !important;
    flex-direction: row !important;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 14px;
    padding: 8px 14px !important;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
    width: 100%;
}

.tachyon-router-services-bar__title {
    font-size: 11px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.72;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon-router-services-bar__list {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 6px 10px;
    flex: 1 1 auto;
    min-width: 0;
}

.tachyon-router-services-bar__item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 4px 10px;
    border-radius: 8px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.07));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
    white-space: nowrap;
    min-width: 0;
}

.tachyon-router-services-bar__item-key {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-weight: 700;
}

.tachyon-router-services-bar__item-val {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-overview-split__system .tachyon_dashboard-page__widgets-section__item {
    padding: 11px 13px;
}

.tachyon-overview-split__system .tachyon-dual-card__body {
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 16px;
}

.tachyon-overview-split__system .tachyon-dual-card__col:first-child {
    padding-right: 16px;
    border-right: 1px solid rgba(128, 128, 128, 0.14);
    padding-bottom: 0;
    border-bottom: none;
}

.tachyon-overview-split__system .tachyon-dual-card__column-title {
    font-size: 10px;
    margin-bottom: 3px;
    padding-bottom: 3px;
}

.tachyon-overview-split__system .tachyon_dashboard-page__widgets-section__item__row {
    font-size: 12px;
    min-height: 21px;
    margin-top: 2px;
}

.tachyon-traffic-chart-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    height: 100%;
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
    gap: 8px;
}

.tachyon-traffic-chart-card__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-traffic-chart-card__legend {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    font-size: 11px;
    font-weight: 600;
}

.tachyon-traffic-chart-card__legend-item {
    display: inline-flex;
    align-items: center;
    gap: 5px;
}

.tachyon-traffic-chart-card__dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    display: inline-block;
}

.tachyon-traffic-chart-card__canvas,
.tachyon-traffic-chart-card__body {
    width: 100%;
    min-height: 112px;
    height: 100%;
    overflow: hidden;
    flex: 1;
}

.tachyon-traffic-chart-svg {
    width: 100%;
    height: 100%;
    display: block;
}

/* ==========================================================================
   Two-Block Dashboard Redesign:
   Block 1: Секции маршрутизации (tachyon-routing-sections-block)
   Block 2: Узлы (tachyon-nodes-block + 4-col tachyon-nodes-grid)
   ========================================================================== */

.tachyon-routing-sections-block,
.tachyon-nodes-block {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px 14px;
    border-radius: 14px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    margin-bottom: 0;
    box-sizing: border-box;
}

.tachyon-routing-sections-block__header,
.tachyon-nodes-block__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-routing-sections-block__title,
.tachyon-nodes-block__title {
    margin: 0;
    font-size: 15px;
    font-weight: 800;
    letter-spacing: -0.01em;
}

.tachyon-routing-sections-block__test-all-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    border-radius: 8px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.26));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-routing-sections-block__test-all-btn:hover {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-routing-sections-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-routing-row {
    display: grid;
    grid-template-columns: minmax(0, 2.15fr) minmax(0, 1.05fr) minmax(0, 1.15fr) 84px 58px 92px;
    align-items: center;
    gap: 8px;
    padding: 9px 11px;
    border-radius: 11px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    cursor: pointer;
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    transition: border-color 0.14s ease, background-color 0.14s ease, box-shadow 0.14s ease;
}

.tachyon-routing-row:hover {
    border-color: var(--border-color-medium, rgba(128, 128, 128, 0.34));
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
}

.tachyon-routing-row.is-selected {
    border-color: rgba(148, 130, 224, 0.45);
    background: rgba(148, 130, 224, 0.08);
}

.tachyon-routing-row.has-error {
    border-color: rgba(239, 68, 68, 0.55);
}

.tachyon-routing-row__identity {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
}

.tachyon-routing-row__icon {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    position: relative;
    overflow: hidden;
    transition: transform 0.14s ease, box-shadow 0.14s ease;
}

.tachyon-routing-row__icon.is-clickable {
    cursor: pointer;
}

.tachyon-routing-row__icon.is-clickable:hover {
    transform: scale(1.06);
    box-shadow: 0 0 0 2px #9482e0;
}

.tachyon-routing-row__icon-inner {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;
}

.tachyon-routing-row__favicon {
    width: 20px;
    height: 20px;
    border-radius: 4px;
    object-fit: contain;
    display: block;
}

.tachyon-routing-row__titles {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
    flex: 1;
}

.tachyon-routing-row__title-line {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
    min-width: 0;
}

.tachyon-routing-row__status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    display: inline-block;
    flex-shrink: 0;
}

.tachyon-routing-row__status-dot.is-online {
    background: #10b981;
    box-shadow: 0 0 0 3px rgba(16, 185, 129, 0.2), 0 0 8px rgba(16, 185, 129, 0.65);
}

.tachyon-routing-row__status-dot.is-offline {
    background: #ef4444;
    box-shadow: 0 0 0 3px rgba(239, 68, 68, 0.2);
}

.tachyon-routing-row__ping--led {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border-radius: 999px;
    background: rgba(16, 185, 129, 0.1);
    border: 1px solid rgba(16, 185, 129, 0.26);
}

.tachyon-routing-row__name {
    font-size: 13px;
    font-weight: 800;
    flex-shrink: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-routing-row__subtitle {
    font-size: 10.5px;
    opacity: 0.65;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-routing-row__status-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 999px;
    font-size: 10px;
    font-weight: 700;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon-routing-row__status-badge.is-active {
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    border: 1px solid rgba(148, 130, 224, 0.28);
}

.tachyon-routing-row__status-badge.is-error {
    background: rgba(239, 68, 68, 0.14);
    color: #ef4444;
    border: 1px solid rgba(239, 68, 68, 0.3);
}

.tachyon-routing-row__engine-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 6px;
    font-size: 10px;
    font-weight: 700;
    white-space: nowrap;
    flex-shrink: 0;
    letter-spacing: 0.01em;
}

.tachyon-routing-row__engine-badge--dpi {
    background: rgba(148, 163, 184, 0.1);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.22);
}

.tachyon-routing-row__engine-badge--proxy {
    background: rgba(148, 130, 224, 0.12);
    color: #b4a5f0;
    border: 1px solid rgba(148, 130, 224, 0.28);
}

.tachyon-routing-row__engine-badge--transport {
    background: rgba(148, 163, 184, 0.1);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.22);
}

.modal:has(.tachyon-icon-picker),
.cbi-modal:has(.tachyon-icon-picker) {
    width: min(94vw, 540px) !important;
    max-width: min(94vw, 540px) !important;
}

.tachyon-icon-picker {
    display: flex;
    flex-direction: column;
    gap: 14px;
    max-width: 100%;
    width: 100%;
    box-sizing: border-box;
}

.tachyon-icon-picker__desc {
    margin: 0;
    font-size: 12.5px;
    opacity: 0.78;
    line-height: 1.4;
}

.tachyon-icon-picker__preview-row,
.tachyon-icon-picker__input-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-radius: 10px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.07));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-icon-picker__preview-icon,
.tachyon-icon-picker__preview {
    width: 36px;
    height: 36px;
    border-radius: 9px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24));
}

.tachyon-icon-picker__preview-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    font-size: 13px;
}

.tachyon-icon-picker__preview-domain {
    font-size: 11.5px;
    opacity: 0.72;
}

.tachyon-icon-picker__field {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-icon-picker__field > label {
    font-size: 12px;
    font-weight: 700;
}

.tachyon-icon-picker__field > input {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
}

.tachyon-icon-picker__presets-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-icon-picker__presets-label {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    opacity: 0.68;
}

.tachyon-icon-picker__chips-grid,
.tachyon-icon-picker__presets {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-icon-picker__chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    word-break: normal !important;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-icon-picker__chip:hover {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-icon-picker__chip-img {
    width: 14px;
    height: 14px;
    border-radius: 3px;
    object-fit: contain;
}

.tachyon-icon-picker__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 8px;
    padding-top: 10px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-icon-picker__footer > button:first-child:not(:last-child) {
    margin-right: auto;
}

.tachyon-icon-picker__footer-right {
    display: flex;
    align-items: center;
    gap: 8px;
}

.tachyon-routing-row__col {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    min-width: 0;
}

.tachyon-routing-row__col--num {
    align-items: flex-start;
}

.tachyon-routing-row__col-label {
    font-size: 9.5px;
    font-weight: 600;
    opacity: 0.58;
    text-transform: uppercase;
    letter-spacing: 0.02em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-routing-row__col-value {
    font-size: 12px;
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 3px;
    max-width: 100%;
}

.tachyon-routing-row__selector-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 12px;
    font-weight: 700;
    padding: 0;
    border-radius: 6px;
    background: transparent;
    border: none;
    color: inherit;
    width: auto;
    max-width: 100%;
    align-self: flex-start;
    text-align: left;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    word-break: normal !important;
}

.tachyon-routing-row__selector-pill > span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
}

.tachyon-routing-row__selector-pill.is-interactive {
    cursor: pointer;
    font-size: 11.5px;
    padding: 2px 9px;
    border-radius: 7px;
    background: rgba(139, 92, 246, 0.1);
    border: 1px solid rgba(139, 92, 246, 0.28);
    color: var(--primary-color-high, #7c3aed);
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-routing-row__selector-pill.is-interactive:hover {
    background: rgba(139, 92, 246, 0.18);
    border-color: var(--primary-color-high, #8b5cf6);
    color: var(--primary-color-high, #8b5cf6);
}

.tachyon-routing-row__selector-pill svg {
    width: 12px;
    height: 12px;
    opacity: 0.78;
    flex-shrink: 0;
}

.tachyon-routing-row__right {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    flex-shrink: 0;
}

.tachyon-routing-row__ping {
    display: inline-flex;
    align-items: center;
    padding: 3px 8px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
    border: 1px solid transparent;
    cursor: pointer;
    white-space: nowrap;
}

.tachyon-routing-row__ping--fast {
    background: rgba(16, 185, 129, 0.14);
    color: #10b981;
    border-color: rgba(16, 185, 129, 0.3);
}

.tachyon-routing-row__ping--medium {
    background: rgba(245, 158, 11, 0.14);
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.3);
}

.tachyon-routing-row__ping--slow {
    background: rgba(239, 68, 68, 0.14);
    color: #ef4444;
    border-color: rgba(239, 68, 68, 0.3);
}

.tachyon-routing-row__ping--neutral {
    background: var(--background-color-high, rgba(128, 128, 128, 0.1));
    color: inherit;
    border-color: var(--border-color-low, rgba(128, 128, 128, 0.22));
    opacity: 0.8;
}

.tachyon-routing-row__chevron {
    font-size: 18px;
    font-weight: 700;
    opacity: 0.55;
    transition: transform 0.16s ease, opacity 0.16s ease;
}

.tachyon-routing-row__chevron.is-selected {
    transform: rotate(90deg);
    opacity: 1;
    color: #b4a5f0;
}

/* Block 2: Узлы (Nodes Block) */
.tachyon-nodes-block__header-left,
.tachyon-nodes-block__header-right {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-nodes-block__section-tabs {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
}

.tachyon-nodes-block__section-tab {
    padding: 4px 11px;
    border: none;
    border-radius: 7px;
    background: transparent;
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.72;
}

.tachyon-nodes-block__section-tab.is-active {
    background: rgba(148, 130, 224, 0.16);
    color: #b4a5f0;
    opacity: 1;
    font-weight: 700;
    box-shadow: none;
}

.tachyon-nodes-block__autogroups {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-nodes-autogroup-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.24));
    font-size: 12.5px;
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-nodes-autogroup-pill:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-nodes-autogroup-pill.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-nodes-autogroup-pill__badge {
    font-size: 11px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 6px;
    background: rgba(148, 130, 224, 0.16);
    color: #b4a5f0;
}

.tachyon-nodes-autogroup-pill__info {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 2px;
    border: none;
    background: transparent;
    color: inherit;
    opacity: 0.72;
    cursor: pointer;
}

.tachyon-nodes-autogroup-pill__info:hover {
    opacity: 1;
}

.tachyon-nodes-autogroup-pill__info svg {
    width: 14px;
    height: 14px;
}

.tachyon-nodes-block__action-btn {
    display: inline-flex !important;
    align-items: center;
    gap: 6px;
    padding: 6px 12px !important;
    border-radius: 9px !important;
    font-size: 12.5px !important;
    font-weight: 600 !important;
}

.tachyon-nodes-subbar {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
    padding: 8px 12px;
    border-radius: 10px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
}

.tachyon-nodes-subbar__item {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
}

.tachyon-nodes-subbar__title {
    font-weight: 700;
}

.tachyon-nodes-subbar__fact {
    opacity: 0.78;
}

.tachyon-nodes-subbar__link {
    display: inline-flex;
    align-items: center;
    color: #b4a5f0;
}

.tachyon-nodes-subbar__link svg {
    width: 14px;
    height: 14px;
}

.tachyon-nodes-countries {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-nodes-country-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.tachyon-nodes-country-pill.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-nodes-country-pill__count {
    font-size: 10.5px;
    opacity: 0.7;
}

.tachyon-nodes-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 8px;
}

.tachyon-node-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 6px;
    padding: 10px 11px;
    border-radius: 11px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    box-sizing: border-box;
    min-width: 0;
    transition: border-color 0.14s ease, background-color 0.14s ease, transform 0.12s ease;
}

.tachyon-node-card.is-selectable {
    cursor: pointer;
}

.tachyon-node-card.is-selectable:hover {
    border-color: rgba(148, 130, 224, 0.42);
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
}

.tachyon-node-card.is-active {
    border-color: #9482e0;
    background: rgba(148, 130, 224, 0.1);
    box-shadow: inset 0 0 0 1px rgba(148, 130, 224, 0.28);
}

.tachyon-node-card__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    min-width: 0;
}

.tachyon-node-card__title {
    font-size: 13px;
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    flex: 1;
}

.tachyon-node-card__badges {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
}

.tachyon-node-card__prefix {
    font-size: 10.5px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 5px;
    cursor: pointer;
    white-space: nowrap;
}

.tachyon-node-card__copy-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 3px;
    border: none;
    border-radius: 5px;
    background: transparent;
    color: inherit;
    opacity: 0.6;
    cursor: pointer;
}

.tachyon-node-card__copy-btn:hover {
    opacity: 1;
    background: rgba(128, 128, 128, 0.15);
}

.tachyon-node-card__copy-btn svg {
    width: 14px;
    height: 14px;
}

.tachyon-node-card__mid {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
}

.tachyon-node-card__proto {
    font-size: 11px;
    font-weight: 600;
    opacity: 0.72;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-node-card__spark {
    flex-shrink: 0;
}

.tachyon-node-card__latency {
    border: none;
    background: transparent;
    padding: 2px 4px;
    border-radius: 5px;
    font-size: 12.5px;
    font-weight: 800;
    cursor: pointer;
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-node-card__latency:hover {
    background: rgba(128, 128, 128, 0.12);
}

.tachyon-node-card__latency--green {
    color: #10b981;
}

.tachyon-node-card__latency--amber {
    color: #f59e0b;
}

.tachyon-node-card__latency--red {
    color: #ef4444;
}

.tachyon-node-card__latency--neutral {
    color: inherit;
    opacity: 0.6;
}

.tachyon-node-card__footer {
    display: flex;
    flex-direction: column;
    gap: 5px;
}

.tachyon-node-card__status {
    font-size: 11px;
    font-weight: 600;
    opacity: 0.75;
}

.tachyon-node-card__status.is-active {
    color: #b4a5f0;
    font-weight: 700;
    opacity: 1;
}

.tachyon-node-card__status.is-alive {
    color: #10b981;
    opacity: 0.95;
}

.tachyon-node-card__status.is-dead {
    color: #ef4444;
    opacity: 0.95;
}

.tachyon-node-card__bar {
    width: 100%;
    height: 3px;
    border-radius: 999px;
    background: var(--border-color-low, rgba(128, 128, 128, 0.2));
    overflow: hidden;
}

.tachyon-node-card__bar-fill {
    height: 100%;
    border-radius: 999px;
}

.tachyon-node-card__bar-fill.is-green {
    background: #10b981;
}

.tachyon-node-card__bar-fill.is-amber {
    background: #f59e0b;
}

.tachyon-node-card__bar-fill.is-red {
    background: #ef4444;
}

.tachyon-node-card__bar-fill.is-neutral {
    background: rgba(128, 128, 128, 0.4);
}

@media (max-width: 820px) {
    .tachyon-kpi-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .tachyon-overview-split {
        grid-template-columns: 1fr;
    }
    .tachyon-routing-row {
        grid-template-columns: minmax(0, 1fr) auto;
    }
    .tachyon-routing-row__col,
    .tachyon-routing-row__status-col {
        display: none;
    }
    .tachyon-nodes-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
}

@media (max-width: 580px) {
    .tachyon-kpi-grid,
    .tachyon-nodes-grid {
        grid-template-columns: 1fr;
    }
}

/* ==========================================================================
   Connection Wizard Modal
   ========================================================================== */

.modal:has(.tachyon-wizard),
.cbi-modal:has(.tachyon-wizard) {
    width: min(94vw, 760px) !important;
    max-width: min(94vw, 760px) !important;
}

#modal_overlay button,
.cbi-modal button,
.tachyon-wizard button,
.tachyon-icon-picker button {
    word-break: normal !important;
    overflow-wrap: break-word;
}

.tachyon-wizard {
    display: flex;
    flex-direction: column;
    gap: 14px;
    max-width: 100%;
    width: 100%;
    box-sizing: border-box;
}

.tachyon-wizard__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 12px;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-wizard__brand {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    flex: 1 1 260px;
}

.tachyon-wizard__brand-text,
.tachyon-wizard__header-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
}

.tachyon-wizard__title {
    font-size: 16px;
    font-weight: 800;
    margin: 0;
    line-height: 1.25;
}

.tachyon-wizard__caption,
.tachyon-wizard__subtitle {
    font-size: 12px;
    opacity: 0.75;
    margin: 0;
    line-height: 1.35;
}

.tachyon-wizard__steps {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
}

.tachyon-wizard__step-pill,
.tachyon-wizard__step {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    font-weight: 600;
    padding: 5px 11px;
    border-radius: 999px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    opacity: 0.72;
}

.tachyon-wizard__step-pill.is-active,
.tachyon-wizard__step.is-active {
    background: rgba(148, 130, 224, 0.14);
    border-color: rgba(148, 130, 224, 0.38);
    color: #b4a5f0;
    opacity: 1;
    font-weight: 700;
}

.tachyon-wizard__step-pill.is-done {
    background: rgba(148, 130, 224, 0.08);
    border-color: rgba(148, 130, 224, 0.24);
    color: #9482e0;
    opacity: 0.95;
}

.tachyon-wizard__step-num {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    font-size: 11px;
    font-weight: 800;
    background: rgba(128, 128, 128, 0.18);
}

.tachyon-wizard__step-pill.is-active .tachyon-wizard__step-num {
    background: rgba(148, 130, 224, 0.28);
    color: #e2e8f0;
}

.tachyon-wizard__cards-2col,
.tachyon-wizard__direction-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
}

.tachyon-wizard__choice-card,
.tachyon-wizard__direction-card,
.tachyon-wizard__proto-card,
.tachyon-wizard__method-card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: flex-start;
    gap: 6px;
    padding: 13px 15px;
    border-radius: 11px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.24));
    background: var(--background-color-high, rgba(128, 128, 128, 0.03));
    color: inherit;
    text-align: left;
    cursor: pointer;
    width: 100%;
    height: auto !important;
    box-sizing: border-box;
    white-space: normal !important;
    word-break: normal !important;
    line-height: 1.35;
    transition: border-color 0.14s ease, background-color 0.14s ease, box-shadow 0.14s ease;
}

.tachyon-wizard__choice-card:hover,
.tachyon-wizard__direction-card:hover,
.tachyon-wizard__proto-card:hover,
.tachyon-wizard__method-card:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-wizard__choice-card.is-selected,
.tachyon-wizard__direction-card.is-selected,
.tachyon-wizard__proto-card.is-selected,
.tachyon-wizard__method-card.is-selected {
    border-color: #9482e0;
    background: rgba(148, 130, 224, 0.12);
    box-shadow: 0 0 0 1px rgba(148, 130, 224, 0.28);
}

.tachyon-wizard__method-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    width: 100%;
    gap: 8px;
}

.tachyon-wizard__choice-title,
.tachyon-wizard__direction-title,
.tachyon-wizard__proto-title,
.tachyon-wizard__method-title {
    font-size: 13.5px;
    font-weight: 700;
    line-height: 1.3;
    word-break: normal !important;
}

.tachyon-wizard__choice-desc,
.tachyon-wizard__direction-desc,
.tachyon-wizard__proto-desc,
.tachyon-wizard__method-desc {
    font-size: 11.5px;
    opacity: 0.76;
    line-height: 1.4;
    word-break: normal !important;
    white-space: normal !important;
}

.tachyon-wizard__section-title {
    font-size: 11.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    opacity: 0.72;
    margin-top: 2px;
}

.tachyon-wizard__proto-grid,
.tachyon-wizard__methods-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 9px;
    max-height: 320px;
    overflow-y: auto;
    padding-right: 4px;
}

.tachyon-wizard__choice-badge,
.tachyon-wizard__proto-badge,
.tachyon-wizard__method-badge {
    display: inline-flex;
    align-items: center;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 7px;
    border-radius: 5px;
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    white-space: nowrap !important;
    word-break: normal !important;
    flex-shrink: 0;
}

.tachyon-wizard__form,
.tachyon-wizard__form-box,
.tachyon-wizard__body {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.tachyon-wizard__form-grid,
.tachyon-wizard__row-2col {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
}

.tachyon-wizard__radio-row,
.tachyon-wizard__chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-wizard__pill-btn,
.tachyon-wizard__chip {
    padding: 6px 12px;
    border-radius: 999px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.24));
    background: transparent;
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    word-break: normal !important;
}

.tachyon-wizard__pill-btn.is-active,
.tachyon-wizard__chip.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-wizard__toggle-box {
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
}

.tachyon-wizard__checkbox-label {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    cursor: pointer;
}

.tachyon-wizard__checkbox-title {
    font-size: 13px;
    font-weight: 700;
}

.tachyon-wizard__checkbox-desc {
    font-size: 11px;
    opacity: 0.72;
}

.tachyon-wizard__field {
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-width: 0;
}

.tachyon-wizard__label {
    font-size: 12px;
    font-weight: 700;
}

.tachyon-wizard__input,
.tachyon-wizard__select,
.tachyon-wizard__textarea {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
}

.tachyon-wizard__new-section-box {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    background: var(--background-color-low, rgba(128, 128, 128, 0.04));
    margin-top: 4px;
}

.tachyon-wizard__checkbox {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    cursor: pointer;
}

.tachyon-wizard__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 8px;
    padding-top: 12px;
    margin-top: 4px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-wizard__footer > button:first-child:not(:last-child) {
    margin-right: auto;
}

.tachyon-wizard__footer-right {
    display: flex;
    align-items: center;
    gap: 8px;
}

/* ==========================================================================
   Pane Quick Action Toolbar + Modernized LuCI CBI Tables, Sub-Pills & Forms
   ========================================================================== */

/* Hide redundant section top sub-tab menu since Sidebar switches them directly */
#cbi-tachyon-section .tachyon-section-subtabs {
    display: none !important;
}

.tachyon-workspace-body {
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-width: 0;
    width: 100%;
}

.tachyon-pane-quickbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 12px;
    padding: 13px 16px;
    margin-bottom: 12px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-pane-quickbar__info {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
    flex: 1 1 280px;
}

.tachyon-pane-quickbar__title {
    font-size: 14px;
    font-weight: 800;
    line-height: 1.25;
}

.tachyon-pane-quickbar__desc {
    font-size: 12px;
    opacity: 0.72;
    line-height: 1.38;
}

.tachyon-pane-quickbar__actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-pane-quickbar__mode-hint {
    padding: 6px 11px;
    border-radius: 8px;
    border: 1px dashed var(--border-color-medium, rgba(128, 128, 128, 0.35));
    background: transparent;
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    opacity: 0.78;
    cursor: pointer;
    transition: opacity 0.14s ease, border-color 0.14s ease;
}

.tachyon-pane-quickbar__mode-hint:hover {
    opacity: 1;
    border-color: rgba(148, 130, 224, 0.42);
    color: #b4a5f0;
}

.tachyon-pane-quickbar__wizard-btn {
    padding: 6px 12px;
    border-radius: 8px;
    border: 1px solid rgba(148, 130, 224, 0.36);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-size: 12px;
    font-weight: 700;
    cursor: pointer;
    transition: background-color 0.14s ease, border-color 0.14s ease;
}

.tachyon-pane-quickbar__wizard-btn:hover {
    background: rgba(148, 130, 224, 0.22);
    border-color: rgba(148, 130, 224, 0.48);
}

/* Segmented Pill Sub-Navigation for Edit Modals & Section Inspector Modal */
.modal .cbi-tabmenu,
.cbi-modal .cbi-tabmenu {
    display: flex !important;
    flex-wrap: wrap;
    gap: 4px;
    padding: 4px !important;
    margin: 0 0 14px 0 !important;
    list-style: none !important;
    border-radius: 11px !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1)) !important;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2)) !important;
}

.modal .cbi-tabmenu > li,
.cbi-modal .cbi-tabmenu > li {
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    border-radius: 8px !important;
}

.modal .cbi-tabmenu > li > a,
.cbi-modal .cbi-tabmenu > li > a {
    display: inline-flex !important;
    align-items: center;
    padding: 6px 13px !important;
    border-radius: 8px !important;
    font-size: 12.5px !important;
    font-weight: 600 !important;
    text-decoration: none !important;
    color: inherit !important;
    opacity: 0.72;
    border: 1px solid transparent !important;
    background: transparent !important;
    transition: background-color 0.14s ease, opacity 0.14s ease, color 0.14s ease;
}

.modal .cbi-tabmenu > li > a:hover,
.cbi-modal .cbi-tabmenu > li > a:hover {
    opacity: 1;
    background: rgba(128, 128, 128, 0.08) !important;
}

.modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a {
    opacity: 1;
    font-weight: 700 !important;
    color: #b4a5f0 !important;
    background: rgba(148, 130, 224, 0.14) !important;
    border-color: rgba(148, 130, 224, 0.28) !important;
    box-shadow: none;
}

/* ==========================================================================
   Section Inspector Modal (Узлы и балансировщики + Условия и правила)
   ========================================================================== */

.modal:has(.tachyon-section-inspector-modal),
.cbi-modal:has(.tachyon-section-inspector-modal) {
    width: min(95vw, 960px) !important;
    max-width: min(95vw, 960px) !important;
}

.tachyon-section-inspector-modal {
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: 0;
    max-width: 100%;
    --dashboard-grid-columns: 2;
    --dashboard-grid-min-width: 240px;
}

@media (max-width: 640px) {
    .tachyon-section-inspector-modal {
        --dashboard-grid-columns: 1;
        --dashboard-grid-min-width: 180px;
    }
}

.tachyon-sec-modal__switcher {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    padding: 6px 8px;
    border-radius: 10px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
}

.tachyon-sec-modal__switch-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 28px;
    padding: 4px 12px;
    border-radius: 7px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-high, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    line-height: 1;
    margin: 0 !important;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-sec-modal__switch-pill:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-sec-modal__switch-pill.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-sec-modal__nodes-pane .tachyon_dashboard-page__outbound-section {
    margin: 0 !important;
    border-radius: 11px;
}

.tachyon-sec-modal__nodes-pane .tachyon_dashboard-page__outbound-section__collapse-icon {
    display: none !important;
}

.tachyon-sec-modal__nodes-pane .tachyon_dashboard-page__outbound-section__header-left {
    cursor: default !important;
}

.tachyon-sec-modal-tabs {
    width: fit-content !important;
    max-width: 100%;
    margin: 0 0 4px 0 !important;
}

.tachyon-sec-modal__conditions-pane {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.tachyon-sec-modal__body {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.tachyon-sec-modal__group {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 14px 16px;
    border-radius: 12px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-sec-modal__group-title {
    margin: 0;
    font-size: 12px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.82;
}

.tachyon-sec-modal__group-desc {
    font-size: 12px;
    opacity: 0.72;
}

.tachyon-sec-modal__card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 12px 14px;
    border-radius: 10px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    min-width: 0;
    max-width: 100%;
    box-sizing: border-box;
}

.tachyon-sec-modal__card.is-active {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.06);
}

.tachyon-sec-modal__card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px;
}

.tachyon-sec-modal__card-title-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    min-width: 0;
}

.tachyon-sec-modal__card-title {
    font-size: 13.5px;
    font-weight: 700;
    color: var(--text-color-high, inherit);
}

.tachyon-sec-modal__card-actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-sec-modal__badge-type {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 6px;
    font-size: 11px;
    font-weight: 700;
    background: rgba(148, 163, 184, 0.1);
    color: var(--text-color-high, #e2e8f0);
    border: 1px solid rgba(148, 163, 184, 0.22);
}

.tachyon-sec-modal__badge-type--neg {
    background: rgba(239, 68, 68, 0.14);
    color: #f87171;
    border-color: rgba(239, 68, 68, 0.3);
}

.tachyon-sec-modal__badge-active {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 6px;
    font-size: 11px;
    font-weight: 700;
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    border: 1px solid rgba(148, 130, 224, 0.3);
}

.tachyon-sec-modal__facts {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px 16px;
    font-size: 12px;
    padding-top: 2px;
}

.tachyon-sec-modal__fact {
    display: inline-flex;
    align-items: center;
    gap: 5px;
}

.tachyon-sec-modal__fact-k {
    font-size: 12px;
    opacity: 0.68;
}

.tachyon-sec-modal__chips,
.tachyon-sec-modal__rules-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    min-width: 0;
    max-width: 100%;
}

.tachyon-sec-modal__chip,
.tachyon-sec-modal__rule-chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 9px;
    border-radius: 6px;
    font-size: 11.5px;
    font-weight: 600;
    background: rgba(139, 92, 246, 0.1);
    color: var(--text-color-high, inherit);
    border: 1px solid rgba(139, 92, 246, 0.24);
    max-width: 100%;
    overflow-wrap: anywhere;
    word-break: break-word;
}

.tachyon-sec-modal__empty-hint,
.tachyon-sec-modal__empty {
    font-size: 12.5px;
    opacity: 0.72;
    padding: 4px 0;
}

.tachyon-sec-modal__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 8px;
    padding-top: 10px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

/* Modernized CBI Section Containers & Tables */
.tachyon-workspace-body .cbi-section {
    background: var(--background-color-high, rgba(128, 128, 128, 0.03));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 12px;
    padding: 12px 13px;
    margin-bottom: 12px;
    box-sizing: border-box;
    overflow: visible !important;
}

/* Dashboard, Diagnostic, Monitoring, Updates already render their own cards */
#cbi-tachyon-dashboard.cbi-section,
#cbi-tachyon-diagnostic.cbi-section,
#cbi-tachyon-monitoring.cbi-section,
#cbi-tachyon-updates.cbi-section,
#cbi-tachyon-section.cbi-section {
    background: transparent !important;
    border: none !important;
    padding: 0 !important;
}

.tachyon-workspace-body .cbi-section-table {
    width: 100%;
    border-collapse: separate;
    border-spacing: 0;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 10px;
    overflow: hidden;
    background: var(--background-color-high, rgba(128, 128, 128, 0.03));
    font-size: 12px;
}

.tachyon-workspace-body .cbi-section-table-titles th,
.tachyon-workspace-body .cbi-section-table-titles .cbi-section-table-cell {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.02em;
    opacity: 0.72;
    padding: 7px 6px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    line-height: 1.25;
}

.tachyon-workspace-body .cbi-section-table-row td,
.tachyon-workspace-body .cbi-section-table-row .cbi-section-table-cell {
    padding: 7px 6px;
    font-size: 12px;
    vertical-align: middle;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
}

.tachyon-workspace-body .cbi-section-table .cbi-section-actions .btn,
.tachyon-workspace-body .cbi-section-table .cbi-section-actions .cbi-button {
    padding: 3px 7px !important;
    font-size: 11px !important;
    min-height: 24px !important;
}

.tachyon-workspace-body .cbi-section-table-row:last-child td,
.tachyon-workspace-body .cbi-section-table-row:last-child .cbi-section-table-cell {
    border-bottom: none;
}

/* ==========================================================================
   Simple Mode (Обычный режим) — Clean "Set & Forget" View
   Hides expert tabs, legacy DPI tools (zapret/zapret2/byedpi), and low-level knobs
   ========================================================================== */

/* 1. Hide expert Settings sub-tabs in Simple Mode (AI/Watchdog internals) */
body[data-tachyon-ui-mode="simple"] #cbi-tachyon-settings .cbi-tabmenu > li[data-tab="ai"],
body[data-tachyon-ui-mode="simple"] .modal .cbi-tabmenu > li[data-tab="advanced"],
body[data-tachyon-ui-mode="simple"] .cbi-modal .cbi-tabmenu > li[data-tab="advanced"] {
    display: none !important;
}

/* ==========================================================================
   Unified Modal Chrome, Segmented Pill Tabs, Form Cards & Settings Lists
   ========================================================================== */

#modal_overlay {
    background: rgba(8, 13, 24, 0.62) !important;
    backdrop-filter: blur(6px);
    -webkit-backdrop-filter: blur(6px);
    padding: 68px 16px 32px 16px !important;
    box-sizing: border-box;
}

@media (max-width: 680px) {
    #modal_overlay {
        padding: 54px 10px 24px 10px !important;
    }
}

#modal_overlay > .modal,
.modal.cbi-modal,
.cbi-modal {
    background: var(--background-color-high, #ffffff) !important;
    color: var(--text-color-high, inherit) !important;
    border: 1px solid var(--border-color-medium, rgba(139, 92, 246, 0.26)) !important;
    border-radius: 16px !important;
    box-shadow: 0 22px 56px rgba(0, 0, 0, 0.34), 0 4px 18px rgba(139, 92, 246, 0.14) !important;
    padding: 18px 20px !important;
    margin-top: 12px !important;
    max-width: min(920px, 95vw) !important;
    width: 100% !important;
    box-sizing: border-box !important;
}

#modal_overlay > .modal > h4,
.modal.cbi-modal > h4,
.cbi-modal > h4 {
    margin: 0 0 14px 0 !important;
    padding: 0 0 11px 0 !important;
    font-size: 16px !important;
    font-weight: 800 !important;
    letter-spacing: -0.015em;
    color: var(--text-color-high, inherit) !important;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16)) !important;
    background: transparent !important;
}

#modal_overlay > .modal > h4:empty,
.modal.cbi-modal > h4:empty,
.cbi-modal > h4:empty {
    display: none !important;
}

/* Segmented Pill Tabmenu inside Modals */
#modal_overlay > .modal .cbi-tabmenu,
.modal.cbi-modal .cbi-tabmenu,
.cbi-modal .cbi-tabmenu {
    display: flex !important;
    flex-wrap: wrap !important;
    gap: 5px !important;
    padding: 5px !important;
    margin: 0 0 14px 0 !important;
    list-style: none !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08)) !important;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.18)) !important;
    border-radius: 11px !important;
}

#modal_overlay > .modal .cbi-tabmenu > li,
.modal.cbi-modal .cbi-tabmenu > li,
.cbi-modal .cbi-tabmenu > li {
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    list-style: none !important;
}

#modal_overlay > .modal .cbi-tabmenu > li > a,
.modal.cbi-modal .cbi-tabmenu > li > a,
.cbi-modal .cbi-tabmenu > li > a {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    padding: 6px 13px !important;
    margin: 0 !important;
    line-height: 1.25 !important;
    border-radius: 8px !important;
    font-size: 12.5px !important;
    font-weight: 700 !important;
    text-decoration: none !important;
    color: var(--text-color-medium, #64748b) !important;
    background: transparent !important;
    border: none !important;
    transition: background 0.15s ease, color 0.15s ease, box-shadow 0.15s ease !important;
}

#modal_overlay > .modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.modal.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a {
    background: rgba(148, 130, 224, 0.14) !important;
    color: #9c8be3 !important;
    border: 1px solid rgba(148, 130, 224, 0.28) !important;
    box-shadow: none !important;
}

/* Modal Form Rows & Workspace Form Rows */
.hidden,
#modal_overlay .hidden,
.cbi-modal .hidden,
.tachyon-workspace-body .hidden,
.cbi-value.hidden,
.cbi-tabmenu > li.hidden,
#modal_overlay > .modal .cbi-tabmenu > li.hidden,
.cbi-modal .cbi-tabmenu > li.hidden {
    display: none !important;
}

#modal_overlay > .modal [data-tab-title]:not([data-tab-active="true"]),
.cbi-modal [data-tab-title]:not([data-tab-active="true"]) {
    display: none !important;
}

#modal_overlay > .modal .cbi-section,
.cbi-modal .cbi-section {
    border: none !important;
    background: transparent !important;
    box-shadow: none !important;
    padding: 0 !important;
    margin: 0 !important;
}

#modal_overlay > .modal .cbi-value:not(.hidden),
.cbi-modal .cbi-value:not(.hidden),
.tachyon-workspace-body .cbi-section-node > .cbi-value:not(.hidden):not([id$="-_mount_node"]),
.tachyon-workspace-body .cbi-tabcontainer > [data-tab] > .cbi-value:not(.hidden):not([id$="-_mount_node"]) {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    gap: 8px 16px;
    padding: 10px 14px !important;
    margin: 0 0 8px 0 !important;
    border-radius: 11px !important;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.025)) !important;
    box-sizing: border-box;
}

#modal_overlay > .modal .cbi-value-field,
.cbi-modal .cbi-value-field {
    flex: 1 1 280px;
    min-width: 0;
    margin-left: 0 !important;
}

#modal_overlay > .modal .cbi-value-field > input[type="text"],
#modal_overlay > .modal .cbi-value-field > input[type="password"],
#modal_overlay > .modal .cbi-value-field > select,
#modal_overlay > .modal .cbi-value-field > div > input[type="text"],
#modal_overlay > .modal .cbi-value-field > div > input[type="password"],
#modal_overlay > .modal .cbi-value-field > div > select,
.cbi-modal .cbi-value-field > input[type="text"],
.cbi-modal .cbi-value-field > input[type="password"],
.cbi-modal .cbi-value-field > select,
.cbi-modal .cbi-value-field > div > input[type="text"],
.cbi-modal .cbi-value-field > div > input[type="password"],
.cbi-modal .cbi-value-field > div > select {
    width: 100%;
    max-width: 480px;
}

#modal_overlay > .modal .cbi-value-field textarea,
.cbi-modal .cbi-value-field textarea {
    width: 100% !important;
    max-width: 100% !important;
}

#modal_overlay > .modal .cbi-value-title,
.cbi-modal .cbi-value-title,
.tachyon-workspace-body .cbi-value-title {
    font-size: 13px !important;
    font-weight: 700 !important;
    color: var(--text-color-high, inherit) !important;
    line-height: 1.35;
}

#modal_overlay > .modal .cbi-value-description,
.cbi-modal .cbi-value-description,
.tachyon-workspace-body .cbi-value-description {
    font-size: 11.5px !important;
    line-height: 1.4 !important;
    color: var(--text-color-medium, #64748b) !important;
    margin-top: 4px !important;
}

/* Inputs, Selects, Textareas across Workspace and Modals */
.tachyon-workspace-body input[type="text"],
.tachyon-workspace-body input[type="password"],
.tachyon-workspace-body input[type="number"],
.tachyon-workspace-body select,
.tachyon-workspace-body textarea,
#modal_overlay > .modal input[type="text"],
#modal_overlay > .modal input[type="password"],
#modal_overlay > .modal input[type="number"],
#modal_overlay > .modal select,
#modal_overlay > .modal textarea {
    border-radius: 8px !important;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.28)) !important;
    padding: 6px 10px !important;
    font-size: 13px !important;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04)) !important;
    color: var(--text-color-high, inherit) !important;
    box-sizing: border-box;
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
}

.tachyon-workspace-body input[type="text"]:focus,
.tachyon-workspace-body input[type="password"]:focus,
.tachyon-workspace-body input[type="number"]:focus,
.tachyon-workspace-body select:focus,
.tachyon-workspace-body textarea:focus,
#modal_overlay > .modal input[type="text"]:focus,
#modal_overlay > .modal input[type="password"]:focus,
#modal_overlay > .modal input[type="number"]:focus,
#modal_overlay > .modal select:focus,
#modal_overlay > .modal textarea:focus {
    outline: none !important;
    border-color: #8b5cf6 !important;
    box-shadow: 0 0 0 3px rgba(139, 92, 246, 0.2) !important;
}

/* Modal Footers & Action Buttons */
#modal_overlay > .modal > .right,
#modal_overlay > .modal > .button-row,
#modal_overlay > .modal > .cbi-page-actions,
.cbi-modal > .right,
.cbi-modal > .button-row {
    display: flex !important;
    justify-content: flex-end !important;
    align-items: center !important;
    flex-wrap: wrap !important;
    gap: 8px !important;
    margin-top: 14px !important;
    padding-top: 12px !important;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16)) !important;
    text-align: right !important;
}

#modal_overlay > .modal .btn,
#modal_overlay > .modal .cbi-button,
.tachyon-workspace-body .cbi-section-create .cbi-button {
    border-radius: 8px !important;
    font-weight: 700 !important;
    font-size: 12.5px !important;
    padding: 6px 13px !important;
}

.tachyon-workspace-body .cbi-section-create {
    display: flex !important;
    align-items: center !important;
    flex-wrap: wrap !important;
    gap: 8px !important;
    padding: 10px 12px !important;
    margin-top: 6px !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.04)) !important;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14)) !important;
}

/* Settings Menu Order & Component Visibility Card Lists */
.tachyon-settings-list-card {
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 12px;
    overflow: hidden;
    margin-bottom: 8px;
    max-width: 680px;
    width: 100%;
    background: var(--background-color-high, rgba(128, 128, 128, 0.03));
    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.03);
}

.tachyon-settings-list-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.13));
    transition: background 0.14s ease, opacity 0.14s ease;
}

.tachyon-settings-list-row:last-child {
    border-bottom: none;
}

.tachyon-settings-list-row:hover {
    background: rgba(139, 92, 246, 0.04);
}

.tachyon-settings-list-row.is-hidden {
    opacity: 0.52;
    background: rgba(128, 128, 128, 0.03);
}

.tachyon-settings-group-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 999px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.02em;
    background: rgba(139, 92, 246, 0.12);
    color: #8b5cf6;
    border: 1px solid rgba(139, 92, 246, 0.24);
    margin-left: 6px;
    vertical-align: middle;
}

/* 2. Hide legacy DPI engines (zapret, zapret2, byedpi, wdtt, olcrtc) in Simple Mode dropdowns */
body[data-tachyon-ui-mode="simple"] option[value="zapret"],
body[data-tachyon-ui-mode="simple"] option[value="zapret2"],
body[data-tachyon-ui-mode="simple"] option[value="byedpi"],
body[data-tachyon-ui-mode="simple"] option[value="wdtt"],
body[data-tachyon-ui-mode="simple"] option[value="olcrtc"],
body[data-tachyon-ui-mode="simple"] li[data-value="zapret"],
body[data-tachyon-ui-mode="simple"] li[data-value="zapret2"],
body[data-tachyon-ui-mode="simple"] li[data-value="byedpi"],
body[data-tachyon-ui-mode="simple"] li[data-value="wdtt"],
body[data-tachyon-ui-mode="simple"] li[data-value="olcrtc"] {
    display: none !important;
}

/* 3. Hide expert low-level fields across Settings, Sections, and Outbounds in Simple Mode */
body[data-tachyon-ui-mode="simple"] [data-name="urltest_tolerance"],
body[data-tachyon-ui-mode="simple"] [data-name="urltest_idle_timeout"],
body[data-tachyon-ui-mode="simple"] [data-name="urltest_testing_url"],
body[data-tachyon-ui-mode="simple"] [data-name="passive_check"],
body[data-tachyon-ui-mode="simple"] [data-name="sticky_hash"],
body[data-tachyon-ui-mode="simple"] [data-name="custom_json"],
body[data-tachyon-ui-mode="simple"] [data-name="desync_fooling"],
body[data-tachyon-ui-mode="simple"] [data-name="desync_ttl"],
body[data-tachyon-ui-mode="simple"] [data-name="desync_split_pos"],
body[data-tachyon-ui-mode="simple"] [data-name="desync_repeats"],
/* Settings -> DNS expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="_dns_speed_test"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_upstream_mode"],
body[data-tachyon-ui-mode="simple"] [data-name="bootstrap_dns_server"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_fallback_server"],
body[data-tachyon-ui-mode="simple"] [data-name="fallback_wan_main"],
body[data-tachyon-ui-mode="simple"] [data-name="fallback_wan_bootstrap"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_check_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_recovery_check_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_check_timeout"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_failure_threshold"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_recovery_threshold"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_rewrite_ttl"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_cache_size"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_strategy"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_detour_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_detour_section"],
/* Settings -> Network expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="tun_interface"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_stack"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_auto_route"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_mtu"],
body[data-tachyon-ui-mode="simple"] [data-name="enable_output_network_interface"],
body[data-tachyon-ui-mode="simple"] [data-name="output_network_interface"],
body[data-tachyon-ui-mode="simple"] [data-name="enable_badwan_interface_monitoring"],
body[data-tachyon-ui-mode="simple"] [data-name="badwan_monitored_interfaces"],
body[data-tachyon-ui-mode="simple"] [data-name="badwan_reload_delay"],
/* Settings -> Services & Updates & System expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="enable_yacd"],
body[data-tachyon-ui-mode="simple"] [data-name="enable_yacd_wan_access"],
body[data-tachyon-ui-mode="simple"] [data-name="yacd_secret_key"],
body[data-tachyon-ui-mode="simple"] [data-name="p2p_ports"],
body[data-tachyon-ui-mode="simple"] [data-name="github_token"],
body[data-tachyon-ui-mode="simple"] [data-name="update_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="download_all_presets"],
body[data-tachyon-ui-mode="simple"] [data-name="component_update_check_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="component_auto_update_mode"],
body[data-tachyon-ui-mode="simple"] [data-name="component_auto_update_time"],
body[data-tachyon-ui-mode="simple"] [data-name="component_auto_update_targets"],
body[data-tachyon-ui-mode="simple"] [data-name="component_backup_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="latency_test_url"],
body[data-tachyon-ui-mode="simple"] [data-name="latency_test_mode"],
body[data-tachyon-ui-mode="simple"] [data-name="download_lists_via_proxy"],
body[data-tachyon-ui-mode="simple"] [data-name="download_lists_via_proxy_section"],
body[data-tachyon-ui-mode="simple"] [data-name="download_components_via_proxy"],
body[data-tachyon-ui-mode="simple"] [data-name="download_components_via_proxy_section"],
body[data-tachyon-ui-mode="simple"] [data-name="dont_touch_dhcp"],
body[data-tachyon-ui-mode="simple"] [data-name="section_failover_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="section_failover_threshold"],
body[data-tachyon-ui-mode="simple"] [data-name="config_path"],
body[data-tachyon-ui-mode="simple"] [data-name="cache_path"],
body[data-tachyon-ui-mode="simple"] [data-name="log_level"],
body[data-tachyon-ui-mode="simple"] [data-name="webrtc_leak_protect"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_doq_ech"],
body[data-tachyon-ui-mode="simple"] [data-name="qos_priority_engine"],
body[data-tachyon-ui-mode="simple"] [data-name="warp_proxy_section"],
/* Section Edit Modal expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="balancer_refs"],
body[data-tachyon-ui-mode="simple"] [data-name="outbound_group_refs"],
body[data-tachyon-ui-mode="simple"] [data-name="section_selection_mode"],
body[data-tachyon-ui-mode="simple"] [data-name="section_health_url"],
body[data-tachyon-ui-mode="simple"] [data-name="section_filter_mode"],
body[data-tachyon-ui-mode="simple"] [data-name="outbound_detour_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="outbound_detour_section"],
body[data-tachyon-ui-mode="simple"] [data-name="sort_by_latency"],
body[data-tachyon-ui-mode="simple"] [data-name="packet_encoding"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_urls"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_timeout"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_threshold"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_recover_threshold"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_cooldown"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_check_direct"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_check_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_recover_interval"],
body[data-tachyon-ui-mode="simple"] [data-name="fail_policy_expected_status"],
body[data-tachyon-ui-mode="simple"] [data-name="mixed_proxy_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="mixed_proxy_port"],
body[data-tachyon-ui-mode="simple"] [data-name="mixed_proxy_auth_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="mixed_proxy_username"],
body[data-tachyon-ui-mode="simple"] [data-name="mixed_proxy_password"],
body[data-tachyon-ui-mode="simple"] [data-name="resolve_real_ip_for_routing"],
body[data-tachyon-ui-mode="simple"] [data-name="condition_refs"],
body[data-tachyon-ui-mode="simple"] [data-name="condition_operator"],
body[data-tachyon-ui-mode="simple"] [data-name="condition_expression"],
body[data-tachyon-ui-mode="simple"] [data-name="user_domains"],
body[data-tachyon-ui-mode="simple"] [data-name="community_subnets"],
body[data-tachyon-ui-mode="simple"] [data-name="rule_set"],
body[data-tachyon-ui-mode="simple"] [data-name="_dns_rule_set"],
body[data-tachyon-ui-mode="simple"] [data-name="domain_ip_lists"],
body[data-tachyon-ui-mode="simple"] [data-name="_dns_domain_ip_lists"],
body[data-tachyon-ui-mode="simple"] [data-name="global_rules"],
body[data-tachyon-ui-mode="simple"] [data-name="routed_dns_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="routed_dns_type"],
body[data-tachyon-ui-mode="simple"] [data-name="routed_dns_server"],
body[data-tachyon-ui-mode="simple"] [data-name="ports"],
body[data-tachyon-ui-mode="simple"] [data-name="dscp"],
body[data-tachyon-ui-mode="simple"] [data-name="excluded_protocol"],
body[data-tachyon-ui-mode="simple"] [data-name="protocol"],
/* Outbound Source modal expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="prefix_nodes"],
body[data-tachyon-ui-mode="simple"] [data-name="node_prefix"],
body[data-tachyon-ui-mode="simple"] [data-name="node_prefix_bg"],
body[data-tachyon-ui-mode="simple"] [data-name="node_prefix_color"],
body[data-tachyon-ui-mode="simple"] [data-name="_prefix_color_presets"] {
    display: none !important;
}

@media (max-width: 1080px) {
    .tachyon-kpi-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .tachyon-overview-split {
        grid-template-columns: 1fr;
    }
}

.tachyon-sidebar__mobile-toggle {
    display: none;
}

@media (max-width: 780px) {
    .tachyon-shell-layout,
    .tachyon-shell-layout[data-sidebar-pos="right"],
    #cbi-tachyon[data-sidebar-pos="right"] > .tachyon-shell-layout {
        flex-direction: column;
    }
    .tachyon-sidebar,
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar {
        width: 100% !important;
        min-width: 0 !important;
        position: relative !important;
        top: 0 !important;
        max-height: none !important;
        padding: 8px 12px !important;
        overflow: visible !important;
        z-index: 900;
    }
    .tachyon-sidebar__brand,
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand {
        flex-direction: row !important;
        justify-content: space-between !important;
        padding: 2px 4px !important;
        margin-bottom: 0 !important;
        border-bottom: none !important;
        width: 100% !important;
    }
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text {
        display: flex !important;
    }
    .tachyon-sidebar__collapse-btn {
        display: none !important;
    }
    .tachyon-sidebar__mobile-toggle {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        padding: 6px 11px;
        border-radius: 9px;
        border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.28));
        background: var(--background-color-low, rgba(128, 128, 128, 0.12));
        color: inherit;
        font-size: 12.5px;
        font-weight: 700;
        cursor: pointer;
        max-width: 62%;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
    }
    .tachyon-sidebar__mobile-toggle-label {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__nav,
    .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__footer {
        display: none !important;
    }
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav {
        display: flex !important;
        position: absolute;
        top: calc(100% + 6px);
        left: 0;
        right: 0;
        z-index: 950;
        padding: 10px;
        border-radius: 14px;
        background: var(--background-color-high, #1e293b);
        border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.32));
        box-shadow: 0 14px 34px rgba(0, 0, 0, 0.42);
        max-height: 72vh;
        overflow-y: auto;
        box-sizing: border-box;
    }
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__footer {
        display: none !important;
    }
    #view > .cbi-page-actions,
    #cbi-tachyon ~ .cbi-page-actions {
        margin-left: 0 !important;
        margin-right: 0 !important;
    }
    .tachyon-kpi-grid,
    .tachyon-wizard__cards-2col,
    .tachyon-wizard__direction-grid,
    .tachyon-wizard__methods-grid,
    .tachyon-wizard__proto-grid,
    .tachyon-wizard__row-2col,
    .tachyon-wizard__form-grid {
        grid-template-columns: 1fr;
    }
    .tachyon_dashboard-page__content > .tachyon-dashboard-widget-slot--half {
        grid-column: 1 / -1;
    }
}

/* ==========================================================================
   Dashboard Presets Toolbar, Widget Views & Configurator
   ========================================================================== */

.tachyon-dash-preset-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
    padding: 8px 12px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-dash-preset-toolbar__left {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    min-width: 0;
}

.tachyon-dash-preset-toolbar__label {
    font-size: 11px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.68;
    white-space: nowrap;
}

.tachyon-dash-preset-toolbar__pills {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-dash-preset-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-dash-preset-pill:hover {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-dash-preset-pill.is-active {
    border-color: rgba(148, 130, 224, 0.42);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-dash-preset-toolbar__customize-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: 9px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.28));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    color: inherit;
    font-size: 12px;
    font-weight: 700;
    cursor: pointer;
    white-space: nowrap;
}

.tachyon-dash-preset-toolbar__customize-btn:hover {
    border-color: rgba(148, 130, 224, 0.42);
    color: #b4a5f0;
}

/* Auto-full span for unpaired half-width widgets */
.tachyon-dashboard-widget-slot--auto-full {
    grid-column: 1 / -1 !important;
}

/* KPI Alternative Views */
.tachyon-kpi-strip {
    grid-column: 1 / -1;
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    padding: 10px 12px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

@media (max-width: 900px) {
    .tachyon-kpi-strip {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
}

.tachyon-kpi-strip__item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
    min-width: 0;
}

.tachyon-kpi-strip__icon {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--background-color-high, rgba(128, 128, 128, 0.08));
    flex-shrink: 0;
}

.tachyon-kpi-strip__content {
    display: flex;
    flex-direction: column;
    gap: 3px;
    flex: 1;
    min-width: 0;
}

.tachyon-kpi-strip__head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
}

.tachyon-kpi-strip__label {
    font-size: 10.5px;
    font-weight: 700;
    opacity: 0.72;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-strip__val {
    font-size: 14.5px;
    font-weight: 800;
    white-space: nowrap;
}

.tachyon-kpi-strip__sub {
    font-size: 10.5px;
    opacity: 0.65;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-card--stat-pill {
    position: relative;
    display: flex !important;
    flex-direction: row !important;
    align-items: stretch !important;
    gap: 12px !important;
    padding: 12px 14px !important;
    border-radius: 13px !important;
    overflow: hidden;
}

.tachyon-kpi-stat-pill__accent {
    width: 4px;
    border-radius: 999px;
    flex-shrink: 0;
}

.tachyon-kpi-stat-pill__body {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 5px;
    flex: 1;
    min-width: 0;
}

.tachyon-kpi-stat-pill__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    width: 100%;
}

.tachyon-kpi-stat-pill__value {
    font-size: 20px;
    font-weight: 800;
    line-height: 1.15;
    letter-spacing: -0.02em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-card--telemetry {
    display: flex !important;
    flex-direction: column !important;
    justify-content: space-between !important;
    gap: 7px !important;
    padding: 12px 14px !important;
}

.tachyon-kpi-telemetry__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-kpi-telemetry__label {
    font-size: 10.5px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.72;
}

.tachyon-kpi-telemetry__pulse {
    width: 8px;
    height: 8px;
    border-radius: 999px;
    flex-shrink: 0;
}

.tachyon-kpi-telemetry__val {
    font-size: 19px;
    font-weight: 800;
    line-height: 1.15;
}

.tachyon-kpi-telemetry__bar {
    height: 5px;
    border-radius: 999px;
    background: var(--border-color-low, rgba(128, 128, 128, 0.2));
    overflow: hidden;
}

.tachyon-kpi-telemetry__bar-fill {
    height: 100%;
    border-radius: 999px;
    transition: width 0.25s ease;
}

.tachyon-kpi-telemetry__sub {
    font-size: 10.5px;
    opacity: 0.65;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-minimal-counters {
    grid-column: 1 / -1;
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0;
    padding: 10px 6px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.03));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.2));
}

@media (max-width: 900px) {
    .tachyon-kpi-minimal-counters {
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 8px;
    }
}

.tachyon-kpi-minimal-counters__item {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 4px 16px;
    border-right: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    min-width: 0;
}

.tachyon-kpi-minimal-counters__item:last-child {
    border-right: none;
}

.tachyon-kpi-minimal-counters__label {
    font-size: 10px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    opacity: 0.65;
}

.tachyon-kpi-minimal-counters__val {
    font-size: 21px;
    font-weight: 800;
    line-height: 1.15;
    letter-spacing: -0.02em;
}

.tachyon-kpi-minimal-counters__sub {
    font-size: 10.5px;
    opacity: 0.62;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Routing Sections Alternative Views (Bento Cards, Compact Tiles, Protocol Matrix) */
.tachyon-routing-sections-list--cards {
    display: grid !important;
    grid-template-columns: repeat(auto-fill, minmax(290px, 1fr));
    gap: 10px;
}

.tachyon-routing-bento-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    cursor: pointer;
    transition: border-color 0.14s ease, transform 0.12s ease;
    box-sizing: border-box;
}

.tachyon-routing-bento-card:hover {
    border-color: rgba(148, 130, 224, 0.42);
    transform: translateY(-1px);
}

.tachyon-routing-bento-card.is-selected {
    border-color: #9482e0;
    background: rgba(148, 130, 224, 0.08);
}

.tachyon-routing-bento-card__head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 10px;
}

.tachyon-routing-bento-card__head-main {
    display: flex;
    flex-direction: column;
    gap: 3px;
    flex: 1;
    min-width: 0;
}

.tachyon-routing-bento-card__body {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px 12px;
    padding: 8px 10px;
    border-radius: 8px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.05));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.12));
}

.tachyon-routing-bento-card__field {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
}

.tachyon-routing-bento-card__foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding-top: 6px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.15));
    font-size: 11.5px;
}

.tachyon-routing-bento-card__metric {
    display: inline-flex;
    align-items: baseline;
    gap: 5px;
    min-width: 0;
}

.tachyon-routing-sections-list--tiles {
    display: grid !important;
    grid-template-columns: repeat(auto-fill, minmax(235px, 1fr));
    gap: 8px;
}

.tachyon-routing-compact-tile {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 12px;
    border-radius: 10px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    cursor: pointer;
    transition: border-color 0.14s ease;
    box-sizing: border-box;
}

.tachyon-routing-compact-tile:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-routing-compact-tile.is-selected {
    border-color: #9482e0;
    background: rgba(148, 130, 224, 0.08);
}

.tachyon-routing-compact-tile__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
}

.tachyon-routing-compact-tile__titles {
    display: flex;
    flex-direction: column;
    gap: 3px;
    flex: 1;
    min-width: 0;
}

.tachyon-routing-compact-tile__badges {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
}

.tachyon-routing-compact-tile__bottom {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding-top: 6px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
    font-size: 11.5px;
}

.tachyon-routing-compact-tile__server {
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
    flex: 1;
}

.tachyon-routing-compact-tile__stat {
    font-weight: 700;
    opacity: 0.8;
    white-space: nowrap;
}

.tachyon-routing-sections-list--matrix {
    display: grid !important;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 8px;
}

.tachyon-routing-matrix-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 14px;
    border-radius: 11px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    cursor: pointer;
    transition: border-color 0.14s ease;
    box-sizing: border-box;
}

.tachyon-routing-matrix-card:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-routing-matrix-card__left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
}

.tachyon-routing-matrix-card__info {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
    flex: 1;
}

.tachyon-routing-matrix-card__node {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11.5px;
    opacity: 0.82;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-routing-matrix-card__sep {
    opacity: 0.45;
}

.tachyon-routing-matrix-card__sel {
    opacity: 0.75;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-routing-matrix-card__right {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
}

.tachyon-routing-matrix-card__stats {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
    font-size: 11px;
}

.tachyon-routing-matrix-card__traffic {
    font-size: 12.5px;
    font-weight: 800;
}

.tachyon-routing-matrix-card__conns {
    opacity: 0.68;
}

/* Traffic Monitor Alternative Views (Gauges & Dual Telemetry) */
.tachyon-traffic-gauges {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    height: 100%;
    align-items: stretch;
}

@media (max-width: 640px) {
    .tachyon-traffic-gauges {
        grid-template-columns: 1fr;
    }
}

.tachyon-traffic-gauge-box {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 8px;
    padding: 12px 14px;
    border-radius: 10px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
}

.tachyon-traffic-gauge-box__top {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-traffic-gauge-box__label {
    font-size: 11px;
    font-weight: 700;
    opacity: 0.76;
}

.tachyon-traffic-gauge-box__val {
    font-size: 17px;
    font-weight: 800;
    white-space: nowrap;
}

.tachyon-traffic-gauge-box__val.is-down {
    color: #8b5cf6;
}

.tachyon-traffic-gauge-box__val.is-up {
    color: #10b981;
}

.tachyon-traffic-gauge-bar {
    height: 8px;
    border-radius: 999px;
    background: var(--border-color-low, rgba(128, 128, 128, 0.22));
    overflow: hidden;
}

.tachyon-traffic-gauge-bar__fill {
    height: 100%;
    border-radius: 999px;
    transition: width 0.25s ease;
}

.tachyon-traffic-gauge-bar__fill.is-down {
    background: linear-gradient(90deg, #7c3aed, #a855f7);
}

.tachyon-traffic-gauge-bar__fill.is-up {
    background: linear-gradient(90deg, #059669, #34d399);
}

.tachyon-traffic-gauge-box__foot {
    font-size: 11px;
    opacity: 0.68;
}

.tachyon-traffic-dual-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    flex: 1;
}

.tachyon-traffic-dual-box {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 6px;
    padding: 12px 14px;
    border-radius: 11px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-traffic-dual-box.is-down {
    border-left: 3px solid #8b5cf6;
}

.tachyon-traffic-dual-box.is-up {
    border-left: 3px solid #10b981;
}

.tachyon-traffic-dual-box__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-traffic-dual-box__tag {
    font-size: 10.5px;
    font-weight: 800;
    letter-spacing: 0.04em;
}

.tachyon-traffic-dual-box__tag.is-down {
    color: #8b5cf6;
}

.tachyon-traffic-dual-box__tag.is-up {
    color: #10b981;
}

.tachyon-traffic-dual-box__value {
    font-size: 20px;
    font-weight: 800;
    letter-spacing: -0.02em;
}

.tachyon-traffic-dual-box__sub {
    font-size: 11px;
    opacity: 0.68;
}

/* System Status Alternative Views */
.tachyon-system-tiles-card,
.tachyon-system-hud-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    height: 100%;
    box-sizing: border-box;
}

.tachyon-system-tiles-card__head,
.tachyon-system-hud-card__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-system-hud-card__title-wrap {
    display: flex;
    align-items: center;
    gap: 8px;
}

.tachyon-system-hud-card__status-pill {
    font-size: 10px;
    font-weight: 800;
    padding: 2px 8px;
    border-radius: 999px;
    letter-spacing: 0.05em;
}

.tachyon-system-hud-card__status-pill.is-online {
    background: rgba(16, 185, 129, 0.16);
    color: #10b981;
}

.tachyon-system-hud-card__status-pill.is-offline {
    background: rgba(239, 68, 68, 0.16);
    color: #ef4444;
}

.tachyon-system-tiles-grid,
.tachyon-system-hud-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
    flex: 1;
}

.tachyon-system-tile,
.tachyon-system-hud-cell {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 4px;
    padding: 9px 11px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    min-width: 0;
}

.tachyon-system-hud-cell.is-accent-1 {
    border-left: 3px solid #8b5cf6;
}
.tachyon-system-hud-cell.is-accent-2 {
    border-left: 3px solid #10b981;
}
.tachyon-system-hud-cell.is-accent-3 {
    border-left: 3px solid #8b5cf6;
}
.tachyon-system-hud-cell.is-accent-4 {
    border-left: 3px solid #f59e0b;
}

.tachyon-system-tile__label,
.tachyon-system-hud-cell__label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    opacity: 0.68;
}

.tachyon-system-tile__val,
.tachyon-system-hud-cell__val {
    font-size: 13px;
    font-weight: 700;
    display: flex;
    align-items: center;
    gap: 6px;
}

.tachyon-system-banner-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px 16px;
    padding: 12px 16px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-system-banner-card__left {
    display: flex;
    align-items: center;
    gap: 8px;
}

.tachyon-system-banner-card__title {
    font-size: 12px;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.82;
}

.tachyon-system-banner-card__items {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px 14px;
}

.tachyon-system-banner-card__item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 11px;
    border-radius: 999px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.07));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
}

.tachyon-system-banner-card__key {
    font-size: 11px;
    font-weight: 700;
    opacity: 0.68;
}

.tachyon-system-banner-card__val {
    font-weight: 700;
    display: inline-flex;
    align-items: center;
    gap: 5px;
}

/* Router Services Alternative Views */
.tachyon-router-services-cards-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px 14px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-router-services-cards-grid,
.tachyon-router-services-resource-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(195px, 1fr));
    gap: 8px;
}

.tachyon-router-service-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 8px 11px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
}

.tachyon-router-service-card__top {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-weight: 700;
}

.tachyon-router-service-card__bottom {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-router-service-res-card {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 9px 12px;
    border-radius: 9px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
}

.tachyon-router-service-res-card__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-router-service-res-card__bar {
    height: 4px;
    border-radius: 999px;
    background: var(--border-color-low, rgba(128, 128, 128, 0.2));
    overflow: hidden;
}

.tachyon-router-service-res-card__bar-fill {
    height: 100%;
    border-radius: 999px;
    background: linear-gradient(90deg, #10b981, #8b5cf6);
}

/* Active Clients & Inbounds Alternative Views + Half-Width Responsiveness */
.tachyon-client-cards-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 8px;
    padding: 4px 0;
}

.tachyon-client-cards-grid .tachyon-client-row {
    flex-direction: column;
    align-items: flex-start;
    gap: 8px;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
}

.tachyon-client-cards-grid .tachyon-client-row__info {
    width: 100%;
    flex-wrap: wrap;
}

.tachyon-client-cards-grid .tachyon-client-row__traffic {
    width: 100%;
    justify-content: flex-start;
}

.tachyon-dashboard-widget-slot--half .tachyon-client-row__name-badge {
    flex: 0 1 135px !important;
    max-width: 135px !important;
}

.tachyon-dashboard-widget-slot--half .tachyon-client-row__ip {
    flex: 0 1 105px !important;
}

.tachyon-inbounds-chip-grid--compact {
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)) !important;
    gap: 6px !important;
}

.tachyon-inbounds-chip-grid--compact .tachyon-inbound-card {
    padding: 7px 10px !important;
}

.tachyon-inbounds-chip-grid--matrix {
    display: flex !important;
    flex-direction: column !important;
    gap: 6px !important;
}

.tachyon-inbounds-chip-grid--matrix .tachyon-inbound-card {
    display: flex !important;
    flex-direction: row !important;
    align-items: center !important;
    justify-content: space-between !important;
    padding: 8px 12px !important;
}

/* Dashboard Visual 2-Column Layout Editor (Settings & Modal) */
.tachyon-dash-editor {
    display: flex;
    flex-direction: column;
    gap: 16px;
    width: 100%;
    box-sizing: border-box;
}

.tachyon-dash-editor__section {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.tachyon-dash-editor__section-head {
    display: flex;
    flex-direction: column;
    gap: 3px;
}

.tachyon-dash-editor__section-title {
    font-size: 13.5px;
    font-weight: 800;
}

.tachyon-dash-editor__section-sub {
    font-size: 12px;
    opacity: 0.72;
}

.tachyon-dash-editor__presets-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(185px, 1fr));
    gap: 8px;
}

.tachyon-dash-preset-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 6px;
    padding: 10px 12px;
    border-radius: 11px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
    color: inherit;
    text-align: left;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-dash-preset-card:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-dash-preset-card.is-selected,
.tachyon-dash-preset-card.is-active {
    border-color: #9482e0;
    background: rgba(148, 130, 224, 0.11);
    box-shadow: 0 0 0 1px rgba(148, 130, 224, 0.32);
}

.tachyon-dash-preset-card__top {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
}

.tachyon-dash-preset-card__icon {
    font-size: 18px;
}

.tachyon-dash-preset-card__titles {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex: 1;
    min-width: 0;
}

.tachyon-dash-preset-card__title {
    font-size: 12.5px;
    font-weight: 800;
}

.tachyon-dash-preset-card__badge {
    align-self: flex-start;
    font-size: 9.5px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 999px;
    background: rgba(148, 130, 224, 0.16);
    color: #b4a5f0;
}

.tachyon-dash-preset-card__preview {
    display: grid;
    grid-template-columns: repeat(2, 14px);
    gap: 2px;
    padding: 3px;
    border-radius: 5px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.1));
}

.tachyon-dash-preset-card__preview-block {
    height: 5px;
    border-radius: 2px;
    background: #9482e0;
    opacity: 0.75;
}

.tachyon-dash-preset-card__preview-block.is-full {
    grid-column: 1 / -1;
}

.tachyon-dash-preset-card__preview-block.is-half {
    grid-column: span 1;
}

.tachyon-dash-preset-card__desc {
    font-size: 11px;
    opacity: 0.72;
    line-height: 1.35;
}

/* 2-Column Visual Canvas Grid */
.tachyon-visual-canvas-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    padding: 12px;
    border-radius: 14px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px dashed var(--border-color-medium, rgba(128, 128, 128, 0.3));
    box-sizing: border-box;
}

@media (max-width: 820px) {
    .tachyon-visual-canvas-grid {
        grid-template-columns: 1fr;
    }
}

.tachyon-visual-slot-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    padding: 11px 13px;
    border-radius: 11px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.07));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24));
    transition: border-color 0.14s ease, transform 0.12s ease, box-shadow 0.14s ease;
    box-sizing: border-box;
}

.tachyon-visual-slot-card.is-full,
.tachyon-visual-slot-card.is-auto-full {
    grid-column: 1 / -1;
}

.tachyon-visual-slot-card.is-half {
    grid-column: span 1;
}

.tachyon-visual-slot-card:hover {
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-visual-slot-card.is-dragging {
    opacity: 0.45;
    transform: scale(0.99);
}

.tachyon-visual-slot-card.is-drag-over {
    border-color: #9482e0;
    box-shadow: 0 0 0 2px rgba(148, 130, 224, 0.28);
}

.tachyon-visual-slot-card.is-disabled {
    opacity: 0.62;
    border-style: dashed;
}

.tachyon-visual-slot-card__head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-visual-slot-card__drag-handle {
    cursor: grab;
    font-size: 15px;
    opacity: 0.55;
    padding: 2px 4px;
    user-select: none;
}

.tachyon-visual-slot-card__title-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-visual-slot-card__span-badge {
    font-size: 10px;
    font-weight: 700;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.12));
    opacity: 0.85;
}

.tachyon-visual-slot-card__controls {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-left: auto;
}

.tachyon-visual-slot-card__views-wrap {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
}

.tachyon-dash-widget-row__check {
    width: 24px;
    height: 24px;
    border-radius: 6px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.3));
    background: transparent;
    color: inherit;
    font-weight: 800;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

.tachyon-dash-widget-row__check.is-checked {
    background: rgba(148, 130, 224, 0.16);
    border-color: rgba(148, 130, 224, 0.42);
    color: #b4a5f0;
}

.tachyon-dash-widget-row__icon {
    font-size: 17px;
}

.tachyon-dash-widget-row__info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex: 1;
    min-width: 160px;
}

.tachyon-dash-widget-row__title {
    font-size: 13px;
    font-weight: 800;
}

.tachyon-dash-widget-row__desc {
    font-size: 11px;
    opacity: 0.68;
}

.tachyon-dash-widget-row__views-label {
    font-size: 11px;
    font-weight: 700;
    opacity: 0.7;
}

.tachyon-dash-widget-row__views,
.tachyon-dash-widget-row__width-group {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 4px;
    padding: 3px;
    border-radius: 8px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.08));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-dash-widget-row__order {
    display: inline-flex;
    align-items: center;
    gap: 3px;
}

.tachyon-dash-order-btn {
    padding: 2px 6px !important;
    font-size: 10px !important;
    min-height: 24px !important;
    line-height: 1 !important;
}

.tachyon-dash-view-chip,
.tachyon-dash-width-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 8px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: inherit;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.78;
}

.tachyon-dash-view-chip:hover,
.tachyon-dash-width-btn:hover {
    opacity: 1;
    background: rgba(128, 128, 128, 0.1);
}

.tachyon-dash-view-chip.is-active,
.tachyon-dash-width-btn.is-active {
    background: rgba(148, 130, 224, 0.16);
    color: #b4a5f0;
    opacity: 1;
    font-weight: 700;
}

.tachyon-view-mini-schematic {
    display: inline-grid;
    gap: 1.5px;
    width: 14px;
    height: 10px;
    vertical-align: middle;
}

.tachyon-view-mini-schematic i {
    display: block;
    background: currentColor;
    border-radius: 1px;
    opacity: 0.85;
}

.tachyon-view-mini-schematic--grid4 {
    grid-template-columns: repeat(4, 1fr);
}

.tachyon-view-mini-schematic--strip {
    grid-template-columns: repeat(3, 1fr);
    align-items: center;
}

.tachyon-view-mini-schematic--strip i {
    height: 4px;
}

.tachyon-view-mini-schematic--rows {
    grid-template-rows: repeat(3, 1fr);
}

.tachyon-view-mini-schematic--bars {
    grid-template-columns: repeat(4, 1fr);
    align-items: end;
}

.tachyon-view-mini-schematic--bars i:nth-child(1) { height: 45%; }
.tachyon-view-mini-schematic--bars i:nth-child(2) { height: 85%; }
.tachyon-view-mini-schematic--bars i:nth-child(3) { height: 60%; }
.tachyon-view-mini-schematic--bars i:nth-child(4) { height: 100%; }

.tachyon-view-mini-schematic--gauges {
    grid-template-rows: repeat(2, 1fr);
}

.tachyon-view-mini-schematic--bento {
    grid-template-columns: repeat(2, 1fr);
    grid-template-rows: repeat(2, 1fr);
}

.tachyon-view-mini-schematic--wave i {
    height: 100%;
    border-radius: 3px;
}

.tachyon-visual-hidden-tray {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 8px;
}

.tachyon-visual-hidden-tray__title {
    font-size: 11.5px;
    font-weight: 700;
    opacity: 0.75;
}


/* ==========================================================================
   Tachyon Studio Deck (Full Redesign of Sections, Outbounds, Conditions,
   Balancers, Inbound Servers, Profiles & Schedules)
   ========================================================================== */

/* Hide legacy Forkop/LuCI GridSection tables & raw add bars when Studio Deck is mounted */
.tachyon-has-studio-deck > .cbi-section-node > .cbi-section-table,
.tachyon-has-studio-deck > .cbi-section-node > .cbi-section-create,
.tachyon-has-studio-deck > .cbi-section-table,
.tachyon-has-studio-deck > .cbi-section-create,
.tachyon-has-studio-deck > .cbi-section > .cbi-section-node > .cbi-section-table,
.tachyon-has-studio-deck > .cbi-section > .cbi-section-node > .cbi-section-create,
.tachyon-has-studio-deck > .cbi-section > .cbi-section-table,
.tachyon-has-studio-deck > .cbi-section > .cbi-section-create,
.tachyon-has-studio-deck > .tachyon-pane-quickbar,
.tachyon-has-studio-deck .tachyon-inbounds-server-header {
    display: none !important;
}

.tachyon-studio-deck {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 100%;
    box-sizing: border-box;
    margin-bottom: 10px;
}

.tachyon-studio-toolbar,
.tachyon-studio-panel {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px 14px;
    border-radius: 12px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-studio-toolbar__top,
.tachyon-studio-panel__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
}

.tachyon-studio-toolbar__titles,
.tachyon-studio-panel__titles {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 200px;
    flex: 1;
}

.tachyon-studio-toolbar__title-row,
.tachyon-studio-toolbar__kicker-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-studio-toolbar__kicker {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--text-color-medium, #94a3b8);
}

.tachyon-studio-toolbar__counter {
    font-size: 10.5px;
    font-weight: 700;
    padding: 1px 7px;
    border-radius: 6px;
    background: rgba(148, 130, 224, 0.12);
    color: #b4a5f0;
    border: 1px solid rgba(148, 130, 224, 0.26);
}

.tachyon-studio-toolbar__title,
.tachyon-studio-panel__title {
    margin: 0 !important;
    font-size: 14.5px !important;
    font-weight: 800 !important;
    letter-spacing: -0.01em;
}

.tachyon-studio-toolbar__subtitle,
.tachyon-studio-panel__subtitle {
    margin: 0 !important;
    font-size: 11.5px;
    opacity: 0.68;
    line-height: 1.35;
}

.tachyon-studio-toolbar__actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-studio-view-switch {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    padding: 2px;
    border-radius: 8px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
}

.tachyon-studio-view-btn {
    padding: 4px 9px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: inherit;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.72;
}

.tachyon-studio-view-btn.is-active {
    background: rgba(148, 130, 224, 0.15);
    color: #b4a5f0;
    opacity: 1;
    font-weight: 700;
    box-shadow: none;
}

.tachyon-studio-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 11px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-studio-btn--primary {
    border: 1px solid rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
}

.tachyon-studio-btn--primary:hover {
    background: rgba(148, 130, 224, 0.22);
    border-color: rgba(148, 130, 224, 0.52);
    color: #d8cff8;
}

.tachyon-studio-btn--ghost {
    border: 1px solid var(--border-color-medium, rgba(148, 163, 184, 0.24));
    background: var(--background-color-low, rgba(148, 163, 184, 0.07));
    color: inherit;
}

.tachyon-studio-btn--ghost:hover {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-studio-toolbar__bottom,
.tachyon-studio-panel__controls {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-studio-filter-group {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-studio-filter-pill {
    padding: 4px 10px;
    border-radius: 7px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
}

.tachyon-studio-filter-pill.is-active {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
    font-weight: 700;
}

.tachyon-studio-search {
    min-width: 200px;
    flex: 0 1 260px;
    padding: 4px 10px !important;
    border-radius: 8px !important;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.26)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06)) !important;
    color: inherit !important;
    font-size: 12px !important;
}

.tachyon-studio-body--cards {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 10px;
}

.tachyon-studio-body--pipeline {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-studio-card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    padding: 12px 14px;
    border-radius: 13px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    cursor: pointer;
    box-sizing: border-box;
    transition: border-color 0.14s ease, background-color 0.14s ease, transform 0.12s ease, box-shadow 0.14s ease;
}

.tachyon-studio-body--pipeline .tachyon-studio-card {
    flex-direction: row;
    align-items: center;
    flex-wrap: wrap;
    padding: 10px 14px;
    gap: 10px 16px;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__head {
    flex: 1 1 280px;
    min-width: 0;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__pipeline {
    flex: 2 1 320px;
    border-top: none;
    padding-top: 0;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__footer {
    border-top: none;
    padding-top: 0;
    margin-left: auto;
}

.tachyon-studio-card:hover {
    border-color: rgba(148, 130, 224, 0.4);
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
}

.tachyon-studio-card.is-disabled {
    opacity: 0.62;
}

.tachyon-studio-card.is-drag-over {
    border-color: #9482e0;
    box-shadow: 0 0 0 2px rgba(148, 130, 224, 0.28);
}

.tachyon-studio-card__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    min-width: 0;
}

.tachyon-studio-card__identity {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
}

.tachyon-studio-card__order {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    flex-shrink: 0;
}

.tachyon-studio-card__priority-badge {
    font-size: 11px;
    font-weight: 800;
    padding: 2px 6px;
    border-radius: 6px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.12));
    opacity: 0.78;
    cursor: grab;
    user-select: none;
}

.tachyon-studio-order-btn {
    padding: 2px 5px;
    border-radius: 5px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    background: transparent;
    color: inherit;
    font-size: 10px;
    font-weight: 700;
    cursor: pointer;
    opacity: 0.7;
}

.tachyon-studio-order-btn:hover:not(:disabled) {
    opacity: 1;
    border-color: rgba(148, 130, 224, 0.42);
}

.tachyon-studio-order-btn:disabled {
    opacity: 0.25;
    cursor: default;
}

.tachyon-studio-card__icon {
    width: 32px;
    height: 32px;
    border-radius: 8px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 15px;
    flex-shrink: 0;
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-high, #e2e8f0);
    border: 1px solid rgba(148, 163, 184, 0.16);
}

.tachyon-studio-card__icon--dpi {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-high, #e2e8f0);
}

.tachyon-studio-card__icon--bypass {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-high, #e2e8f0);
}

.tachyon-studio-card__favicon {
    width: 20px;
    height: 20px;
    border-radius: 4px;
    object-fit: contain;
}

.tachyon-studio-card__title-wrap {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
}

.tachyon-studio-card__title-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
    min-width: 0;
}

.tachyon-studio-card__title {
    font-size: 14px;
    font-weight: 800;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-studio-card__sid {
    font-size: 11px;
    opacity: 0.65;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Modern iOS/macOS Toggle Switch */
.tachyon-studio-switch {
    position: relative;
    width: 40px;
    height: 22px;
    border-radius: 999px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    background: rgba(128, 128, 128, 0.25);
    padding: 2px;
    cursor: pointer;
    flex-shrink: 0;
    transition: background-color 0.16s ease, border-color 0.16s ease;
}

.tachyon-studio-switch.is-on {
    background: #9482e0;
    border-color: #816ed4;
}

.tachyon-studio-switch__thumb {
    display: block;
    width: 16px;
    height: 16px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.28);
    transition: transform 0.16s ease;
}

.tachyon-studio-switch.is-on .tachyon-studio-switch__thumb {
    transform: translateX(18px);
}

/* Studio Badges */
.tachyon-studio-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 5px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.02em;
    white-space: nowrap;
}

.tachyon-studio-badge--proxy {
    background: rgba(148, 130, 224, 0.12);
    color: #b4a5f0;
    border: 1px solid rgba(148, 130, 224, 0.28);
}

.tachyon-studio-badge--dpi {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.2);
}

.tachyon-studio-badge--block {
    background: rgba(239, 68, 68, 0.12);
    color: #f87171;
    border: 1px solid rgba(239, 68, 68, 0.28);
}

.tachyon-studio-badge--bypass {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.2);
}

.tachyon-studio-badge--dns {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.2);
}

.tachyon-studio-badge--proto {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-high, #e2e8f0);
    border: 1px solid rgba(148, 163, 184, 0.2);
}

.tachyon-studio-badge--transport {
    background: rgba(148, 163, 184, 0.08);
    color: var(--text-color-medium, #94a3b8);
    border: 1px solid rgba(148, 163, 184, 0.2);
}

/* Studio Pipeline & Chips */
.tachyon-studio-card__pipeline {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px 12px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.15));
}

.tachyon-studio-card__pipe-stage {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
    flex: 1 1 140px;
}

.tachyon-studio-card__pipe-label {
    font-size: 9.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.58;
}

.tachyon-studio-card__pipe-arrow {
    font-size: 13px;
    opacity: 0.45;
    font-weight: 800;
}

.tachyon-studio-card__chips {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-studio-chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 7px;
    font-size: 11px;
    font-weight: 600;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    color: inherit;
    white-space: nowrap;
}

button.tachyon-studio-chip {
    cursor: pointer;
}

button.tachyon-studio-chip:hover {
    border-color: rgba(148, 130, 224, 0.42);
    color: #b4a5f0;
}

.tachyon-studio-chip--cond {
    background: rgba(148, 163, 184, 0.08);
    border-color: rgba(148, 163, 184, 0.2);
}

.tachyon-studio-chip--source {
    background: rgba(148, 130, 224, 0.1);
    border-color: rgba(148, 130, 224, 0.24);
}

.tachyon-studio-chip--balancer {
    background: rgba(148, 130, 224, 0.1);
    border-color: rgba(148, 130, 224, 0.24);
}

.tachyon-studio-chip--section {
    background: rgba(148, 163, 184, 0.08);
    border-color: rgba(148, 163, 184, 0.2);
}

.tachyon-studio-chip--muted {
    opacity: 0.68;
}

.tachyon-studio-card__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 6px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
}

.tachyon-studio-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    border-radius: 7px;
    border: 1px solid var(--border-color-medium, rgba(148, 163, 184, 0.22));
    background: var(--background-color-low, rgba(148, 163, 184, 0.06));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-studio-action-btn:hover {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.1);
}

.tachyon-studio-action-btn--primary {
    border-color: rgba(148, 130, 224, 0.38);
    background: rgba(148, 130, 224, 0.14);
    color: #b4a5f0;
}

.tachyon-studio-action-btn--danger {
    border-color: rgba(148, 163, 184, 0.22);
    background: rgba(148, 163, 184, 0.06);
    color: var(--text-color-medium, #94a3b8);
}

.tachyon-studio-action-btn--danger:hover {
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.45);
    color: #fca5a5;
}

.tachyon-studio-aux-stack {
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-top: 12px;
}

.tachyon-studio-groups-grid {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-studio-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 4px;
    padding: 24px 16px;
    border-radius: 12px;
    border: 1px dashed var(--border-color-medium, rgba(128, 128, 128, 0.28));
    text-align: center;
}

.tachyon-studio-empty--compact {
    padding: 14px;
}

.tachyon-studio-empty__title {
    font-size: 13.5px;
    font-weight: 800;
}

.tachyon-studio-empty__sub {
    font-size: 12px;
    opacity: 0.7;
}

/* Quick-Create Modal */
.tachyon-studio-create {
    display: flex;
    flex-direction: column;
    gap: 14px;
}

.tachyon-studio-create__field {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-studio-create__label {
    font-size: 12px;
    font-weight: 800;
}

.tachyon-studio-create__input {
    width: 100% !important;
    box-sizing: border-box !important;
}

.tachyon-studio-create__error {
    font-size: 12px;
    color: #ef4444;
    font-weight: 600;
}

.tachyon-studio-create__templates {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 8px;
}

.tachyon-studio-create__tpl-card {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    text-align: left;
    cursor: pointer;
}

.tachyon-studio-create__tpl-card.is-selected {
    border-color: var(--primary-color-high, #8b5cf6);
    background: rgba(139, 92, 246, 0.14);
}

.tachyon-studio-create__tpl-icon {
    font-size: 18px;
}

.tachyon-studio-create__tpl-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon-studio-create__tpl-title {
    font-size: 12.5px;
    font-weight: 800;
}

.tachyon-studio-create__tpl-desc {
    font-size: 11px;
    opacity: 0.72;
    line-height: 1.35;
}

.tachyon-studio-create__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 10px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

/* ==========================================================================
   Wizard Step 4: Smart DNS Auto-Tune & Benchmark + Visual DNS Preset Cards
   ========================================================================== */

.tachyon-wizard__dns-autotune-card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 13px 15px;
    border-radius: 13px;
    background: linear-gradient(135deg, rgba(139, 92, 246, 0.1), rgba(124, 58, 237, 0.04));
    border: 1px solid rgba(139, 92, 246, 0.34);
    box-sizing: border-box;
}

.tachyon-wizard__dns-autotune-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px;
}

.tachyon-wizard__dns-autotune-titles {
    display: flex;
    flex-direction: column;
    gap: 3px;
    flex: 1 1 260px;
    min-width: 0;
}

.tachyon-wizard__dns-autotune-title {
    font-size: 13.5px;
    font-weight: 800;
    color: #b4a5f0;
}

.tachyon-wizard__dns-autotune-desc {
    font-size: 11.5px;
    opacity: 0.8;
    line-height: 1.4;
}

.tachyon-wizard__dns-autotune-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
}

.tachyon-wizard__dns-run-btn {
    border-radius: 8px !important;
    background: rgba(148, 130, 224, 0.14) !important;
    border: 1px solid rgba(148, 130, 224, 0.38) !important;
    color: #b4a5f0 !important;
    font-weight: 700 !important;
    padding: 6px 13px !important;
    font-size: 12px !important;
    cursor: pointer;
    box-shadow: none !important;
}

.tachyon-wizard__dns-run-btn:hover {
    background: rgba(148, 130, 224, 0.22) !important;
    border-color: rgba(148, 130, 224, 0.5) !important;
}

.tachyon-wizard__dns-progress-box {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 9px 12px;
    border-radius: 9px;
    background: var(--background-color-high, rgba(15, 23, 42, 0.25));
    border: 1px solid rgba(139, 92, 246, 0.26);
}

.tachyon-wizard__dns-progress-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-size: 12px;
}

.tachyon-wizard__dns-progress-bar {
    height: 7px;
    border-radius: 999px;
    background: rgba(139, 92, 246, 0.16);
    overflow: hidden;
}

.tachyon-wizard__dns-progress-fill {
    height: 100%;
    border-radius: 999px;
    background: linear-gradient(90deg, #8b5cf6, #a855f7, #10b981);
    transition: width 0.25s ease;
}

.tachyon-wizard__dns-rec-box {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 11px 13px;
    border-radius: 11px;
    background: var(--background-color-high, rgba(16, 185, 129, 0.06));
    border: 1px solid rgba(16, 185, 129, 0.35);
}

.tachyon-wizard__dns-rec-box.is-selected {
    border-color: #8b5cf6;
    box-shadow: 0 0 0 1px rgba(139, 92, 246, 0.35);
}

.tachyon-wizard__dns-rec-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-wizard__dns-rec-title {
    font-size: 12.5px;
    font-weight: 800;
    color: #10b981;
}

.tachyon-wizard__dns-rec-actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-wizard__dns-rec-btn {
    padding: 4px 10px !important;
    font-size: 11.5px !important;
    border-radius: 7px !important;
}

.tachyon-wizard__dns-rec-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
    gap: 7px;
}

.tachyon-wizard__dns-rec-tier {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 7px 10px;
    border-radius: 8px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-wizard__dns-rec-tier-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    opacity: 0.68;
}

.tachyon-wizard__dns-rec-tier-val {
    font-size: 12px;
    font-weight: 800;
    word-break: break-all;
}

.tachyon-wizard__dns-rec-tier-sub {
    font-size: 10.5px;
    opacity: 0.75;
    color: #a855f7;
    font-weight: 600;
}

.tachyon-wizard__dns-rec-reason {
    font-size: 11px;
    opacity: 0.78;
    line-height: 1.35;
}

.tachyon-wizard__dns-top-wrap {
    display: flex;
    flex-direction: column;
    gap: 7px;
}

.tachyon-wizard__dns-top-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    font-size: 11.5px;
    font-weight: 700;
}

.tachyon-wizard__dns-top-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(195px, 1fr));
    gap: 7px;
}

.tachyon-wizard__dns-srv-chip {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 3px;
    padding: 8px 10px;
    border-radius: 9px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-high, rgba(128, 128, 128, 0.05));
    color: inherit;
    text-align: left;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-wizard__dns-srv-chip:hover,
.tachyon-wizard__dns-srv-chip.is-winner {
    border-color: #8b5cf6;
    background: rgba(139, 92, 246, 0.1);
}

.tachyon-wizard__dns-srv-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 6px;
}

.tachyon-wizard__dns-srv-name {
    font-size: 12px;
    font-weight: 800;
}

.tachyon-wizard__dns-srv-proto {
    font-size: 9.5px;
    font-weight: 800;
    padding: 1px 6px;
    border-radius: 5px;
    background: rgba(139, 92, 246, 0.16);
    color: #8b5cf6;
}

.tachyon-wizard__dns-srv-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    font-size: 11px;
}

.tachyon-wizard__dns-srv-addr {
    opacity: 0.68;
    font-family: monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 120px;
}

.tachyon-wizard__dns-srv-ms {
    font-weight: 800;
}

.tachyon-wizard__dns-presets-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
    gap: 8px;
}

.tachyon-wizard__dns-preset-card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: space-between;
    gap: 5px;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24));
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    color: inherit;
    text-align: left;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease, box-shadow 0.14s ease;
}

.tachyon-wizard__dns-preset-card:hover {
    border-color: #8b5cf6;
}

.tachyon-wizard__dns-preset-card.is-selected {
    border-color: #8b5cf6;
    background: rgba(139, 92, 246, 0.13);
    box-shadow: 0 0 0 1px rgba(139, 92, 246, 0.32);
}

.tachyon-wizard__dns-preset-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 6px;
}

.tachyon-wizard__dns-preset-title {
    font-size: 12.5px;
    font-weight: 800;
}

.tachyon-wizard__dns-preset-badge {
    font-size: 9.5px;
    font-weight: 800;
    padding: 1px 6px;
    border-radius: 5px;
    background: rgba(139, 92, 246, 0.16);
    color: #8b5cf6;
    white-space: nowrap;
}

.tachyon-wizard__dns-preset-desc {
    font-size: 11px;
    opacity: 0.74;
    line-height: 1.35;
}

/* ==========================================================================
   Interactive Community Service List Picker & Live Hover/Mobile Hint Banner
   ========================================================================== */

.cbi-dynlist.tachyon-dynlist-with-picker {
    display: flex !important;
    flex-direction: row !important;
    flex-wrap: wrap !important;
    align-items: center !important;
    gap: 5px !important;
    width: 100%;
    max-width: 100%;
    margin-bottom: 8px !important;
}

.cbi-dynlist.tachyon-dynlist-with-picker:not(:has(> .item)) {
    display: none !important;
    margin-bottom: 0 !important;
}

.cbi-dynlist.tachyon-dynlist-with-picker > .item {
    width: auto !important;
    max-width: 100% !important;
    flex: 0 0 auto !important;
    display: inline-flex !important;
    align-items: center !important;
    margin: 0 !important;
    padding: 3px 24px 3px 9px !important;
    border-radius: 7px !important;
    font-size: 11.5px !important;
    line-height: 1.3 !important;
    border-color: rgba(148, 130, 224, 0.28) !important;
    background: rgba(148, 130, 224, 0.10) !important;
}

.cbi-dynlist.tachyon-dynlist-with-picker > .add-item,
.cbi-dynlist.tachyon-dynlist-with-picker > .cbi-dropdown,
.cbi-dynlist.tachyon-dynlist-with-picker > select,
.cbi-dynlist.tachyon-dynlist-with-picker .add-item,
.cbi-dynlist.tachyon-dynlist-with-picker .cbi-dropdown {
    display: none !important;
}

.tachyon-ruleset-picker {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 0;
    background: transparent;
    border: none;
    box-sizing: border-box;
    width: 100%;
}

.tachyon-ruleset-picker button,
.tachyon-ruleset-picker button:hover,
.tachyon-ruleset-picker button:focus,
.tachyon-ruleset-picker button:active {
    --focus-color-rgb: 148, 130, 224 !important;
    outline: none !important;
    box-shadow: none !important;
}

.tachyon-ruleset-picker__hint-bar {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 8px 11px;
    border-radius: 9px;
    background: rgba(148, 130, 224, 0.06);
    border: 1px solid rgba(148, 130, 224, 0.20);
    transition: border-color 0.15s ease, background-color 0.15s ease;
    box-sizing: border-box;
}

.tachyon-ruleset-picker__hint-bar.is-highlighted {
    border-color: rgba(148, 130, 224, 0.34);
    background: rgba(148, 130, 224, 0.09);
}

.tachyon-ruleset-picker__cats-block {
    display: flex;
    flex-direction: column;
    padding: 8px 10px;
    border-radius: 9px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.20));
    box-sizing: border-box;
}

.tachyon-ruleset-picker__list-block {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 9px 10px;
    border-radius: 9px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.20));
    box-sizing: border-box;
}

.tachyon-ruleset-picker__hint-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-ruleset-picker__hint-title {
    font-size: 12px;
    font-weight: 800;
    color: var(--text-color-high, inherit);
}

.tachyon-ruleset-picker__hint-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 10.5px;
    font-weight: 700;
    background: rgba(148, 130, 224, 0.14);
    color: #9c8be3;
    border: 1px solid rgba(148, 130, 224, 0.28);
}

.tachyon-ruleset-picker__hint-badge.is-vpn {
    background: rgba(148, 130, 224, 0.14);
    color: #9c8be3;
    border-color: rgba(148, 130, 224, 0.30);
}

.tachyon-ruleset-picker__hint-badge.is-dpi {
    background: rgba(245, 158, 11, 0.14);
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.30);
}

.tachyon-ruleset-picker__hint-badge.is-direct {
    background: rgba(16, 185, 129, 0.14);
    color: #10b981;
    border-color: rgba(16, 185, 129, 0.30);
}

.tachyon-ruleset-picker__hint-badge.is-block {
    background: rgba(239, 68, 68, 0.14);
    color: #ef4444;
    border-color: rgba(239, 68, 68, 0.30);
}

.tachyon-ruleset-picker__hint-desc {
    font-size: 11.5px;
    line-height: 1.38;
    opacity: 0.85;
}

.tachyon-ruleset-picker__toolbar {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-ruleset-picker__cats {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-ruleset-picker__cat-btn {
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-ruleset-picker__cat-btn:hover {
    border-color: rgba(148, 130, 224, 0.38) !important;
}

.tachyon-ruleset-picker__cat-btn.is-active,
.tachyon-ruleset-picker__cat-btn.is-active:hover,
.tachyon-ruleset-picker__cat-btn.is-active:focus {
    border-color: rgba(148, 130, 224, 0.38) !important;
    background: rgba(148, 130, 224, 0.14) !important;
    color: #9c8be3 !important;
    font-weight: 700;
    box-shadow: none !important;
}

.tachyon-ruleset-picker__search {
    width: 100% !important;
    max-width: 100% !important;
    padding: 5px 10px !important;
    font-size: 12px !important;
    border-radius: 8px !important;
    box-sizing: border-box !important;
}

.tachyon-ruleset-picker__grid {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
    max-height: 175px;
    overflow-y: auto;
    padding: 2px;
}

.tachyon-ruleset-picker__chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 8px;
    border-radius: 7px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-ruleset-picker__chip:hover {
    border-color: rgba(148, 130, 224, 0.38) !important;
    background: rgba(148, 130, 224, 0.07);
}

.tachyon-ruleset-picker__chip.is-selected,
.tachyon-ruleset-picker__chip.is-selected:hover,
.tachyon-ruleset-picker__chip.is-selected:focus {
    border-color: rgba(148, 130, 224, 0.38) !important;
    background: rgba(148, 130, 224, 0.13) !important;
    color: #9c8be3 !important;
    font-weight: 700;
}

.tachyon-ruleset-picker__chip-check {
    font-size: 11px;
    font-weight: 800;
    opacity: 0.85;
}

.tachyon-ruleset-picker__chip-route {
    font-size: 9.5px;
    font-weight: 800;
    padding: 1px 5px;
    border-radius: 4px;
    background: rgba(148, 130, 224, 0.14);
    color: #9c8be3;
}

.tachyon-ruleset-picker__chip-route.is-dpi {
    background: rgba(245, 158, 11, 0.15);
    color: #f59e0b;
}

.tachyon-ruleset-picker__chip-route.is-direct {
    background: rgba(16, 185, 129, 0.15);
    color: #10b981;
}

.tachyon-ruleset-picker__chip-route.is-block {
    background: rgba(239, 68, 68, 0.15);
    color: #ef4444;
}

.tachyon-ruleset-picker__chip-info {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 17px;
    height: 17px;
    border-radius: 50%;
    font-size: 11px;
    font-weight: 800;
    opacity: 0.65;
    margin-left: 2px;
    background: rgba(128, 128, 128, 0.14);
}

.tachyon-ruleset-picker__chip-info:hover {
    opacity: 1;
    background: rgba(148, 130, 224, 0.20);
    color: #9c8be3;
}

.tachyon-ruleset-picker__empty {
    font-size: 12px;
    opacity: 0.68;
    padding: 8px 4px;
}
`;
