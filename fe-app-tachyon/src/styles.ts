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

/* Scroll stability & theme anchoring isolation */
[id^="cbi-${TACHYON_CBI_PREFIX}"],
.tachyon-view {
    overflow-anchor: none !important;
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
    background: var(--primary-color-high, #1976d2);
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
    border-color: var(--primary-color-high, #1976d2);
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
    background: rgba(25, 118, 210, 0.1);
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
    color: var(--primary-color-high, #1976d2);
}

.tachyon-lang-option__badge--install {
    background: rgba(25, 118, 210, 0.14);
    color: var(--primary-color-high, #1976d2);
}
`;
