// language=CSS
import { DashboardTab } from './tachyon/tabs/dashboard';
import { DiagnosticTab } from './tachyon/tabs/diagnostic';
import { MonitoringTab } from './tachyon/tabs/monitoring';
import { UpdatesTab } from './tachyon/tabs/updates';
import { PartialStyles } from './partials';
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from './constants';

export const GlobalStyles = `
@font-face {
    font-family: 'Twemoji Country Flags';
    src: url('/luci-static/resources/view/tachyon/fonts/TwemojiCountryFlags.woff2') format('woff2');
    font-weight: normal;
    font-style: normal;
    font-display: swap;
}
${DashboardTab.styles}
${DiagnosticTab.styles}
${MonitoringTab.styles}
${UpdatesTab.styles}
${PartialStyles}

/* ==========================================================================
   Tachyon-UI Reusable Design System & High-Performance GPU Tokens (1:1 ui.html)
   ========================================================================== */
:root {
    --color-scheme: dark;
    --bg: #0b0b0c;
    --surface: #141416;
    --hover: #1c1c1f;
    --elevated: #26262b;
    --border: rgba(255, 255, 255, 0.08);
    --border-strong: rgba(255, 255, 255, 0.15);
    --accent: #0a84ff;
    --accent-hover: #409cff;
    --danger: #ff453a;
    --success: #30d158;
    --ok: #30d158;
    --warn: #ff9f0a;
    --text: #f5f5f7;
    --text2: #a1a1a6;
    --text3: #6e6e73;
    --bg2: #141416;
    --border-hi: rgba(255, 255, 255, 0.15);
    --surface-glass: rgba(20, 20, 22, 0.84);
    --topbar-glass: rgba(20, 20, 22, 0.96);
    --accent-soft: rgba(10, 132, 255, 0.16);
    --accent-ring: rgba(10, 132, 255, 0.34);
    --bg-grid-stroke: rgba(255, 255, 255, 0.028);
    --mono: "SF Mono", ui-monospace, "Cascadia Code", "JetBrains Mono", monospace;
    --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
    --r-card: 12px;
    --r-btn: 8px;
    --r-xs: 6px;
    --spring: cubic-bezier(0.22, 1, 0.36, 1);
    --transition: 160ms var(--spring);
}

html,
body,
[data-darkmode="true"],
[data-darkmode="false"] {
    color-scheme: var(--color-scheme, dark) !important;

    /* Legacy LuCI / Bootstrap variable mappings -> tachyon-ui tokens */
    --background-color-high: var(--surface) !important;
    --background-color-medium: var(--bg) !important;
    --background-color-low: var(--hover) !important;
    --border-color-high: var(--border-strong) !important;
    --border-color-medium: var(--border) !important;
    --border-color-low: var(--border) !important;
    --text-color-high: var(--text) !important;
    --text-color-medium: var(--text2) !important;
    --text-color-low: var(--text3) !important;
    --primary-color-high: var(--accent) !important;
    --primary-color-medium: var(--accent) !important;
    --primary-color-low: var(--accent-soft, rgba(10, 132, 255, 0.16)) !important;
    --primary: var(--accent) !important;
    --main-color: var(--accent) !important;
}

html,
body {
    background: var(--bg) !important;
    color: var(--text) !important;
    font-family: var(--sans) !important;
    font-size: 14px;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
    font-optical-sizing: auto;
}

body > header,
body > footer,
header .fill,
#indicators,
#unsaved-changes {
    display: none !important;
}

#maincontent,
.main,
.main-right,
.container {
    background: transparent !important;
    max-width: 100% !important;
    width: 100% !important;
    margin: 0 !important;
    padding: 0 !important;
}

/* Tachyon Animated SVG Background (1:1 ui.html) */
.tachyon-bg-layer {
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 0;
    overflow: hidden;
    background: transparent !important;
}

[data-tachyon-bg-animation="false"] .tachyon-bg-layer,
[data-tachyon-bg-animation="false"] .tachyon-bg-layer svg {
    display: none !important;
}

.tachyon-bg-layer svg {
    width: 100%;
    height: 100%;
    display: block;
}

.tachyon-stream {
    stroke-dasharray: 80 620;
    animation: tachyon-flow 5.5s linear infinite;
}
.tachyon-stream.s2 {
    stroke-dasharray: 50 540;
    animation-duration: 4.1s;
    animation-delay: -1.6s;
}
.tachyon-stream.s3 {
    stroke-dasharray: 110 720;
    animation-duration: 6.8s;
    animation-delay: -3.2s;
}
.tachyon-stream.s4 {
    stroke-dasharray: 40 480;
    animation-duration: 3.4s;
    animation-delay: -0.9s;
}
.tachyon-stream.s5 {
    stroke-dasharray: 65 600;
    animation-duration: 4.9s;
    animation-delay: -2.4s;
}
@keyframes tachyon-flow {
    from { stroke-dashoffset: 800; }
    to { stroke-dashoffset: 0; }
}

/* Reusable Typography & Utility Classes (tachyon-ui) */
.tabnum {
    font-variant-numeric: tabular-nums;
    font-feature-settings: 'tnum' 1;
}
.mono {
    font-family: var(--mono);
    font-size: 12px;
}

/* Reusable Cards, Badges, Progress, Segmented Tabs & Preset Chips (tachyon-ui) */
.card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--r-card);
    padding: 16px;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04);
    contain: layout style;
}
.card-title {
    font-size: 13px;
    color: var(--text2);
    font-weight: 600;
    letter-spacing: -0.008em;
    margin-bottom: 10px;
}

.badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border-radius: var(--r-xs);
    font-size: 11px;
    font-weight: 500;
    font-variant-numeric: tabular-nums;
    line-height: 1.4;
}
.badge-on,
.badge-ok {
    color: var(--success) !important;
    border: 1px solid rgba(48, 209, 88, 0.28) !important;
    background: rgba(48, 209, 88, 0.1) !important;
}
.badge-warn {
    color: var(--warn) !important;
    border: 1px solid rgba(255, 159, 10, 0.28) !important;
    background: rgba(255, 159, 10, 0.1) !important;
}
.badge-danger {
    color: var(--danger) !important;
    border: 1px solid rgba(255, 69, 58, 0.28) !important;
    background: rgba(255, 69, 58, 0.1) !important;
}
.badge-off {
    color: var(--text3) !important;
    border: 1px solid var(--border) !important;
    background: transparent !important;
}
.badge-proto {
    font-family: var(--mono);
    color: var(--text2) !important;
    border: 1px solid var(--border) !important;
    background: var(--bg) !important;
}

.modal-tabs {
    display: flex;
    gap: 4px;
    padding: 4px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    margin-bottom: 14px;
    flex-shrink: 0;
    overflow: hidden;
}
.modal-tab {
    flex: 1;
    justify-content: center;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: var(--r-xs);
    font-size: 12px;
    font-weight: 500;
    color: var(--text2);
    background: transparent;
    border: none;
    white-space: nowrap;
    cursor: pointer;
    transition: background var(--transition), color var(--transition), transform 80ms ease-out;
}
.modal-tab:hover {
    color: var(--text);
    background: var(--hover);
}
.modal-tab:active {
    transform: scale(0.97);
}
.modal-tab.active {
    color: var(--text);
    background: var(--elevated);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.4), inset 0 1px 0 rgba(255, 255, 255, 0.08);
}

.preset-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    padding: 8px 12px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--r-btn);
    margin-bottom: 14px;
}
.preset-label,
.preset-bar-label {
    font-size: 12px;
    font-weight: 500;
    color: var(--text3);
    margin-right: 4px;
    display: inline-flex;
    align-items: center;
    gap: 5px;
}
.preset-chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    border-radius: var(--r-xs);
    font-size: 12px;
    font-weight: 500;
    color: var(--text2);
    background: var(--surface);
    border: 1px solid var(--border);
    cursor: pointer;
    transition: background var(--transition), border-color var(--transition), color var(--transition), transform 80ms ease-out;
}
.preset-chip:hover {
    color: var(--text);
    border-color: var(--border-strong);
    background: var(--hover);
}
.preset-chip:active {
    transform: scale(0.97);
}
.preset-chip.active {
    color: #fff;
    border-color: var(--accent);
    background: rgba(10, 132, 255, 0.22);
}

.progress {
    height: 5px;
    background: var(--elevated);
    border-radius: 99px;
    overflow: hidden;
    min-width: 60px;
}
.progress-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 99px;
    transition: width 300ms var(--spring);
}
.progress-fill.warn { background: var(--warn); }
.progress-fill.danger { background: var(--danger); }

.logs-box {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--r-btn);
    padding: 12px;
    font-family: var(--mono);
    font-size: 12px;
    color: var(--text2);
    max-height: 240px;
    overflow-y: auto;
    line-height: 1.65;
    white-space: pre-wrap;
    word-break: break-all;
}

.config-pre {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--r-btn);
    padding: 16px;
    font-family: var(--mono);
    font-size: 12px;
    color: var(--text2);
    max-height: 60vh;
    overflow: auto;
    white-space: pre;
    tab-size: 2;
    line-height: 1.6;
}

/* Unified Tables (1:1 tachyon-ui — eliminates black LuCI Bootstrap table headers) */
.tbl-wrap,
.table-wrap {
    overflow-x: auto;
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] table,
.tachyon-view table,
#modal_overlay table,
.cbi-modal table,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .table,
.tachyon-view .table,
#modal_overlay .table,
.cbi-modal .table {
    width: 100%;
    border-collapse: collapse !important;
    font-size: 13px;
    background: transparent !important;
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] thead th,
.tachyon-view thead th,
#modal_overlay thead th,
.cbi-modal thead th,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .table .th,
.tachyon-view .table .th,
#modal_overlay .table .th,
.cbi-modal .table .th,
#modal_overlay .cbi-section-table-titles .th,
.cbi-modal .cbi-section-table-titles .th {
    text-align: left;
    padding: 9px 12px !important;
    color: var(--text3) !important;
    font-weight: 500 !important;
    font-size: 12px !important;
    letter-spacing: 0 !important;
    border-bottom: 1px solid var(--border) !important;
    border-top: none !important;
    background: var(--surface) !important;
    box-shadow: none !important;
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] tbody td,
.tachyon-view tbody td,
#modal_overlay tbody td,
.cbi-modal tbody td,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .table .td,
.tachyon-view .table .td,
#modal_overlay .table .td,
.cbi-modal .table .td {
    padding: 9px 12px !important;
    border-bottom: 1px solid var(--border) !important;
    border-top: none !important;
    vertical-align: middle !important;
    background: transparent !important;
    color: var(--text);
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] tbody tr,
.tachyon-view tbody tr,
#modal_overlay tbody tr,
.cbi-modal tbody tr,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .table .tr:not(.cbi-section-table-titles),
.tachyon-view .table .tr:not(.cbi-section-table-titles),
#modal_overlay .table .tr:not(.cbi-section-table-titles),
.cbi-modal .table .tr:not(.cbi-section-table-titles) {
    transition: background 120ms ease;
    background: transparent !important;
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] tbody tr:hover,
.tachyon-view tbody tr:hover,
#modal_overlay tbody tr:hover,
.cbi-modal tbody tr:hover,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .table .tr:not(.cbi-section-table-titles):hover,
.tachyon-view .table .tr:not(.cbi-section-table-titles):hover,
#modal_overlay .table .tr:not(.cbi-section-table-titles):hover,
.cbi-modal .table .tr:not(.cbi-section-table-titles):hover {
    background: rgba(255, 255, 255, 0.025) !important;
}
[id^="cbi-${TACHYON_CBI_PREFIX}"] tbody tr:last-child td,
.tachyon-view tbody tr:last-child td,
#modal_overlay tbody tr:last-child td,
.cbi-modal tbody tr:last-child td,
#modal_overlay .table .tr:last-child .td,
.cbi-modal .table .tr:last-child .td {
    border-bottom: none !important;
}

html,
body,
#maincontent,
.main,
.main-right,
.cbi-map,
.cbi-page-actions,
footer {
    overflow-anchor: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"],
.tachyon-view,
#modal_overlay,
.cbi-modal,
.tachyon-wizard,
[data-darkmode="false"] [id^="cbi-${TACHYON_CBI_PREFIX}"],
[data-darkmode="false"] .tachyon-view,
[data-darkmode="false"] #modal_overlay,
[data-darkmode="false"] .cbi-modal,
[data-darkmode="false"] .tachyon-wizard {
    overflow-anchor: none !important;
    --tachyon-accent: var(--accent);
    --tachyon-accent-strong: var(--accent-hover);
    --tachyon-accent-soft: rgba(10, 132, 255, 0.15);
    --tachyon-accent-border: rgba(10, 132, 255, 0.38);
    --tachyon-accent-text: #409cff;
    --tachyon-accent-text-hover: #64d2ff;
    --tachyon-violet: var(--accent);
    --tachyon-violet-strong: var(--accent-hover);
    --tachyon-violet-soft: var(--tachyon-accent-soft);
    --tachyon-violet-border: var(--tachyon-accent-border);
    --tachyon-bg-shell: var(--bg);
    --tachyon-bg-card: var(--surface);
    --tachyon-bg-card-elevated: var(--hover);
    --tachyon-bg-surface-alt: var(--elevated);
    --tachyon-border-subtle: var(--border);
    --tachyon-text-main: var(--text);
    --tachyon-text-secondary: var(--text2);
    --tachyon-text-muted: var(--text3);
    --tachyon-radius-card: var(--r-card);
    --tachyon-success: var(--success);
    --tachyon-success-soft: rgba(48, 209, 88, 0.12);
    --tachyon-success-border: rgba(48, 209, 88, 0.28);
    --tachyon-warning: var(--warn);
    --tachyon-warning-soft: rgba(255, 159, 10, 0.14);
    --tachyon-warning-border: rgba(255, 159, 10, 0.30);
    --tachyon-danger: var(--danger);
    --tachyon-danger-soft: rgba(255, 69, 58, 0.12);
    --tachyon-danger-border: rgba(255, 69, 58, 0.32);
}

/* Unified 36x20 Apple iOS/macOS Switch for all CBI checkboxes & .toggle across Tachyon */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-checkbox > input[type="checkbox"],
.tachyon-view .cbi-checkbox > input[type="checkbox"],
#modal_overlay .cbi-checkbox > input[type="checkbox"],
.cbi-modal .cbi-checkbox > input[type="checkbox"] {
    appearance: none !important;
    -webkit-appearance: none !important;
    position: relative !important;
    display: inline-flex !important;
    align-items: center !important;
    width: 36px !important;
    min-width: 36px !important;
    max-width: 36px !important;
    height: 20px !important;
    min-height: 20px !important;
    margin: 0 8px 0 0 !important;
    padding: 0 !important;
    border-radius: 10px !important;
    border: 1px solid var(--border-strong) !important;
    background: var(--elevated) !important;
    cursor: pointer !important;
    vertical-align: middle !important;
    box-sizing: border-box !important;
    transition: background-color var(--transition), border-color var(--transition) !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-checkbox > input[type="checkbox"]::before,
.tachyon-view .cbi-checkbox > input[type="checkbox"]::before,
#modal_overlay .cbi-checkbox > input[type="checkbox"]::before,
.cbi-modal .cbi-checkbox > input[type="checkbox"]::before {
    display: none !important;
    content: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-checkbox > input[type="checkbox"]::after,
.tachyon-view .cbi-checkbox > input[type="checkbox"]::after,
#modal_overlay .cbi-checkbox > input[type="checkbox"]::after,
.cbi-modal .cbi-checkbox > input[type="checkbox"]::after {
    content: "" !important;
    position: absolute !important;
    top: 1px !important;
    left: 1px !important;
    width: 16px !important;
    height: 16px !important;
    border-radius: 50% !important;
    background: #ffffff !important;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.4) !important;
    mask-image: none !important;
    -webkit-mask-image: none !important;
    transform: translateX(0) !important;
    transition: transform 200ms var(--spring) !important;
    opacity: 1 !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-checkbox > input[type="checkbox"]:checked,
.tachyon-view .cbi-checkbox > input[type="checkbox"]:checked,
#modal_overlay .cbi-checkbox > input[type="checkbox"]:checked,
.cbi-modal .cbi-checkbox > input[type="checkbox"]:checked {
    background: var(--success) !important;
    border-color: var(--success) !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-checkbox > input[type="checkbox"]:checked::after,
.tachyon-view .cbi-checkbox > input[type="checkbox"]:checked::after,
#modal_overlay .cbi-checkbox > input[type="checkbox"]:checked::after,
.cbi-modal .cbi-checkbox > input[type="checkbox"]:checked::after {
    transform: translateX(16px) !important;
}

/* Solid Topbar Surface */
.tachyon-topbar {
    background-color: var(--topbar-glass, rgba(20, 20, 22, 0.96)) !important;
}

.tachyon-sidebar,
.tachyon_updates-page__component,
.tachyon_diagnostic-page__left-bar,
.tachyon_diagnostic-action-group,
.tachyon_diagnostic-system-strip > *,
.tachyon_diagnostic-page__right-bar__system-info,
.tachyon_diagnostic-page__right-bar__wiki,
.tachyon_monitoring-page__panel,
.tachyon_dashboard-page__widgets-section__item,
.tachyon_dashboard-page__outbound-section,
.tachyon-kpi-card,
.tachyon-kpi-strip,
.tachyon-kpi-minimal-counters,
.tachyon-traffic-chart-card,
.tachyon-routing-sections-block,
.tachyon-nodes-block,
.tachyon-router-services-bar,
.tachyon-router-services-cards-wrap,
.tachyon-system-tiles-card,
.tachyon-system-hud-card,
.tachyon-system-banner-card,
.tachyon-studio-toolbar,
.tachyon-studio-panel,
.tachyon-studio-card,
.tachyon-settings-list-card,
.tachyon-workspace-body .cbi-section:not(#cbi-tachyon-dashboard):not(#cbi-tachyon-diagnostic):not(#cbi-tachyon-monitoring):not(#cbi-tachyon-updates):not(#cbi-tachyon-section) {
    background-color: var(--surface-glass, rgba(20, 20, 22, 0.82)) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04);
}

/* Unified Reusable Buttons — Cohesive Dark Graphite & Tinted Accent Glass (Zero Neon Bricks) */
.btn,
.cbi-button,
input.cbi-button,
input[type="button"].cbi-button,
input[type="submit"].cbi-button,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button,
[id^="cbi-${TACHYON_CBI_PREFIX}"] input.cbi-button,
.tachyon-view .btn,
.tachyon-view .cbi-button,
#modal_overlay .btn,
#modal_overlay .cbi-button,
.cbi-modal .btn,
.cbi-modal .cbi-button {
    appearance: none !important;
    -webkit-appearance: none !important;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 6px !important;
    width: auto !important;
    max-width: 100% !important;
    height: auto !important;
    min-height: 28px !important;
    padding: 5px 12px !important;
    margin: 0 !important;
    border-radius: 7px !important;
    font-family: var(--sans) !important;
    font-size: 12px !important;
    font-weight: 500 !important;
    line-height: 1.3 !important;
    letter-spacing: -0.005em !important;
    background: rgba(255, 255, 255, 0.045) !important;
    background-image: none !important;
    border: 1px solid rgba(255, 255, 255, 0.11) !important;
    color: #e4e4e7 !important;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04) !important;
    text-shadow: none !important;
    outline: none !important;
    user-select: none;
    white-space: nowrap;
    flex-shrink: 0;
    cursor: pointer;
    transition: background var(--transition), border-color var(--transition), color var(--transition), opacity var(--transition), transform 80ms ease-out !important;
}

.btn:hover:not(:disabled),
.cbi-button:hover:not(:disabled),
input.cbi-button:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] input.cbi-button:hover:not(:disabled),
.tachyon-view .btn:hover:not(:disabled),
.tachyon-view .cbi-button:hover:not(:disabled),
#modal_overlay .btn:hover:not(:disabled),
#modal_overlay .cbi-button:hover:not(:disabled),
.cbi-modal .btn:hover:not(:disabled),
.cbi-modal .cbi-button:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.09) !important;
    background-image: none !important;
    border-color: rgba(255, 255, 255, 0.2) !important;
    color: #ffffff !important;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.07) !important;
}

.btn:active:not(:disabled),
.cbi-button:active:not(:disabled),
input.cbi-button:active:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn:active:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button:active:not(:disabled),
.tachyon-view .btn:active:not(:disabled),
.tachyon-view .cbi-button:active:not(:disabled),
#modal_overlay .btn:active:not(:disabled),
#modal_overlay .cbi-button:active:not(:disabled),
.cbi-modal .btn:active:not(:disabled),
.cbi-modal .cbi-button:active:not(:disabled) {
    transform: scale(0.97) !important;
    transition-duration: 50ms !important;
}

.btn:disabled,
.cbi-button:disabled,
input.cbi-button:disabled,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn:disabled,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button:disabled,
.tachyon-view .btn:disabled,
.tachyon-view .cbi-button:disabled,
#modal_overlay .btn:disabled,
#modal_overlay .cbi-button:disabled,
.cbi-modal .btn:disabled,
.cbi-modal .cbi-button:disabled {
    opacity: 0.4 !important;
    cursor: not-allowed !important;
}

/* Primary & Action Buttons — Refined Dark-Accent Glass Pill (matches sidebar/wizard/studio buttons) */
.btn-primary,
.cbi-button-apply,
.cbi-button-save,
.cbi-button-positive,
.cbi-button-action,
input.cbi-button-action,
.cbi-button-action.important,
input.cbi-button-action.important,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn-primary,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-apply,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-save,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-positive,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action,
[id^="cbi-${TACHYON_CBI_PREFIX}"] input.cbi-button-action,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action.important,
#modal_overlay .btn-primary,
#modal_overlay .cbi-button-apply,
#modal_overlay .cbi-button-save,
#modal_overlay .cbi-button-positive,
#modal_overlay .cbi-button-action,
#modal_overlay input.cbi-button-action,
.cbi-modal .btn-primary,
.cbi-modal .cbi-button-apply,
.cbi-modal .cbi-button-save,
.cbi-modal .cbi-button-positive,
.cbi-modal .cbi-button-action,
.cbi-modal input.cbi-button-action {
    background: rgba(10, 132, 255, 0.14) !important;
    background-image: none !important;
    border: 1px solid rgba(10, 132, 255, 0.36) !important;
    color: #5eb0ff !important;
    box-shadow: inset 0 1px 0 rgba(10, 132, 255, 0.12) !important;
}

.btn-primary:hover:not(:disabled),
.cbi-button-apply:hover:not(:disabled),
.cbi-button-save:hover:not(:disabled),
.cbi-button-positive:hover:not(:disabled),
.cbi-button-action:hover:not(:disabled),
input.cbi-button-action:hover:not(:disabled),
.cbi-button-action.important:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn-primary:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-apply:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-save:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-positive:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] input.cbi-button-action:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-action.important:hover:not(:disabled),
#modal_overlay .btn-primary:hover:not(:disabled),
#modal_overlay .cbi-button-apply:hover:not(:disabled),
#modal_overlay .cbi-button-save:hover:not(:disabled),
#modal_overlay .cbi-button-positive:hover:not(:disabled),
#modal_overlay .cbi-button-action:hover:not(:disabled),
#modal_overlay input.cbi-button-action:hover:not(:disabled),
.cbi-modal .btn-primary:hover:not(:disabled),
.cbi-modal .cbi-button-apply:hover:not(:disabled),
.cbi-modal .cbi-button-save:hover:not(:disabled),
.cbi-modal .cbi-button-positive:hover:not(:disabled),
.cbi-modal .cbi-button-action:hover:not(:disabled),
.cbi-modal input.cbi-button-action:hover:not(:disabled) {
    background: rgba(10, 132, 255, 0.22) !important;
    background-image: none !important;
    border-color: rgba(10, 132, 255, 0.52) !important;
    color: #82c4ff !important;
    box-shadow: none !important;
}

/* Keep buttons inside LuCI light-yellow alert banners readable across light and dark themes */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .cbi-button-apply,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .cbi-button,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .btn,
.tachyon-view .alert-message .cbi-button-apply,
.tachyon-view .alert-message .cbi-button,
.tachyon-view .alert-message .btn,
#modal_overlay .alert-message .cbi-button-apply,
#modal_overlay .alert-message .cbi-button,
#modal_overlay .alert-message .btn,
.cbi-modal .alert-message .cbi-button-apply,
.cbi-modal .alert-message .cbi-button,
.cbi-modal .alert-message .btn {
    background: #1f2430 !important;
    border-color: rgba(15, 23, 42, 0.45) !important;
    color: #f8fafc !important;
    font-weight: 600 !important;
    text-shadow: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .cbi-button-apply:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .cbi-button:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message .btn:hover:not(:disabled),
.tachyon-view .alert-message .cbi-button-apply:hover:not(:disabled),
.tachyon-view .alert-message .cbi-button:hover:not(:disabled),
.tachyon-view .alert-message .btn:hover:not(:disabled),
#modal_overlay .alert-message .cbi-button-apply:hover:not(:disabled),
#modal_overlay .alert-message .cbi-button:hover:not(:disabled),
#modal_overlay .alert-message .btn:hover:not(:disabled),
.cbi-modal .alert-message .cbi-button-apply:hover:not(:disabled),
.cbi-modal .alert-message .cbi-button:hover:not(:disabled),
.cbi-modal .alert-message .btn:hover:not(:disabled) {
    background: #111827 !important;
    border-color: rgba(15, 23, 42, 0.72) !important;
    color: #ffffff !important;
}

/* Danger / Remove Buttons (1:1 tachyon-ui .btn-danger) */
.btn-danger,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn-danger,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-remove,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-negative,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-reset,
#modal_overlay .btn-danger,
#modal_overlay .cbi-button-remove,
#modal_overlay .cbi-button-negative,
#modal_overlay .cbi-button-reset,
.cbi-modal .btn-danger,
.cbi-modal .cbi-button-remove,
.cbi-modal .cbi-button-negative,
.cbi-modal .cbi-button-reset {
    color: var(--danger) !important;
    border-color: rgba(255, 69, 58, 0.35) !important;
    background: rgba(255, 69, 58, 0.08) !important;
}

/* Negative / Remove buttons stay calm neutral until hovered */
.btn-danger:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .btn-danger:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-remove:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-negative:hover:not(:disabled),
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-button-reset:hover:not(:disabled),
#modal_overlay .btn-danger:hover:not(:disabled),
#modal_overlay .cbi-button-remove:hover:not(:disabled),
#modal_overlay .cbi-button-negative:hover:not(:disabled),
#modal_overlay .cbi-button-reset:hover:not(:disabled),
.cbi-modal .btn-danger:hover:not(:disabled),
.cbi-modal .cbi-button-remove:hover:not(:disabled),
.cbi-modal .cbi-button-negative:hover:not(:disabled),
.cbi-modal .cbi-button-reset:hover:not(:disabled) {
    background: rgba(255, 69, 58, 0.16) !important;
    border-color: rgba(255, 69, 58, 0.45) !important;
    color: var(--danger) !important;
}

.btn-sm {
    padding: 4px 10px !important;
    font-size: 12px !important;
    border-radius: var(--r-xs) !important;
}

.btn-icon {
    padding: 6px !important;
    border: none !important;
    background: transparent !important;
    border-radius: var(--r-xs) !important;
    color: var(--text2) !important;
    box-shadow: none !important;
    transition: background var(--transition), color var(--transition), transform 80ms ease-out !important;
}
.btn-icon:hover {
    background: var(--hover) !important;
    color: var(--text) !important;
}
.btn-icon:active {
    transform: scale(0.92) !important;
}
.btn-group {
    display: flex;
    gap: 4px;
    align-items: center;
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
    background: var(--tachyon-accent);
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
/* Toast (Tachyon-UI Native Card above all Modals & Overlays) */
.toast-container {
    position: fixed !important;
    bottom: 24px !important;
    right: 24px !important;
    left: auto !important;
    transform: none !important;
    display: flex !important;
    flex-direction: column !important;
    align-items: flex-end !important;
    gap: 8px !important;
    z-index: 2147483647 !important;
    pointer-events: none !important;
    font-family: var(--sans, system-ui, sans-serif) !important;
}

.toast {
    pointer-events: auto !important;
    opacity: 0;
    transform: translateY(8px) scale(0.98);
    transition: opacity 0.2s cubic-bezier(0.22, 1, 0.36, 1), transform 0.2s cubic-bezier(0.22, 1, 0.36, 1);
    padding: 9px 14px !important;
    border-radius: 9px !important;
    background: rgba(22, 22, 26, 0.96) !important;
    border: 1px solid rgba(255, 255, 255, 0.14) !important;
    color: var(--text, #f5f5f7) !important;
    font-size: 12.5px !important;
    font-weight: 500 !important;
    line-height: 1.35 !important;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.65), inset 0 1px 0 rgba(255, 255, 255, 0.08) !important;
    min-width: 180px;
    max-width: 420px;
    text-align: left !important;
    display: inline-flex !important;
    align-items: center !important;
    gap: 9px !important;
    cursor: pointer;
}

.toast-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    background: #30d158;
}

.toast-dot-success {
    background: #30d158;
}

.toast-dot-error {
    background: #ff453a;
}

.toast-dot-warning {
    background: #ff9f0a;
}

.toast-dot-info {
    background: #0a84ff;
}

.toast-success {
    background: rgba(22, 22, 26, 0.96) !important;
    border-color: rgba(48, 209, 88, 0.42) !important;
}

.toast-error {
    background: rgba(22, 22, 26, 0.96) !important;
    border-color: rgba(255, 69, 58, 0.45) !important;
}

.toast-warning {
    background: rgba(22, 22, 26, 0.96) !important;
    border-color: rgba(255, 159, 10, 0.42) !important;
}

.toast-info {
    background: rgba(22, 22, 26, 0.96) !important;
    border-color: rgba(10, 132, 255, 0.42) !important;
}

.toast.visible {
    opacity: 1;
    transform: translateY(0) scale(1);
}

/* Suppress LuCI top-level alerts & restyle in-modal/in-view .alert-message as compact Tachyon-UI cards */
#maincontent > .alert-message,
#maincontent > .notice,
#view > .alert-message,
#uci-apply-status {
    display: none !important;
}

#modal_overlay .alert-message,
.cbi-modal .alert-message,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message,
.tachyon-view .alert-message {
    background: #16161a !important;
    color: var(--text, #f5f5f7) !important;
    border: 1px solid rgba(255, 255, 255, 0.1) !important;
    border-radius: 8px !important;
    padding: 8px 12px !important;
    margin: 0 0 10px 0 !important;
    font-size: 12.5px !important;
    line-height: 1.4 !important;
    box-shadow: none !important;
    text-shadow: none !important;
}

#modal_overlay .alert-message.success,
.cbi-modal .alert-message.success,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.success {
    background: rgba(48, 209, 88, 0.08) !important;
    border-color: rgba(48, 209, 88, 0.28) !important;
    color: #d1fae5 !important;
}

#modal_overlay .alert-message.warning,
.cbi-modal .alert-message.warning,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.warning {
    background: rgba(255, 159, 10, 0.08) !important;
    border-color: rgba(255, 159, 10, 0.3) !important;
    color: #fef3c7 !important;
}

#modal_overlay .alert-message.danger,
#modal_overlay .alert-message.error,
.cbi-modal .alert-message.danger,
.cbi-modal .alert-message.error,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.danger,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.error {
    background: rgba(255, 69, 58, 0.09) !important;
    border-color: rgba(255, 69, 58, 0.32) !important;
    color: #fee2e2 !important;
}

#modal_overlay .alert-message.info,
#modal_overlay .alert-message.notice,
.cbi-modal .alert-message.info,
.cbi-modal .alert-message.notice,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.info,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .alert-message.notice {
    background: rgba(10, 132, 255, 0.08) !important;
    border-color: rgba(10, 132, 255, 0.28) !important;
    color: #dbeafe !important;
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

/* LuCI & CBI dropdown menu viewport containment */
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-dropdown,
.tachyon-view .cbi-dropdown,
#modal_overlay .cbi-dropdown,
.cbi-modal .cbi-dropdown {
    position: relative !important;
    display: flex !important;
    align-items: center !important;
    flex-wrap: nowrap !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-dropdown > ul,
.tachyon-view .cbi-dropdown > ul,
#modal_overlay .cbi-dropdown > ul,
.cbi-modal .cbi-dropdown > ul {
    flex: 1 1 auto !important;
    min-width: 0 !important;
    margin: 0 !important;
    padding-right: 28px !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-dropdown > .open,
.tachyon-view .cbi-dropdown > .open,
#modal_overlay .cbi-dropdown > .open,
.cbi-modal .cbi-dropdown > .open {
    position: absolute !important;
    right: 10px !important;
    top: 50% !important;
    transform: translateY(-50%) !important;
    pointer-events: none !important;
    font-size: 11px !important;
    line-height: 1 !important;
    opacity: 0.72 !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-dropdown[open] > ul,
.tachyon-view .cbi-dropdown[open] > ul,
#modal_overlay .cbi-dropdown[open] > ul,
.cbi-modal .cbi-dropdown[open] > ul,
.cbi-dropdown[open] > ul.dropdown,
.cbi-dropdown[open] > ul,
.cbi-dynlist .cbi-dropdown[open] > ul {
    width: 100% !important;
    max-width: min(100%, calc(100vw - 40px)) !important;
    max-height: min(320px, 45vh);
    overflow-x: hidden !important;
    overflow-y: auto !important;
    overscroll-behavior: contain !important;
    z-index: 2500 !important;
    box-sizing: border-box !important;
    -webkit-overflow-scrolling: touch;
}

#modal_overlay .cbi-dropdown[open] > ul > li,
.cbi-modal .cbi-dropdown[open] > ul > li,
.cbi-dynlist .cbi-dropdown[open] > ul > li {
    white-space: normal !important;
    overflow-wrap: anywhere !important;
    word-break: break-word !important;
    line-height: 1.35 !important;
    padding: 7px 10px !important;
}

/* Tachyon modal sizing by content type */

/* General Tachyon modals: crisp compact width on desktop, full-width on mobile */
.modal:has([class*="tachyon"]),
.cbi-modal:has([class*="tachyon"]) {
    width: min(94vw, 680px) !important;
    max-width: min(94vw, 680px) !important;
    box-sizing: border-box;
    margin: 12px auto 24px auto !important;
}

/* Compact modals: UrlTest details, priority info, icon picker */
.modal:has(.tachyon_dashboard-page__urltest-details),
.cbi-modal:has(.tachyon_dashboard-page__urltest-details) {
    width: min(94vw, 600px) !important;
    max-width: min(94vw, 600px) !important;
    box-sizing: border-box;
    margin: 12px auto 24px auto !important;
}

#modal_overlay > .modal:has(.tachyon-switch-history) {
    max-width: min(94vw, 680px) !important;
}

.tachyon-switch-history {
    color: var(--text);
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon-switch-history__controls {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-block: 8px 12px;
}

.tachyon-switch-history__controls select {
    flex: 1 1 130px;
    min-width: 0;
    max-width: 100%;
}

.tachyon-switch-history__status:not(:empty) {
    color: var(--text2);
    padding-block: 8px;
}

.tachyon-switch-history__list {
    max-height: min(60vh, 480px);
    overflow: auto;
    overscroll-behavior: contain;
}

.tachyon-switch-history__event {
    border-top: 1px solid var(--border-strong);
    padding: 10px 8px;
}

.tachyon-switch-history__event summary {
    cursor: pointer;
    font-size: 13px;
}

.tachyon-switch-history__meta,
.tachyon-switch-history__route {
    display: flex;
    flex-wrap: wrap;
    gap: 4px 10px;
}

.tachyon-switch-history__meta {
    color: var(--text2);
    font-size: 12px;
}

.tachyon-switch-history__meta:first-child {
    display: inline-flex;
    max-width: calc(100% - 22px);
}

.tachyon-switch-history__route {
    margin-block: 4px;
}

.tachyon-switch-history__details {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 2fr);
    gap: 6px 12px;
    margin: 10px 0 0;
    padding: 10px 0 2px;
    border-top: 1px solid var(--border);
    font-size: 12px;
}

.tachyon-switch-history__details dt {
    color: var(--text2);
}

.tachyon-switch-history__details dd {
    margin: 0;
}

/* Medium modals: Support, Service check, DNS benchmark, Updates, AI Chat, Server info */
.modal:has(.tachyon-support-modal),
.cbi-modal:has(.tachyon-support-modal),
.modal:has(.tachyon-service-check-modal),
.cbi-modal:has(.tachyon-service-check-modal),
.modal:has(.tachyon-service-check-modal-wrapper),
.cbi-modal:has(.tachyon-service-check-modal-wrapper),
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
    width: min(94vw, 760px) !important;
    max-width: min(94vw, 760px) !important;
    box-sizing: border-box;
    margin: 12px auto 24px auto !important;
}

.modal .fkp-server-info-modal,
.cbi-modal .fkp-server-info-modal {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box;
    margin: 0 !important;
}

/* Wide modals: Strategy Fuzzer, Leak detection, Route Explainer, Stability */
.modal:has(.tachyon-strategy-fuzzer-modal),
.cbi-modal:has(.tachyon-strategy-fuzzer-modal),
.modal:has(.tachyon_fuzzer_modal),
.cbi-modal:has(.tachyon_fuzzer_modal),
.modal:has(.tachyon-leak-check-modal),
.cbi-modal:has(.tachyon-leak-check-modal),
.modal:has(.tachyon-route-explain-modal),
.cbi-modal:has(.tachyon-route-explain-modal),
.modal:has(.tachyon-stability-modal),
.cbi-modal:has(.tachyon-stability-modal),
.modal:has(.tachyon_stability-modal),
.cbi-modal:has(.tachyon_stability-modal) {
    width: min(96vw, 920px) !important;
    max-width: min(96vw, 920px) !important;
    box-sizing: border-box;
    margin: 12px auto 24px auto !important;
}

.tachyon-leak-check-modal .cbi-section-table th,
.tachyon-leak-check-modal .cbi-section-table .th,
.tachyon-route-explain-modal .cbi-section-table th,
.tachyon-route-explain-modal .cbi-section-table .th {
    white-space: normal !important;
    line-height: 1.25;
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

/* Phones: edge-to-edge inside modal overlay without vw scrollbar overflow */
@media (max-width: 640px) {
    .modal:has([class*="tachyon"]),
    .cbi-modal:has([class*="tachyon"]),
    .modal:has(.fkp-server-info-modal),
    .cbi-modal:has(.fkp-server-info-modal) {
        width: 100% !important;
        max-width: 100% !important;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
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
    border-radius: 10px;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.12));
    background: var(--surface, #16161a);
    color: var(--text, #f5f5f7);
    box-shadow: 0 14px 36px rgba(0, 0, 0, 0.65);
    z-index: 2500;
}

.tachyon-lang-menu[hidden] {
    display: none !important;
}

.tachyon-lang-menu__header {
    padding: 4px 8px 6px;
    font-size: 11px;
    font-weight: 600;
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
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
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
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 4px;
    white-space: nowrap;
}

.tachyon-lang-option__badge--active {
    color: var(--tachyon-accent-text, #5b21b6);
}

.tachyon-lang-option__badge--install {
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text, #5b21b6);
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
.tachyon-workspace-body .cbi-tabmenu:not(.tachyon-sec-modal-tabs):not(.tachyon-section-subtabs):not(.tachyon-clients-subtabs):not(#cbi-tachyon-settings .cbi-tabmenu),
.tachyon-main-workspace > .cbi-tabmenu,
.cbi-map-tabbed > .cbi-tabmenu,
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

#cbi-tachyon .cbi-map-tabbed > .cbi-section[data-tab-active="false"],
#cbi-tachyon .cbi-map-tabbed > .cbi-section.cbi-tab-disabled,
#cbi-tachyon .tachyon-workspace-body > .cbi-section[data-tab-active="false"],
#cbi-tachyon .tachyon-workspace-body > .cbi-section.cbi-tab-disabled,
#cbi-tachyon .cbi-section[id^="cbi-tachyon-"][data-tab-active="false"],
#cbi-tachyon .cbi-section[id^="cbi-tachyon-"].cbi-tab-disabled,
#cbi-tachyon .cbi-section-node-tabbed > [data-tab][data-tab-active="false"],
#cbi-tachyon .cbi-section-node-tabbed > [data-tab].cbi-tab-disabled,
.cbi-map-tabbed > .cbi-section[data-tab-active="false"],
.cbi-map-tabbed > .cbi-section.cbi-tab-disabled,
.tachyon-workspace-body > .cbi-section[data-tab-active="false"],
.tachyon-workspace-body > .cbi-section.cbi-tab-disabled {
    display: none !important;
    pointer-events: none !important;
    padding: 0 !important;
    margin: 0 !important;
    border: none !important;
}

/* Keep LuCI top navigation bar and its dropdown menus above Tachyon stacking contexts */
body > header,
#topmenu,
#mainmenu,
body > header .dropdown-menu {
    z-index: 1200 !important;
}

/* Neutralize OpenWrt Bootstrap sticky header rules on inner <header> elements inside Tachyon cards */
#cbi-tachyon header,
.tachyon-shell-layout header {
    position: static !important;
    top: auto !important;
    z-index: auto !important;
    box-shadow: none !important;
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

.cbi-page-actions:not(.modal .cbi-page-actions),
#view > .cbi-page-actions,
#cbi-tachyon ~ .cbi-page-actions {
    display: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"],
#cbi-tachyon[data-sidebar-pos="top"] > .tachyon-shell-layout {
    flex-direction: column;
    gap: 10px;
}

.tachyon-shell-layout[data-sidebar-pos="top"] > .tachyon-main-workspace,
#cbi-tachyon[data-sidebar-pos="top"] > .tachyon-shell-layout > .tachyon-main-workspace {
    width: 100% !important;
    max-width: 100% !important;
    flex: 1 1 auto !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar {
    width: 100% !important;
    min-width: 0 !important;
    min-height: 52px !important;
    max-height: none !important;
    overflow: visible !important;
    position: relative !important;
    top: auto !important;
    z-index: 400 !important;
    background: var(--topbar-glass, rgba(20, 20, 22, 0.94)) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    border-radius: 12px !important;
}

@media (min-width: 861px) {
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar {
        flex-direction: row !important;
        flex-wrap: wrap !important;
        align-items: center !important;
        justify-content: space-between !important;
        gap: 8px 12px !important;
        padding: 10px 14px 8px !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__brand,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand {
        order: 1;
        border-right: none !important;
        padding: 0 !important;
        flex: 0 0 auto !important;
        gap: 8px !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer {
        order: 2;
        margin-left: auto !important;
        flex: 0 1 auto !important;
        flex-wrap: wrap !important;
        justify-content: flex-end !important;
        align-items: center !important;
        gap: 6px !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav {
        order: 3;
        flex: 1 0 100% !important;
        width: 100% !important;
        min-width: 0 !important;
        display: flex !important;
        flex-direction: row !important;
        align-items: center !important;
        flex-wrap: nowrap !important;
        gap: 4px !important;
        padding: 8px 0 0 !important;
        margin: 0 !important;
        border-top: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
        overflow-x: auto !important;
        scrollbar-width: none !important;
    }
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__brand,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand {
    border-bottom: none !important;
    margin-bottom: 0 !important;
    border-right: none !important;
    padding: 0 !important;
    width: auto !important;
    flex: 0 0 auto !important;
    flex-direction: row !important;
    align-items: center !important;
    gap: 8px !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__brand-sub,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand-sub {
    display: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__collapse-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__collapse-btn {
    display: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav {
    display: flex !important;
    flex-direction: row !important;
    align-items: center !important;
    flex-wrap: nowrap !important;
    gap: 4px !important;
    min-width: 0 !important;
    background: transparent !important;
    border-radius: 0 !important;
    border-left: none !important;
    border-right: none !important;
    border-bottom: none !important;
    overflow-x: auto !important;
    scrollbar-width: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav::-webkit-scrollbar,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav::-webkit-scrollbar {
    display: none;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__menu-block,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__menu-block {
    position: relative !important;
    width: auto !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-item,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-item {
    width: auto !important;
    height: 34px !important;
    flex-shrink: 0 !important;
    white-space: nowrap !important;
    padding: 0 12px !important;
    border-radius: 8px !important;
    justify-content: flex-start !important;
    gap: 7px !important;
    font-size: 13px !important;
    font-weight: 500 !important;
    color: var(--text2, #a1a1a6) !important;
    background: transparent !important;
    border: 1px solid transparent !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-item:hover,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-item:hover {
    color: var(--text, #f5f5f7) !important;
    background: var(--hover, rgba(255, 255, 255, 0.05)) !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-item.is-active,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-item.has-active-child,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-item.is-active,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-item.has-active-child {
    color: var(--text, #f5f5f7) !important;
    background: var(--elevated, #222227) !important;
    border-color: var(--border-strong, rgba(255, 255, 255, 0.14)) !important;
    font-weight: 600 !important;
    box-shadow: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-label,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__brand-text,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__status-label,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-label,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand-text,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__status-label {
    display: inline-flex !important;
    flex: 0 0 auto !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__chevron,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__submenu,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-count,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__chevron,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__submenu,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__nav-count {
    display: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer {
    display: flex !important;
    align-items: center !important;
    justify-content: flex-end !important;
    flex-wrap: wrap !important;
    gap: 6px !important;
    width: auto !important;
    flex: 0 1 auto !important;
    margin-left: auto !important;
    margin-top: 0 !important;
    padding-top: 0 !important;
    border-top: none !important;
    flex-direction: row !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__status-card,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__status-card {
    width: auto !important;
    flex: 0 0 auto !important;
    flex-direction: row !important;
    align-items: center !important;
    gap: 6px !important;
    height: 26px !important;
    padding: 0 9px !important;
    margin-left: 2px !important;
    border-radius: 999px !important;
    background: var(--hover, rgba(255, 255, 255, 0.04)) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__status-row,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__status-row {
    gap: 6px !important;
    font-size: 11.5px !important;
    line-height: 1 !important;
    white-space: nowrap !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__status-meta,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__status-meta {
    display: none !important;
}

.tachyon-topbar__divider {
    width: 1px;
    height: 18px;
    background: var(--border, rgba(255, 255, 255, 0.08));
    flex-shrink: 0;
    margin: 0 2px;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__service-controls,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__service-controls {
    gap: 4px !important;
    flex-shrink: 0 !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__icon-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__service-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__wizard-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__sidebar-pos-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-lang-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__icon-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__service-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__wizard-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__sidebar-pos-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-lang-btn {
    height: 30px !important;
    padding: 0 10px !important;
    box-sizing: border-box !important;
    border-radius: 8px !important;
    white-space: nowrap !important;
    flex-shrink: 0 !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__service-btn--restart,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__service-btn--restart,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__sidebar-pos-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__sidebar-pos-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__logout-btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__logout-btn,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-history-btn--icon,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-history-btn--icon {
    width: 30px !important;
    padding: 0 !important;
    justify-content: center !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar__service-btn--restart > span,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar__service-btn--restart > span {
    display: none !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-mode-switcher,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-mode-switcher {
    height: 30px !important;
    padding: 2px !important;
    border-radius: 8px !important;
    box-sizing: border-box !important;
    flex-shrink: 0 !important;
}

.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-mode-switcher__btn,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-mode-switcher__btn {
    height: 24px !important;
    padding: 0 8px !important;
    border-radius: 6px !important;
    font-size: 11.5px !important;
    display: inline-flex !important;
    align-items: center !important;
}

@media (max-width: 1180px) and (min-width: 861px) {
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-kbd,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-kbd,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-theme-trigger__name,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-theme-trigger__name {
        display: none !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-theme-trigger,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-theme-trigger {
        padding: 0 8px !important;
    }
}

@media (max-width: 1020px) and (min-width: 861px) {
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-trigger > span,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-trigger > span {
        display: none !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-trigger,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__footer .tachyon-cmdk-trigger {
        width: 30px !important;
        padding: 0 !important;
        justify-content: center !important;
    }
}

.tachyon-topbar.tachyon-topbar--subnav {
    background: transparent !important;
    border: none !important;
    padding: 0 !important;
    border-radius: 0 !important;
    min-height: 0 !important;
    box-shadow: none !important;
    z-index: 25 !important;
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-subnav-actions {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
}

.tachyon-sidebar {
    width: 220px;
    min-width: 220px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    background: rgba(14, 14, 16, 0.92);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 12px;
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
    gap: 8px;
    padding: 6px 8px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    margin-bottom: 8px;
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
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: transparent;
    color: inherit;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    opacity: 0.75;
    flex-shrink: 0;
}

.tachyon-sidebar__collapse-btn:hover {
    opacity: 1;
    background: rgba(255, 255, 255, 0.05);
}

.tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text,
#cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text {
    display: none;
}

.tachyon-sidebar__brand-title {
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.018em;
    color: var(--text, #f5f5f7);
}

.tachyon-sidebar__brand-sub {
    font-size: 11px;
    color: #6e6e73;
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
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 32%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent) !important;
    color: var(--tachyon-accent-text) !important;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    box-shadow: none !important;
    transition: background-color 0.15s ease, border-color 0.15s ease;
}

.tachyon-sidebar__wizard-btn:hover,
.tachyon-sidebar__wizard-btn:focus {
    background: color-mix(in srgb, var(--tachyon-accent) 20%, transparent) !important;
    border-color: color-mix(in srgb, var(--tachyon-accent) 45%, transparent) !important;
    box-shadow: none !important;
}

.tachyon-sidebar__wizard-btn-plus {
    font-size: 16px;
    line-height: 1;
    font-weight: 600;
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
    gap: 2px;
    flex: 1;
    width: 100%;
    background: #0b0b0c;
    padding: 4px;
    border-radius: 10px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-sizing: border-box;
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
    font-weight: 600;
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
    gap: 8px;
    width: 100%;
    padding: 6px 11px;
    border: none;
    border-radius: 7px;
    background: transparent;
    color: #a1a1a6;
    font-size: 13px;
    font-weight: 500;
    text-align: left;
    cursor: pointer;
    box-sizing: border-box;
    transition: background-color 0.14s ease, color 0.14s ease;
}

.tachyon-sidebar__item svg,
.tachyon-sidebar__nav-item svg {
    width: 15px;
    height: 15px;
    flex-shrink: 0;
    opacity: 0.85;
}

.tachyon-sidebar__item:hover,
.tachyon-sidebar__nav-item:hover {
    background: rgba(255, 255, 255, 0.04);
    color: #f5f5f7;
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
    background: #26262b !important;
    border: none !important;
    color: #f5f5f7 !important;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.08) !important;
    font-weight: 500 !important;
}

.tachyon-sidebar__item.is-active svg,
.tachyon-sidebar__nav-item.is-active svg {
    opacity: 1;
}

.tachyon-sidebar__nav-parent {
    color: var(--text, #f5f5f7);
    font-weight: 600;
}

.tachyon-sidebar__nav-parent.has-active-child,
.tachyon-sidebar__nav-parent.has-active-child:hover,
.tachyon-sidebar__nav-parent.has-active-child:focus {
    background: rgba(10, 132, 255, 0.08) !important;
    border-color: transparent !important;
    color: var(--text, #f5f5f7) !important;
    box-shadow: none !important;
    font-weight: 600;
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
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    padding: 1px 6px;
    border-radius: 999px;
    background: var(--elevated, #252836);
    color: var(--text3, #6e6e73);
}

.tachyon-sidebar__chevron {
    flex-shrink: 0;
    opacity: 0.65;
    transform: rotate(-90deg);
    transition: transform var(--transition), opacity var(--transition);
}

.tachyon-sidebar__chevron.is-open {
    transform: rotate(0deg);
    opacity: 0.95;
}

.tachyon-sidebar__submenu {
    display: none;
    flex-direction: column;
    gap: 2px;
    margin: 2px 0 6px 0;
    padding-left: 0;
    border-left: none !important;
}

.tachyon-sidebar__submenu.is-open {
    display: flex;
}

.tachyon-sidebar__subitem {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 6px 10px 6px 28px;
    border: 1px solid transparent;
    border-radius: var(--r-btn, 8px);
    background: transparent;
    color: var(--text2, #a1a1a6);
    font-size: 12.5px;
    font-weight: 500;
    text-align: left;
    cursor: pointer;
    box-sizing: border-box;
    transition: background-color var(--transition), color var(--transition);
}

.tachyon-sidebar__subitem:hover {
    color: var(--text, #f5f5f7);
    background: var(--hover, #1f222e);
    border-color: transparent !important;
    box-shadow: none !important;
}

.tachyon-sidebar__subitem.is-active,
.tachyon-sidebar__subitem.is-active:hover,
.tachyon-sidebar__subitem.is-active:focus {
    font-weight: 600;
    color: var(--text, #f5f5f7) !important;
    background: var(--elevated, #252836) !important;
    border-color: var(--border-strong, rgba(255, 255, 255, 0.14)) !important;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.08) !important;
}

.tachyon-sidebar__subitem-dot {
    display: none !important;
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

.tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__item-label,
.tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__nav-label,
.tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__nav-count,
.tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__chevron,
.tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__submenu,
#cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__nav-label,
#cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__nav-count,
#cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__chevron,
#cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar__submenu {
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
    font-weight: 600;
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
    position: relative !important;
    top: auto !important;
    left: auto !important;
    right: auto !important;
    z-index: 390;
    overflow: visible !important;
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
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent-text, #5b21b6);
    opacity: 1;
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-topbar__eco-btn.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
}

.tachyon-topbar__eco-btn:disabled {
    opacity: 0.6;
    cursor: wait;
}

.tachyon-topbar__service-controls {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon-topbar__service-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
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

.tachyon-topbar__service-btn--start {
    border-color: rgba(16, 185, 129, 0.4);
    background: rgba(16, 185, 129, 0.14);
    color: #34d399;
}

.tachyon-topbar__service-btn--start:hover {
    border-color: rgba(16, 185, 129, 0.6);
    background: rgba(16, 185, 129, 0.22);
}

.tachyon-topbar__service-btn--stop {
    border-color: rgba(239, 68, 68, 0.36);
    background: rgba(239, 68, 68, 0.12);
    color: #f87171;
}

.tachyon-topbar__service-btn--stop:hover {
    border-color: rgba(239, 68, 68, 0.56);
    background: rgba(239, 68, 68, 0.2);
}

.tachyon-topbar__service-btn--restart:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
}

.tachyon-topbar__service-btn--busy {
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.12);
    color: #fbbf24;
    cursor: wait;
    opacity: 0.9;
}

.tachyon-topbar__wizard-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 11px;
    border-radius: 8px;
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 36%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-size: 12px;
    font-weight: 600;
    white-space: nowrap;
    cursor: pointer;
}

.tachyon-topbar__wizard-btn:hover {
    background: color-mix(in srgb, var(--tachyon-accent) 22%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 48%, transparent);
}

.tachyon-topbar__lang-slot .tachyon-lang-switcher {
    margin-left: 0;
}

.tachyon-topbar__collapse-btn {
    min-width: 28px;
    padding: 4px 8px;
    font-size: 11px;
    line-height: 1;
}

.tachyon-topbar.is-collapsed,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar {
    padding: 4px 10px;
}

.tachyon-topbar.is-collapsed .tachyon-topbar__left,
.tachyon-topbar.is-collapsed .tachyon-topbar__wizard-btn,
.tachyon-topbar.is-collapsed .tachyon-topbar__sidebar-pos-btn,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar__left,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar__wizard-btn,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar__sidebar-pos-btn,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar__left,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar__wizard-btn,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar__sidebar-pos-btn {
    display: none !important;
}

.tachyon-topbar.is-collapsed .tachyon-topbar__right,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar__right,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar__right {
    margin-left: auto;
}

/* Top-right Close (✕) header and footer for all Tachyon modals (1:1 tachyon-ui) */
#modal_overlay > .modal:has(> .tachyon-modal__sticky-header),
.cbi-modal:has(> .tachyon-modal__sticky-header),
.modal:has(> .tachyon-modal__sticky-header) {
    background-color: var(--surface, #141416) !important;
    color: var(--text, #f5f5f7) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
}

#modal_overlay > .modal > h4.tachyon-modal__sticky-header,
#modal_overlay > .modal > h3.tachyon-modal__sticky-header,
.cbi-modal > h4.tachyon-modal__sticky-header,
.cbi-modal > h3.tachyon-modal__sticky-header,
.modal > h4.tachyon-modal__sticky-header,
.modal > h3.tachyon-modal__sticky-header {
    position: relative !important;
    top: auto !important;
    z-index: 2 !important;
    display: flex !important;
    align-items: center !important;
    justify-content: space-between !important;
    gap: 10px !important;
    background: transparent !important;
    color: var(--text, #f5f5f7) !important;
    font-size: 15px !important;
    font-weight: 600 !important;
    letter-spacing: -0.012em !important;
    margin: 0 0 14px 0 !important;
    padding: 0 0 12px 0 !important;
    border-radius: 0 !important;
    border-bottom: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
}

/* Clean textarea & form control corners across third-party LuCI themes */
[id^="cbi-${TACHYON_CBI_PREFIX}"] textarea,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-textarea,
.tachyon-view textarea,
.tachyon-view .cbi-input-textarea,
#modal_overlay textarea,
#modal_overlay .cbi-input-textarea,
.cbi-modal textarea,
.cbi-modal .cbi-input-textarea {
    background-color: var(--bg, #0b0b0c) !important;
    color: var(--text, #f5f5f7) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    border-radius: var(--r-btn, 8px) !important;
    background-clip: padding-box !important;
    outline: none !important;
    box-shadow: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] textarea:focus,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-textarea:focus,
.tachyon-view textarea:focus,
.tachyon-view .cbi-input-textarea:focus,
#modal_overlay textarea:focus,
#modal_overlay .cbi-input-textarea:focus,
.cbi-modal textarea:focus,
.cbi-modal .cbi-input-textarea:focus {
    border-color: var(--accent, #0a84ff) !important;
    box-shadow: 0 0 0 3px rgba(10, 132, 255, 0.18) !important;
}

.fkp-annotated-textarea {
    position: relative;
    background-color: var(--bg, #0b0b0c) !important;
    border-radius: var(--r-btn, 8px) !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] .fkp-annotated-textarea > textarea,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .fkp-annotated-textarea > .cbi-input-textarea,
.tachyon-view .fkp-annotated-textarea > textarea,
.tachyon-view .fkp-annotated-textarea > .cbi-input-textarea,
#modal_overlay .fkp-annotated-textarea > textarea,
#modal_overlay .fkp-annotated-textarea > .cbi-input-textarea,
.cbi-modal .fkp-annotated-textarea > textarea,
.cbi-modal .fkp-annotated-textarea > .cbi-input-textarea,
.fkp-annotated-textarea > textarea {
    position: relative !important;
    z-index: 1 !important;
    background: transparent !important;
    background-color: transparent !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] textarea::-webkit-resizer,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-textarea::-webkit-resizer,
.tachyon-view textarea::-webkit-resizer,
#modal_overlay textarea::-webkit-resizer,
.cbi-modal textarea::-webkit-resizer {
    display: none !important;
    background: transparent !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"] textarea::-webkit-scrollbar-corner,
[id^="cbi-${TACHYON_CBI_PREFIX}"] .cbi-input-textarea::-webkit-scrollbar-corner,
#modal_overlay textarea::-webkit-scrollbar-corner,
.cbi-modal textarea::-webkit-scrollbar-corner {
    background: transparent !important;
}

.tachyon-modal__header-close {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    width: 28px !important;
    height: 28px !important;
    padding: 6px !important;
    margin-left: auto !important;
    flex-shrink: 0 !important;
    border-radius: var(--r-xs, 6px) !important;
    border: none !important;
    background: transparent !important;
    box-shadow: none !important;
    color: var(--text2, #a1a1a6) !important;
    font-size: 14px !important;
    font-weight: 500 !important;
    line-height: 1 !important;
    cursor: pointer !important;
    transition: background var(--transition), color var(--transition), transform 80ms ease-out !important;
}

.tachyon-modal__header-close:hover {
    background: var(--hover, #1c1c1f) !important;
    border: none !important;
    color: var(--text, #f5f5f7) !important;
}

.tachyon-modal__header-close:active {
    transform: scale(0.92) !important;
}

.tachyon-sec-modal__footer,
.tachyon-partial-modal__footer {
    position: sticky;
    bottom: 0;
    z-index: 25;
    background: var(--surface, #141416);
    padding-bottom: 4px;
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
    font-weight: 600;
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
    font-weight: 600;
    line-height: 1.15;
    letter-spacing: -0.01em;
    white-space: nowrap;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    font-variant-numeric: tabular-nums;
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
    gap: 6px 12px;
    padding: 6px 12px !important;
    border-radius: 4px;
    background: #111114;
    border: 1px solid #222228;
    box-sizing: border-box;
    width: 100%;
}

.tachyon-router-services-bar__title {
    font-size: 11px;
    font-weight: 600;
    color: #8b8b94;
    letter-spacing: 0.02em;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon-router-services-bar__list {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 4px 0;
    flex: 1 1 auto;
    min-width: 0;
}

@media (min-width: 900px) {
    .tachyon-router-services-bar,
    .tachyon-router-services-bar__list {
        flex-wrap: nowrap;
    }
}

.tachyon-router-services-bar__item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 2px 12px;
    border-radius: 0;
    background: transparent !important;
    border: none !important;
    border-left: 1px solid #222228 !important;
    font-size: 12px;
    white-space: nowrap;
    min-width: 0;
}

.tachyon-router-services-bar__item:first-child {
    padding-left: 0;
    border-left: none !important;
}

.tachyon-router-services-bar__item:last-child {
    padding-right: 0;
}

.tachyon-router-services-bar .tachyon-service-pill,
.tachyon-router-services-bar .tachyon-service-pill--ram,
.tachyon-router-services-bar .tachyon-service-pill--uptime {
    width: auto !important;
    min-width: 0 !important;
    height: auto !important;
    padding: 0 !important;
    border: none !important;
    border-radius: 0 !important;
    background: transparent !important;
    font-family: "JetBrains Mono", "SF Mono", ui-monospace, monospace;
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon-router-services-bar .tachyon-service-pill--ram {
    color: #e4e4e7 !important;
    font-weight: 500;
}

.tachyon-router-services-bar .tachyon-service-pill--uptime {
    color: #71717a !important;
    font-weight: 400;
}

.tachyon-router-services-bar .tachyon-service-pill--uptime::before {
    content: "· ";
    color: #52525b;
}

.tachyon-router-services-bar__item-key {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: #d4d4d8;
    font-weight: 500;
}

.tachyon-router-services-bar__item-val {
    display: inline-flex;
    align-items: center;
    gap: 6px;
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
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-routing-sections-block__actions {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-routing-sections-block__filter-btn {
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

.tachyon-routing-sections-block__filter-btn:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-routing-sections-block__filter-btn.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 48%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-section-order-warning {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid rgba(217, 119, 6, 0.34);
    background: rgba(217, 119, 6, 0.08);
    color: inherit;
    font-size: 12.5px;
    line-height: 1.45;
}

.tachyon-section-order-warning__icon {
    flex-shrink: 0;
    margin-top: 1px;
    color: #d97706;
    display: inline-flex;
    align-items: center;
}

.tachyon-section-order-warning__body {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon-section-order-warning__title {
    font-weight: 600;
    font-size: 12.5px;
    color: inherit;
}

.tachyon-section-order-warning__desc {
    font-size: 12px;
    opacity: 0.88;
}

.tachyon-section-order-warning__btn {
    flex-shrink: 0;
    align-self: center;
    padding: 5px 10px;
    border-radius: 8px;
    border: 1px solid rgba(217, 119, 6, 0.38);
    background: rgba(217, 119, 6, 0.12);
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: background-color 0.14s ease, border-color 0.14s ease;
}

.tachyon-section-order-warning__btn:hover {
    border-color: rgba(217, 119, 6, 0.6);
    background: rgba(217, 119, 6, 0.2);
}

@media (max-width: 640px) {
    .tachyon-section-order-warning {
        flex-wrap: wrap;
    }

    .tachyon-section-order-warning__btn {
        margin-left: 25px;
    }
}

.tachyon-section-types-modal {
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-width: min(520px, 90vw);
}

.tachyon-section-types-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-section-type-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 14px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(148, 163, 184, 0.18));
    background: var(--background-color-low, rgba(128, 128, 128, 0.04));
    cursor: pointer;
    transition: border-color 0.15s ease, background-color 0.15s ease;
}

.tachyon-section-type-card:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 36%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 6%, transparent);
}

.tachyon-section-type-card.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 55%, transparent);
}

.tachyon-section-type-card__info {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
}

.tachyon-section-type-card__icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    border-radius: 8px;
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent);
    flex-shrink: 0;
}

.tachyon-section-type-card__text {
    min-width: 0;
}

.tachyon-section-type-card__title-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-section-type-card__title {
    font-size: 13px;
    font-weight: 600;
    color: inherit;
}

.tachyon-section-type-card__badge {
    font-size: 10px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 6px;
    letter-spacing: 0.02em;
}

.tachyon-section-type-card__badge.is-enabled {
    background: rgba(34, 197, 94, 0.16);
    color: #22c55e;
}

.tachyon-section-type-card__badge.is-disabled {
    background: rgba(148, 163, 184, 0.14);
    color: rgba(148, 163, 184, 0.8);
}

.tachyon-section-type-card__desc {
    font-size: 11px;
    opacity: 0.72;
    margin-top: 3px;
    line-height: 1.35;
}

.tachyon-section-type-card__switch {
    width: 38px;
    height: 22px;
    border-radius: 9999px;
    background: rgba(148, 163, 184, 0.22);
    position: relative;
    flex-shrink: 0;
    transition: background-color 0.2s ease;
}

.tachyon-section-type-card.is-active .tachyon-section-type-card__switch {
    background: var(--tachyon-accent);
}

.tachyon-section-type-card__switch-knob {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: #ffffff;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.25);
    transition: transform 0.2s ease;
}

.tachyon-section-type-card.is-active .tachyon-section-type-card__switch-knob {
    transform: translateX(16px);
}

.tachyon-routing-sections-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-routing-row {
    display: grid;
    grid-template-columns: minmax(0, 2.15fr) minmax(0, 1.05fr) minmax(0, 1.15fr) 84px 58px minmax(108px, max-content);
    align-items: center;
    gap: 8px;
    padding: 9px 11px;
    border-radius: 11px;
    background: var(--tachyon-bg-card-elevated, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--tachyon-border-subtle, rgba(128, 128, 128, 0.18));
    color: var(--tachyon-text-main, inherit);
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 45%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent);
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
    box-shadow: 0 0 0 2px var(--tachyon-accent);
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
    background: #4cc38a;
}

.tachyon-routing-row__status-dot.is-offline {
    background: #e5484d;
}

.tachyon-routing-row__ping--led {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border-radius: 6px;
    background: rgba(76, 195, 138, 0.1);
    border: 1px solid rgba(76, 195, 138, 0.26);
}

.tachyon-routing-row__name {
    font-size: 13px;
    font-weight: 600;
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

.tachyon-routing-row__mobile-node {
    display: none;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    font-weight: 600;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-top: 1px;
}

.tachyon-routing-row__mobile-server {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-color-high, inherit);
}

.tachyon-routing-row__mobile-sep {
    opacity: 0.45;
    flex-shrink: 0;
}

.tachyon-routing-row__mobile-sel {
    font-weight: 500;
    opacity: 0.72;
    flex-shrink: 0;
}

.tachyon-routing-row__status-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 5px;
    font-size: 10px;
    font-weight: 600;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon-routing-row__status-badge.is-active {
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
}

.tachyon-routing-row__status-badge.is-error {
    background: rgba(239, 68, 68, 0.14);
    color: #ef4444;
    border: 1px solid rgba(239, 68, 68, 0.3);
}

.tachyon-routing-row__status-badge.is-hidden {
    background: rgba(148, 163, 184, 0.16);
    color: #64748b;
    border: 1px dashed rgba(148, 163, 184, 0.45);
}

.tachyon-routing-row.is-dashboard-hidden,
.tachyon-routing-matrix-card.is-dashboard-hidden,
.tachyon-routing-compact-tile.is-dashboard-hidden,
.tachyon-routing-bento-card.is-dashboard-hidden {
    opacity: 0.72;
    border-style: dashed;
}

.tachyon-routing-row__engine-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 6px;
    font-size: 10px;
    font-weight: 600;
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
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
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
    font-weight: 600;
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
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
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
    letter-spacing: 0.02em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-routing-row__col-value {
    font-size: 12px;
    font-weight: 600;
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
    font-weight: 600;
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
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
    color: var(--primary-color-high, #0a84ff);
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-routing-row__selector-pill.is-interactive:hover {
    background: color-mix(in srgb, var(--tachyon-accent) 18%, transparent);
    border-color: var(--primary-color-high, var(--tachyon-accent));
    color: var(--primary-color-high, var(--tachyon-accent));
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
    border-radius: 6px;
    font-size: 11px;
    font-weight: 600;
    border: 1px solid transparent;
    cursor: pointer;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
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
    font-weight: 600;
    opacity: 0.55;
    transition: transform 0.16s ease, opacity 0.16s ease;
}

.tachyon-routing-row__chevron.is-selected {
    transform: rotate(90deg);
    opacity: 1;
    color: var(--tachyon-accent-text);
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
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent-text);
    opacity: 1;
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-nodes-autogroup-pill.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
}

.tachyon-nodes-autogroup-pill__badge {
    font-size: 11px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 6px;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent-text);
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
    font-weight: 600;
}

.tachyon-nodes-subbar__fact {
    opacity: 0.78;
}

.tachyon-nodes-subbar__link {
    display: inline-flex;
    align-items: center;
    color: var(--tachyon-accent-text);
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
    border-radius: 6px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.tachyon-nodes-country-pill.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
}

.tachyon-node-card.is-active {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
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
    font-weight: 600;
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
    font-weight: 600;
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
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-variant-numeric: tabular-nums;
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
    color: var(--tachyon-accent-text);
    font-weight: 600;
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
    .tachyon-routing-row__mobile-node {
        display: flex;
    }
    .tachyon-routing-row--has-mobile-node .tachyon-routing-row__subtitle {
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
    width: min(94vw, 840px) !important;
    max-width: min(94vw, 840px) !important;
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
    gap: 10px;
    max-width: 100%;
    width: 100%;
    box-sizing: border-box;
}

.tachyon-wizard__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding-bottom: 8px;
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
    font-weight: 600;
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
    border-radius: 6px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    opacity: 0.72;
}

.tachyon-wizard__step-pill.is-active,
.tachyon-wizard__step.is-active {
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    color: var(--tachyon-accent-text);
    opacity: 1;
    font-weight: 600;
}

.tachyon-wizard__step-pill.is-done {
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 24%, transparent);
    color: var(--tachyon-accent);
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
    font-weight: 600;
    background: rgba(128, 128, 128, 0.18);
}

.tachyon-wizard__step-pill.is-active .tachyon-wizard__step-num {
    background: color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
    color: #e2e8f0;
}

.tachyon-wizard__cards-2col,
.tachyon-wizard__direction-grid {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-wizard__choice-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 8px;
}

.tachyon-wizard__choice-card,
.tachyon-wizard__direction-card,
.tachyon-wizard__proto-card,
.tachyon-wizard__method-card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: flex-start;
    gap: 3px;
    padding: 8px 12px;
    border-radius: 10px;
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
    line-height: 1.3;
    transition: border-color 0.14s ease, background-color 0.14s ease, box-shadow 0.14s ease;
}

.tachyon-wizard__choice-card:hover,
.tachyon-wizard__direction-card:hover,
.tachyon-wizard__proto-card:hover,
.tachyon-wizard__method-card:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-wizard__choice-card.is-selected,
.tachyon-wizard__direction-card.is-selected,
.tachyon-wizard__proto-card.is-selected,
.tachyon-wizard__method-card.is-selected {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
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
    font-weight: 600;
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
    font-weight: 600;
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
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 5px;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
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
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: 6px;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
}

.tachyon-wizard__chip.is-subsumed,
.tachyon-wizard__chip.is-subsumed:hover,
.tachyon-wizard__chip:disabled {
    opacity: 0.42;
    cursor: not-allowed;
    border-style: dashed;
    border-color: var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: rgba(128, 128, 128, 0.04);
    color: var(--text-color-medium, inherit);
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
    font-weight: 600;
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
    font-weight: 600;
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

/* Segmented sub-tab bars (global top subnav + in-page Маршруты, Настройки, Клиенты) */
.tachyon-global-subtabs.cbi-tabmenu,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu,
#cbi-tachyon-settings .cbi-tabmenu,
.tachyon-clients-subtabs.cbi-tabmenu {
    display: inline-flex !important;
    flex-wrap: wrap !important;
    gap: 2px !important;
    padding: 3px !important;
    margin: 0 0 12px 0 !important;
    width: fit-content !important;
    max-width: 100% !important;
    list-style: none !important;
    border-radius: 10px !important;
    background: var(--bg, #0b0b0c) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    box-sizing: border-box !important;
}

.tachyon-global-subtabs.cbi-tabmenu {
    margin: 0 !important;
}

.tachyon-global-subtabs.cbi-tabmenu > li,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li,
#cbi-tachyon-settings .cbi-tabmenu > li,
.tachyon-clients-subtabs.cbi-tabmenu > li,
.tachyon-global-subtabs.cbi-tabmenu > li.cbi-tab-disabled,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li.cbi-tab-disabled,
#cbi-tachyon-settings .cbi-tabmenu > li.cbi-tab-disabled,
.tachyon-clients-subtabs.cbi-tabmenu > li.cbi-tab-disabled {
    flex: 0 0 auto !important;
    width: auto !important;
    max-width: none !important;
    overflow: visible !important;
    opacity: 1 !important;
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    border-radius: 7px !important;
    list-style: none !important;
}

.tachyon-global-subtabs.cbi-tabmenu > li > a,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li > a,
#cbi-tachyon-settings .cbi-tabmenu > li > a,
.tachyon-clients-subtabs.cbi-tabmenu > li > a,
.tachyon-global-subtabs.cbi-tabmenu > li.cbi-tab-disabled > a,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li.cbi-tab-disabled > a,
#cbi-tachyon-settings .cbi-tabmenu > li.cbi-tab-disabled > a,
.tachyon-clients-subtabs.cbi-tabmenu > li.cbi-tab-disabled > a {
    display: inline-flex !important;
    align-items: center !important;
    gap: 6px !important;
    width: auto !important;
    max-width: none !important;
    overflow: visible !important;
    white-space: nowrap !important;
    text-overflow: clip !important;
    opacity: 1 !important;
    padding: 5px 12px !important;
    border-radius: 7px !important;
    font-size: 12.5px !important;
    font-weight: 500 !important;
    line-height: 1.3 !important;
    text-decoration: none !important;
    color: var(--text2, #b8b8c0) !important;
    border: none !important;
    background: transparent !important;
    transition: background var(--transition), color var(--transition) !important;
}

.tachyon-global-subtabs.cbi-tabmenu > li > a:hover,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li > a:hover,
#cbi-tachyon-settings .cbi-tabmenu > li > a:hover,
.tachyon-clients-subtabs.cbi-tabmenu > li > a:hover {
    color: var(--text, #f5f5f7) !important;
    background: var(--hover, #1c1c1f) !important;
}

.tachyon-global-subtabs.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
#cbi-tachyon-section .tachyon-section-subtabs.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
#cbi-tachyon-settings .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.tachyon-clients-subtabs.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a {
    color: var(--text, #f5f5f7) !important;
    background: var(--elevated, #26262b) !important;
    font-weight: 600 !important;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.08) !important;
}

/* In top-bar mode, global subnav replaces duplicate in-page sub-tabs and bulky quickbars */
.tachyon-shell-layout[data-sidebar-pos="top"] #cbi-tachyon-section .tachyon-section-subtabs,
#cbi-tachyon[data-sidebar-pos="top"] #cbi-tachyon-section .tachyon-section-subtabs,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-clients-subtabs,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-clients-subtabs,
.tachyon-shell-layout[data-sidebar-pos="top"] #cbi-tachyon-settings > .cbi-tabmenu,
#cbi-tachyon[data-sidebar-pos="top"] #cbi-tachyon-settings > .cbi-tabmenu,
.tachyon-shell-layout[data-sidebar-pos="top"] #cbi-tachyon-settings > .cbi-section-node > .cbi-tabmenu,
#cbi-tachyon[data-sidebar-pos="top"] #cbi-tachyon-settings > .cbi-section-node > .cbi-tabmenu,
.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-pane-quickbar,
#cbi-tachyon[data-sidebar-pos="top"] .tachyon-pane-quickbar {
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
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-pane-quickbar__wizard-btn {
    padding: 6px 12px;
    border-radius: 8px;
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 36%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.14s ease, border-color 0.14s ease;
}

.tachyon-pane-quickbar__wizard-btn:hover {
    background: color-mix(in srgb, var(--tachyon-accent) 22%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 48%, transparent);
}

/* Segmented Pill Sub-Navigation for Edit Modals, Section Inspector Modal & Accordion */
.modal .cbi-tabmenu,
.cbi-modal .cbi-tabmenu,
.tachyon-sec-modal-tabs.cbi-tabmenu {
    display: inline-flex !important;
    flex-wrap: wrap;
    gap: 3px;
    padding: 3px !important;
    margin: 0 0 10px 0 !important;
    width: fit-content !important;
    max-width: 100% !important;
    list-style: none !important;
    border-radius: 8px !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.1)) !important;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2)) !important;
    box-sizing: border-box !important;
}

.modal .cbi-tabmenu > li,
.cbi-modal .cbi-tabmenu > li,
.tachyon-sec-modal-tabs.cbi-tabmenu > li {
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    border-radius: 6px !important;
}

.modal .cbi-tabmenu > li > a,
.cbi-modal .cbi-tabmenu > li > a,
.tachyon-sec-modal-tabs.cbi-tabmenu > li > a {
    display: inline-flex !important;
    align-items: center;
    padding: 4px 11px !important;
    border-radius: 6px !important;
    font-size: 12px !important;
    font-weight: 600 !important;
    line-height: 1.2 !important;
    text-decoration: none !important;
    color: inherit !important;
    opacity: 0.72;
    border: 1px solid transparent !important;
    background: transparent !important;
    transition: background-color 0.14s ease, opacity 0.14s ease, color 0.14s ease;
}

.modal .cbi-tabmenu > li > a:hover,
.cbi-modal .cbi-tabmenu > li > a:hover,
.tachyon-sec-modal-tabs.cbi-tabmenu > li > a:hover {
    opacity: 1;
    background: rgba(128, 128, 128, 0.08) !important;
}

.modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.tachyon-sec-modal-tabs.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a {
    opacity: 1;
    font-weight: 600 !important;
    color: var(--tachyon-accent-text) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent) !important;
    border-color: color-mix(in srgb, var(--tachyon-accent) 30%, transparent) !important;
    box-shadow: none !important;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-sec-modal__switch-pill.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
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
    font-weight: 600;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 6%, transparent);
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
    font-weight: 600;
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
    font-weight: 600;
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
    font-weight: 600;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 30%, transparent);
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
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
    color: var(--text-color-high, inherit);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 24%, transparent);
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
    font-weight: 600;
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
   Hides expert tabs and low-level knobs
   ========================================================================== */

/* 1. Hide expert modal sub-tabs in Simple Mode */
body[data-tachyon-ui-mode="simple"] .modal .cbi-tabmenu > li[data-tab="advanced"],
body[data-tachyon-ui-mode="simple"] .cbi-modal .cbi-tabmenu > li[data-tab="advanced"] {
    display: none !important;
}

/* ==========================================================================
   Unified Modal Chrome, Segmented Pill Tabs, Form Cards & Settings Lists
   ========================================================================== */

#modal_overlay {
    z-index: 10000 !important;
    background: rgba(0, 0, 0, 0.72) !important;
    padding: 64px 14px 24px 14px !important;
    scroll-padding-top: 64px !important;
    box-sizing: border-box;
}

@media (max-width: 680px) {
    #modal_overlay {
        padding: 48px 8px 16px 8px !important;
        scroll-padding-top: 48px !important;
    }
}

#modal_overlay > .modal,
.modal.cbi-modal,
.cbi-modal {
    background: #111114 !important;
    color: var(--text, #f4f4f5) !important;
    border: 1px solid rgba(255, 255, 255, 0.1) !important;
    border-radius: 6px !important;
    box-shadow: 0 24px 48px rgba(0, 0, 0, 0.65) !important;
    padding: 16px 18px !important;
    margin: 12px auto 24px auto !important;
    max-width: min(880px, 95vw) !important;
    width: 100% !important;
    overflow-x: clip !important;
    box-sizing: border-box !important;
    animation: tachyonModalEnter 0.14s cubic-bezier(0.22, 1, 0.36, 1);
}

#modal_overlay > .modal:has(.cbi-dropdown[open]),
.modal.cbi-modal:has(.cbi-dropdown[open]),
.cbi-modal:has(.cbi-dropdown[open]) {
    overflow: visible !important;
}

#modal_overlay > .modal > h4:not(.tachyon-modal__sticky-header),
.modal.cbi-modal > h4:not(.tachyon-modal__sticky-header),
.cbi-modal > h4:not(.tachyon-modal__sticky-header) {
    margin: 0 0 14px 0 !important;
    padding: 0 0 10px 0 !important;
    font-size: 16px !important;
    font-weight: 700 !important;
    letter-spacing: -0.02em;
    color: var(--text, #f5f5f7) !important;
    border-bottom: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    background: transparent !important;
}

#modal_overlay > .modal > h4:empty,
.modal.cbi-modal > h4:empty,
.cbi-modal > h4:empty {
    display: none !important;
}

/* Segmented Pill Tabmenu inside Modals & Workspace Settings (tachyon-ui .modal-tabs) */
#modal_overlay > .modal .cbi-tabmenu,
.modal.cbi-modal .cbi-tabmenu,
.cbi-modal .cbi-tabmenu {
    display: inline-flex !important;
    flex-wrap: wrap !important;
    gap: 2px !important;
    padding: 3px !important;
    margin: 0 0 14px 0 !important;
    width: fit-content !important;
    max-width: 100% !important;
    height: auto !important;
    max-height: none !important;
    overflow: visible !important;
    list-style: none !important;
    background: var(--bg, #0d0e12) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    border-radius: var(--r-btn, 8px) !important;
}

#modal_overlay > .modal .cbi-tabmenu > li,
.modal.cbi-modal .cbi-tabmenu > li,
.cbi-modal .cbi-tabmenu > li {
    flex: 0 1 auto !important;
    max-width: 100% !important;
    height: auto !important;
    overflow: visible !important;
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
    padding: 5px 12px !important;
    margin: 0 !important;
    max-width: 100% !important;
    height: auto !important;
    white-space: normal !important;
    overflow: visible !important;
    text-overflow: clip !important;
    line-height: 1.25 !important;
    border-radius: 6px !important;
    font-size: 12px !important;
    font-weight: 500 !important;
    text-decoration: none !important;
    color: var(--text3, #6e6e73) !important;
    background: transparent !important;
    border: none !important;
    transition: all var(--transition, 0.14s cubic-bezier(0.22, 1, 0.36, 1)) !important;
}

#modal_overlay > .modal .cbi-tabmenu > li > a:hover,
.modal.cbi-modal .cbi-tabmenu > li > a:hover,
.cbi-modal .cbi-tabmenu > li > a:hover {
    color: var(--text2, #a1a1a6) !important;
}

#modal_overlay > .modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.modal.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a,
.cbi-modal .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled) > a {
    background: var(--elevated, #252836) !important;
    color: var(--text, #f5f5f7) !important;
    border: none !important;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.4), inset 0 1px 0 rgba(255, 255, 255, 0.08) !important;
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

/* Ensure all custom mount nodes (Dashboard, Updates, Diagnostic, Monitoring) span 100% fluid width */
.tachyon-main-workspace,
.tachyon-workspace-body,
.tachyon-workspace-body > .cbi-section,
.tachyon-workspace-body > .cbi-section > .cbi-section-node {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 0 !important;
    box-sizing: border-box !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"],
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] {
    display: block !important;
    width: 100% !important;
    max-width: 100% !important;
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    box-sizing: border-box !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > .cbi-value-title,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > .cbi-value-title {
    display: none !important;
}

[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > output,
[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > .cbi-value-field,
[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > .cbi-value-field > output,
[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > .cbi-value-field > div,
[id^="cbi-${TACHYON_CBI_PREFIX}"][id$="-_mount_node"] > div,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > output,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > .cbi-value-field,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > .cbi-value-field > output,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > .cbi-value-field > div,
.tachyon-workspace-body .cbi-value[id$="-_mount_node"] > div {
    display: block !important;
    width: 100% !important;
    max-width: 100% !important;
    flex: 1 1 100% !important;
    margin: 0 !important;
    padding: 0 !important;
    box-sizing: border-box !important;
}

/* Clean strict list layout for form fields: no left column gap, stacked labels */
#modal_overlay > .modal .cbi-value:not(.hidden),
.cbi-modal .cbi-value:not(.hidden),
.tachyon-workspace-body .cbi-section-node > .cbi-value:not(.hidden):not([id$="-_mount_node"]),
.tachyon-workspace-body .cbi-tabcontainer > [data-tab] > .cbi-value:not(.hidden):not([id$="-_mount_node"]) {
    display: flex !important;
    flex-direction: column !important;
    align-items: stretch !important;
    justify-content: flex-start !important;
    gap: 5px !important;
    padding: 8px 6px !important;
    margin: 0 !important;
    min-height: 0 !important;
    height: auto !important;
    border: none !important;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.13)) !important;
    border-radius: 0 !important;
    background: transparent !important;
    box-sizing: border-box !important;
    width: 100% !important;
}

#modal_overlay > .modal .cbi-value:not(.hidden)::before,
#modal_overlay > .modal .cbi-value:not(.hidden)::after,
.cbi-modal .cbi-value:not(.hidden)::before,
.cbi-modal .cbi-value:not(.hidden)::after,
.tachyon-workspace-body .cbi-value:not(.hidden)::before,
.tachyon-workspace-body .cbi-value:not(.hidden)::after {
    display: none !important;
    content: none !important;
}

#modal_overlay > .modal .cbi-value:not(.hidden):has(> .cbi-value-field > .cbi-checkbox),
.cbi-modal .cbi-value:not(.hidden):has(> .cbi-value-field > .cbi-checkbox),
.tachyon-workspace-body .cbi-value:not(.hidden):has(> .cbi-value-field > .cbi-checkbox),
#modal_overlay > .modal .cbi-value[data-widget="CBI.Flag"]:not(.hidden),
.cbi-modal .cbi-value[data-widget="CBI.Flag"]:not(.hidden),
.tachyon-workspace-body .cbi-value[data-widget="CBI.Flag"]:not(.hidden) {
    flex-direction: column !important;
    align-items: stretch !important;
    justify-content: flex-start !important;
    gap: 2px !important;
}

#modal_overlay > .modal .cbi-value-field:has(> .cbi-checkbox),
.cbi-modal .cbi-value-field:has(> .cbi-checkbox),
.tachyon-workspace-body .cbi-value-field:has(> .cbi-checkbox),
#modal_overlay > .modal .cbi-value[data-widget="CBI.Flag"] > .cbi-value-field,
.cbi-modal .cbi-value[data-widget="CBI.Flag"] > .cbi-value-field,
.tachyon-workspace-body .cbi-value[data-widget="CBI.Flag"] > .cbi-value-field {
    display: flex !important;
    flex-direction: row !important;
    align-items: center !important;
    flex-wrap: nowrap !important;
    gap: 8px !important;
    width: 100% !important;
    flex: 0 0 auto !important;
    min-height: 0 !important;
}

#modal_overlay > .modal .cbi-value-field > .cbi-checkbox,
.cbi-modal .cbi-value-field > .cbi-checkbox,
.tachyon-workspace-body .cbi-value-field > .cbi-checkbox {
    display: inline-flex !important;
    align-items: center !important;
    height: auto !important;
    margin: 0 !important;
    flex: 0 0 auto !important;
}

#modal_overlay > .modal .cbi-value-field > .cbi-checkbox ~ .cbi-value-description,
.cbi-modal .cbi-value-field > .cbi-checkbox ~ .cbi-value-description,
.tachyon-workspace-body .cbi-value-field > .cbi-checkbox ~ .cbi-value-description {
    margin: 0 0 0 1.35em !important;
    flex: 1 1 auto !important;
    min-width: 0 !important;
    line-height: 1.3 !important;
}

#modal_overlay > .modal .cbi-value:not(.hidden):last-of-type,
.cbi-modal .cbi-value:not(.hidden):last-of-type,
.tachyon-workspace-body .cbi-section-node > .cbi-value:not(.hidden):not([id$="-_mount_node"]):last-of-type,
.tachyon-workspace-body .cbi-tabcontainer > [data-tab] > .cbi-value:not(.hidden):not([id$="-_mount_node"]):last-of-type {
    border-bottom: none !important;
}

#modal_overlay > .modal .cbi-value-field,
.cbi-modal .cbi-value-field,
.tachyon-workspace-body .cbi-value-field {
    float: none !important;
    flex: 0 0 auto !important;
    min-width: 0 !important;
    min-height: 0 !important;
    height: auto !important;
    width: 100% !important;
    margin: 0 !important;
    padding: 0 !important;
    text-align: left !important;
}

#modal_overlay > .modal .cbi-value-field > input[type="text"],
#modal_overlay > .modal .cbi-value-field > input[type="password"],
#modal_overlay > .modal .cbi-value-field > input[type="number"],
#modal_overlay > .modal .cbi-value-field > select,
#modal_overlay > .modal .cbi-value-field > div > input[type="text"],
#modal_overlay > .modal .cbi-value-field > div > input[type="password"],
#modal_overlay > .modal .cbi-value-field > div > input[type="number"],
#modal_overlay > .modal .cbi-value-field > div > select,
.cbi-modal .cbi-value-field > input[type="text"],
.cbi-modal .cbi-value-field > input[type="password"],
.cbi-modal .cbi-value-field > input[type="number"],
.cbi-modal .cbi-value-field > select,
.cbi-modal .cbi-value-field > div > input[type="text"],
.cbi-modal .cbi-value-field > div > input[type="password"],
.cbi-modal .cbi-value-field > div > input[type="number"],
.cbi-modal .cbi-value-field > div > select,
.tachyon-workspace-body .cbi-value-field > input[type="text"],
.tachyon-workspace-body .cbi-value-field > input[type="password"],
.tachyon-workspace-body .cbi-value-field > input[type="number"],
.tachyon-workspace-body .cbi-value-field > select,
.tachyon-workspace-body .cbi-value-field > div > input[type="text"],
.tachyon-workspace-body .cbi-value-field > div > input[type="password"],
.tachyon-workspace-body .cbi-value-field > div > input[type="number"],
.tachyon-workspace-body .cbi-value-field > div > select {
    width: 100% !important;
    max-width: 100% !important;
}

#modal_overlay > .modal .cbi-value-field .cbi-dynlist:not(.tachyon-dns-speed-enabled),
.cbi-modal .cbi-value-field .cbi-dynlist:not(.tachyon-dns-speed-enabled),
.tachyon-workspace-body .cbi-value-field .cbi-dynlist:not(.tachyon-dns-speed-enabled),
#modal_overlay > .modal .cbi-value-field .cbi-dropdown,
.cbi-modal .cbi-value-field .cbi-dropdown,
.tachyon-workspace-body .cbi-value-field .cbi-dropdown {
    max-width: 100% !important;
    width: 100% !important;
    box-sizing: border-box;
}

#modal_overlay > .modal .cbi-value-field .cbi-dynlist.tachyon-dns-speed-enabled,
.cbi-modal .cbi-value-field .cbi-dynlist.tachyon-dns-speed-enabled,
.tachyon-workspace-body .cbi-value-field .cbi-dynlist.tachyon-dns-speed-enabled {
    max-width: calc(100% - 112px) !important;
    width: calc(100% - 112px) !important;
    box-sizing: border-box;
}

#modal_overlay > .modal .cbi-value-field textarea,
.cbi-modal .cbi-value-field textarea,
.tachyon-workspace-body .cbi-value-field textarea {
    width: 100% !important;
    max-width: 100% !important;
}

#modal_overlay > .modal .cbi-value-title,
.cbi-modal .cbi-value-title,
.tachyon-workspace-body .cbi-value-title {
    float: none !important;
    flex: 0 0 auto !important;
    width: auto !important;
    min-width: 0 !important;
    min-height: 0 !important;
    height: auto !important;
    padding: 0 !important;
    margin: 0 !important;
    text-align: left !important;
    font-size: 12.5px !important;
    font-weight: 600 !important;
    color: var(--text-color-high, inherit) !important;
    line-height: 1.35 !important;
    word-break: normal !important;
    overflow-wrap: break-word !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
}

#modal_overlay > .modal .cbi-value-description,
.cbi-modal .cbi-value-description,
.tachyon-workspace-body .cbi-value-description {
    font-size: 11px !important;
    line-height: 1.35 !important;
    color: var(--text-color-medium, #64748b) !important;
    margin-top: 3px !important;
    opacity: 0.86;
}

/* Inputs, Selects, Textareas across Workspace and Modals (tachyon-ui 1:1) */
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
    border-radius: var(--r-btn, 8px) !important;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    padding: 7px 10px !important;
    font-size: 13px !important;
    background: var(--bg, #0d0e12) !important;
    color: var(--text, #f5f5f7) !important;
    box-sizing: border-box;
    transition: border-color var(--transition, 0.14s cubic-bezier(0.22, 1, 0.36, 1)), box-shadow var(--transition, 0.14s cubic-bezier(0.22, 1, 0.36, 1));
}

.tachyon-workspace-body .cbi-value-field select,
#modal_overlay > .modal select,
.cbi-modal select {
    height: auto !important;
    min-height: 36px !important;
    line-height: 1.4 !important;
    -webkit-appearance: none !important;
    appearance: none !important;
    padding-right: 32px !important;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%238e8e93' stroke-width='2.2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpolyline points='6 9 12 15 18 9'/%3E%3C/svg%3E") !important;
    background-repeat: no-repeat !important;
    background-position: right 10px center !important;
    background-size: 12px 12px !important;
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
    border-color: var(--accent, #0a84ff) !important;
    box-shadow: 0 0 0 3px rgba(10, 132, 255, 0.18) !important;
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
    margin-top: 16px !important;
    padding-top: 12px !important;
    border-top: 1px solid var(--border, rgba(255, 255, 255, 0.08)) !important;
    text-align: right !important;
}

#modal_overlay > .modal .btn,
#modal_overlay > .modal .cbi-button,
.tachyon-workspace-body .cbi-section-create .cbi-button {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    line-height: 1.25 !important;
    box-sizing: border-box !important;
    border-radius: 7px !important;
    font-weight: 500 !important;
    font-size: 12px !important;
    padding: 5px 12px !important;
}

#modal_overlay > .modal .tachyon_dashboard-page__urltest-details__sort-pill,
.cbi-modal .tachyon_dashboard-page__urltest-details__sort-pill {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 4px !important;
    height: 26px !important;
    min-height: 26px !important;
    padding: 0 10px !important;
    font-size: 11.5px !important;
    font-weight: 600 !important;
    line-height: 1 !important;
    border-radius: 6px !important;
    cursor: pointer !important;
    user-select: none !important;
}

#modal_overlay > .modal .tachyon_dashboard-page__urltest-details__sort-pill.is-active,
.cbi-modal .tachyon_dashboard-page__urltest-details__sort-pill.is-active {
    background: var(--tachyon-accent-soft) !important;
    border-color: var(--tachyon-accent-border) !important;
    color: var(--tachyon-accent-text) !important;
}

#modal_overlay > .modal .tachyon_dashboard-page__urltest-details__select-btn,
.cbi-modal .tachyon_dashboard-page__urltest-details__select-btn {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    height: 26px !important;
    min-height: 26px !important;
    padding: 0 10px !important;
    font-size: 12px !important;
    line-height: 1 !important;
    border-radius: 6px !important;
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
    max-width: 100%;
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
    background: color-mix(in srgb, var(--tachyon-accent) 4%, transparent);
}

.tachyon-settings-list-row.is-hidden {
    opacity: 0.52;
    background: rgba(128, 128, 128, 0.03);
}

.tachyon-settings-group-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 6px;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.02em;
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 24%, transparent);
    margin-left: 6px;
    vertical-align: middle;
}

/* 3. Hide expert low-level fields across Settings, Sections, and Outbounds in Simple Mode */
body[data-tachyon-ui-mode="simple"] [data-name="urltest_tolerance"],
body[data-tachyon-ui-mode="simple"] [data-name="urltest_idle_timeout"],
body[data-tachyon-ui-mode="simple"] [data-name="urltest_testing_url"],
body[data-tachyon-ui-mode="simple"] [data-name="passive_check"],
body[data-tachyon-ui-mode="simple"] [data-name="sticky_hash"],
body[data-tachyon-ui-mode="simple"] [data-name="custom_json"],
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
body[data-tachyon-ui-mode="simple"] [data-name="fakeip_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="fakeip_inet4_range"],
body[data-tachyon-ui-mode="simple"] [data-name="fakeip_inet6_range"],
body[data-tachyon-ui-mode="simple"] [data-name="fakeip_exclude"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_detour_enabled"],
body[data-tachyon-ui-mode="simple"] [data-name="dns_detour_section"],
/* Settings -> Network expert knobs */
body[data-tachyon-ui-mode="simple"] [data-name="tun_interface"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_stack"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_auto_route"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_mtu"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_inet4"],
body[data-tachyon-ui-mode="simple"] [data-name="tun_inet6"],
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

@media (max-width: 860px) {
    #cbi-tachyon {
        padding: 8px 8px 64px !important;
        overflow-x: hidden;
    }
    .tachyon-shell-layout,
    .tachyon-shell-layout[data-sidebar-pos="right"],
    #cbi-tachyon[data-sidebar-pos="right"] > .tachyon-shell-layout,
    .tachyon-shell-layout[data-sidebar-pos="top"],
    #cbi-tachyon[data-sidebar-pos="top"] > .tachyon-shell-layout {
        flex-direction: column !important;
        gap: 10px !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-workspace,
    .tachyon-workspace-body {
        min-width: 0 !important;
        max-width: 100% !important;
        width: 100% !important;
    }
    .tachyon-sidebar,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar,
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar {
        display: flex !important;
        flex-direction: column !important;
        flex-wrap: nowrap !important;
        align-items: stretch !important;
        justify-content: flex-start !important;
        width: 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
        position: relative !important;
        top: 0 !important;
        max-height: none !important;
        padding: 8px 10px !important;
        gap: 0 !important;
        border-radius: 12px !important;
        overflow: visible !important;
        box-sizing: border-box !important;
        z-index: 1200 !important;
    }
    .tachyon-topbar,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-topbar,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-topbar {
        position: relative !important;
        top: auto !important;
        z-index: 1 !important;
        flex-wrap: wrap !important;
        gap: 8px !important;
        padding: 8px 10px !important;
        width: 100% !important;
        max-width: 100% !important;
        min-width: 0 !important;
        box-sizing: border-box !important;
    }
    .tachyon-topbar.tachyon-topbar--subnav {
        padding: 6px 8px !important;
    }
    .tachyon-topbar__sidebar-pos-btn,
    .tachyon-topbar__collapse-btn,
    .tachyon-sidebar__collapse-btn {
        display: none !important;
    }
    .tachyon-sidebar__brand,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__brand,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand,
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand {
        order: 0 !important;
        display: flex !important;
        flex-direction: row !important;
        align-items: center !important;
        justify-content: flex-start !important;
        gap: 8px !important;
        padding: 2px !important;
        margin: 0 !important;
        border-right: none !important;
        border-bottom: none !important;
        width: 100% !important;
        min-width: 0 !important;
        flex: 0 0 auto !important;
        box-sizing: border-box !important;
    }
    .tachyon-shell-layout[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text,
    #cbi-tachyon[data-sidebar-collapsed="true"] .tachyon-sidebar__brand-text,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__brand-text {
        display: flex !important;
        min-width: 0 !important;
        flex: 0 0 auto !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar__status-card--inline,
    .tachyon-sidebar__status-card--inline {
        margin-left: 0 !important;
        padding: 3px 8px !important;
        font-size: 11px !important;
        flex-shrink: 0 !important;
    }
    .tachyon-sidebar__mobile-toggle {
        margin-left: auto !important;
        display: inline-flex !important;
        align-items: center !important;
        gap: 7px !important;
        min-height: 36px !important;
        padding: 6px 10px !important;
        border-radius: 9px !important;
        border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.28)) !important;
        background: var(--background-color-low, rgba(128, 128, 128, 0.14)) !important;
        color: inherit !important;
        font-size: 12.5px !important;
        font-weight: 600 !important;
        cursor: pointer !important;
        flex: 0 1 auto !important;
        min-width: 0 !important;
        max-width: 56% !important;
        white-space: nowrap !important;
        overflow: hidden !important;
        text-overflow: ellipsis !important;
    }
    .tachyon-sidebar__mobile-toggle.is-open {
        border-color: color-mix(in srgb, var(--tachyon-accent) 48%, transparent) !important;
        background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent) !important;
        color: var(--tachyon-accent-text) !important;
    }
    .tachyon-sidebar__mobile-toggle-label {
        overflow: hidden !important;
        text-overflow: ellipsis !important;
        white-space: nowrap !important;
        min-width: 0 !important;
    }
    .tachyon-sidebar__mobile-toggle-icon {
        flex-shrink: 0 !important;
        opacity: 0.9 !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__nav,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__nav,
    .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__nav,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__footer,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__footer,
    .tachyon-sidebar:not(.is-mobile-open) .tachyon-sidebar__footer {
        display: none !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav,
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav {
        order: 0 !important;
        display: flex !important;
        flex-direction: column !important;
        align-items: stretch !important;
        flex-wrap: nowrap !important;
        gap: 4px !important;
        flex: 0 0 auto !important;
        width: 100% !important;
        position: static !important;
        margin: 8px 0 0 !important;
        padding: 8px 2px 4px !important;
        border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22)) !important;
        background: transparent !important;
        box-shadow: none !important;
        max-height: min(62dvh, 460px) !important;
        overflow-y: auto !important;
        overflow-x: hidden !important;
        box-sizing: border-box !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__menu-block,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__menu-block {
        display: flex !important;
        flex-direction: column !important;
        width: 100% !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-item,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-item {
        width: 100% !important;
        justify-content: flex-start !important;
        min-height: 40px !important;
        padding: 8px 10px !important;
        font-size: 13px !important;
        box-sizing: border-box !important;
    }
    #cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-label,
    .tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-label,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-label {
        display: inline !important;
    }
    #cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__chevron,
    .tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__chevron,
    #cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-count,
    .tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-count,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__chevron,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-count {
        display: inline-flex !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-count,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__nav-count {
        margin-left: auto !important;
    }
    #cbi-tachyon[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__submenu.is-open,
    .tachyon-shell-layout[data-sidebar-collapsed="true"]:not([data-sidebar-pos="top"]) .tachyon-sidebar.is-mobile-open .tachyon-sidebar__submenu.is-open,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__submenu.is-open,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__submenu.is-open {
        display: flex !important;
        flex-direction: column !important;
        gap: 2px !important;
        padding: 2px 0 6px 12px !important;
        margin: 2px 0 4px 12px !important;
        border-left: 1px solid var(--border-color-low, rgba(255, 255, 255, 0.14)) !important;
    }
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__subitem,
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__subitem {
        width: 100% !important;
        justify-content: flex-start !important;
        min-height: 36px !important;
        padding: 7px 10px !important;
        font-size: 12.5px !important;
        box-sizing: border-box !important;
    }
    .tachyon-sidebar.is-mobile-open .tachyon-sidebar__footer {
        display: none !important;
    }
    .tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__footer,
    #cbi-tachyon[data-sidebar-pos="top"] .tachyon-sidebar.is-mobile-open .tachyon-sidebar__footer {
        order: 0 !important;
        display: flex !important;
        flex-direction: row !important;
        flex-wrap: wrap !important;
        align-items: center !important;
        justify-content: flex-start !important;
        gap: 8px !important;
        margin: 8px 0 0 !important;
        padding: 10px 2px 2px !important;
        border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22)) !important;
        width: 100% !important;
        margin-left: 0 !important;
        box-sizing: border-box !important;
    }
    .tachyon-sidebar.is-mobile-open .tachyon-topbar__divider {
        display: none !important;
    }
    .tachyon-sidebar.is-mobile-open .tachyon-topbar__service-controls,
    .tachyon-sidebar.is-mobile-open .tachyon-topbar__mode-switch,
    .tachyon-sidebar.is-mobile-open .tachyon-topbar__lang-slot,
    .tachyon-topbar__left,
    .tachyon-topbar__right {
        flex-wrap: wrap !important;
        max-width: 100% !important;
    }
    .tachyon-topbar--subnav .tachyon-global-subtabs.cbi-tabmenu,
    .tachyon-clients-subtabs.cbi-tabmenu,
    #cbi-tachyon-settings .cbi-tabmenu {
        display: flex !important;
        flex-wrap: nowrap !important;
        overflow-x: auto !important;
        overflow-y: hidden !important;
        width: 100% !important;
        max-width: 100% !important;
        scrollbar-width: none !important;
        -webkit-overflow-scrolling: touch !important;
    }
    .tachyon-topbar--subnav .tachyon-global-subtabs.cbi-tabmenu > li,
    .tachyon-clients-subtabs.cbi-tabmenu > li,
    #cbi-tachyon-settings .cbi-tabmenu > li {
        flex: 0 0 auto !important;
    }
    .tachyon-topbar--subnav .tachyon-global-subtabs.cbi-tabmenu > li > a,
    .tachyon-clients-subtabs.cbi-tabmenu > li > a,
    #cbi-tachyon-settings .cbi-tabmenu > li > a {
        white-space: nowrap !important;
        padding: 6px 10px !important;
        font-size: 12px !important;
    }
    .tachyon-studio-deck,
    .tachyon-studio-panel,
    .tachyon-studio-toolbar,
    .tachyon-pane-quickbar,
    .tachyon-dash-preset-toolbar {
        min-width: 0 !important;
        max-width: 100% !important;
        padding: 10px !important;
        box-sizing: border-box !important;
    }
    .tachyon-studio-toolbar__titles,
    .tachyon-studio-panel__titles,
    .tachyon-pane-quickbar__info {
        min-width: 0 !important;
        flex: 1 1 100% !important;
    }
    .tachyon-studio-toolbar__actions,
    .tachyon-studio-panel__header-controls {
        width: 100% !important;
        justify-content: flex-start !important;
    }
    .tachyon-dash-preset-toolbar__pills {
        width: 100% !important;
        flex-wrap: nowrap !important;
        overflow-x: auto !important;
        scrollbar-width: none !important;
        -webkit-overflow-scrolling: touch !important;
        padding-bottom: 2px !important;
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
    .tachyon-studio-body--pipeline .tachyon-studio-card {
        flex-direction: column !important;
        align-items: stretch !important;
        padding: 10px 12px !important;
        gap: 8px !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-body--pipeline .tachyon-studio-card__head {
        flex: 1 1 auto !important;
        min-width: 0 !important;
        max-width: 100% !important;
        width: 100% !important;
    }
    .tachyon-studio-card__identity {
        min-width: 0 !important;
        flex: 1 1 160px !important;
    }
    .tachyon-studio-body--pipeline .tachyon-studio-card__pipeline {
        flex: 1 1 auto !important;
        min-width: 0 !important;
        width: 100% !important;
        margin-right: 0 !important;
        flex-wrap: wrap !important;
    }
    .tachyon-studio-body--pipeline .tachyon-studio-card__footer,
    .tachyon-studio-card__footer {
        flex: 1 1 auto !important;
        flex-wrap: wrap !important;
        justify-content: flex-start !important;
        width: 100% !important;
        margin-left: 0 !important;
        padding-top: 8px !important;
        border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14)) !important;
        white-space: normal !important;
    }
    #modal_overlay > .modal,
    #modal_overlay > .modal.cbi-modal,
    #modal_overlay > .modal:has([class*="tachyon"]),
    .cbi-modal,
    .cbi-modal:has([class*="tachyon"]) {
        width: 100% !important;
        max-width: 100% !important;
        min-width: 0 !important;
        max-height: 92dvh !important;
        margin: 4dvh auto !important;
        padding: 14px !important;
        overflow-x: hidden !important;
        box-sizing: border-box !important;
    }
    #modal_overlay > .modal > *,
    #modal_overlay > .modal .cbi-section,
    #modal_overlay > .modal .cbi-section-node,
    #modal_overlay > .modal .cbi-tabcontainer,
    #modal_overlay > .modal .cbi-value,
    #modal_overlay > .modal .cbi-value-field,
    .cbi-modal .cbi-section,
    .cbi-modal .cbi-section-node {
        min-width: 0 !important;
        max-width: 100% !important;
        box-sizing: border-box !important;
    }
    #modal_overlay > .modal .cbi-page-actions,
    .cbi-modal .cbi-page-actions {
        display: flex !important;
        flex-wrap: wrap !important;
        justify-content: flex-end !important;
        gap: 8px !important;
        max-width: 100% !important;
    }
}

@media (max-width: 480px) {
    .tachyon-sidebar__brand-sub {
        display: none !important;
    }
    .tachyon-sidebar__mobile-toggle {
        max-width: 52% !important;
        padding: 5px 8px !important;
        font-size: 12px !important;
    }
}

@media (max-height: 520px) and (orientation: landscape) {
    .tachyon-sidebar {
        position: relative !important;
        top: 0 !important;
        max-height: none !important;
    }
    .tachyon-topbar {
        position: relative !important;
        top: auto !important;
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
    font-weight: 600;
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
    border-radius: 6px;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-dash-preset-pill.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
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
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
}

.tachyon-dash-preset-toolbar__customize-btn:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    color: var(--tachyon-accent-text);
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
    font-weight: 600;
    opacity: 0.72;
    letter-spacing: 0.03em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-kpi-strip__val {
    font-size: 14.5px;
    font-weight: 600;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
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
    border-radius: 6px;
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
    font-weight: 600;
    line-height: 1.15;
    letter-spacing: -0.02em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-variant-numeric: tabular-nums;
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
    font-weight: 600;
    letter-spacing: 0.04em;
    opacity: 0.72;
}

.tachyon-kpi-telemetry__pulse {
    width: 8px;
    height: 8px;
    border-radius: 6px;
    flex-shrink: 0;
}

.tachyon-kpi-telemetry__val {
    font-size: 19px;
    font-weight: 600;
    line-height: 1.15;
    font-variant-numeric: tabular-nums;
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
    font-weight: 600;
    letter-spacing: 0.05em;
    opacity: 0.65;
}

.tachyon-kpi-minimal-counters__val {
    font-size: 21px;
    font-weight: 600;
    line-height: 1.15;
    letter-spacing: -0.02em;
    font-variant-numeric: tabular-nums;
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
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 290px), 1fr));
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    transform: translateY(-1px);
}

.tachyon-routing-bento-card.is-selected {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent);
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
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 235px), 1fr));
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-routing-compact-tile.is-selected {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent);
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
    font-weight: 600;
    opacity: 0.8;
    white-space: nowrap;
}

.tachyon-routing-sections-list--matrix {
    display: grid !important;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr));
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
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
    font-weight: 600;
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
    font-weight: 600;
    opacity: 0.76;
}

.tachyon-traffic-gauge-box__val {
    font-size: 17px;
    font-weight: 600;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
}

.tachyon-traffic-gauge-box__val.is-down {
    color: var(--tachyon-accent);
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
    background: var(--tachyon-accent, #7c86ff);
}

.tachyon-traffic-gauge-bar__fill.is-up {
    background: var(--tachyon-success, #4cc38a);
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
    border-left: 3px solid var(--tachyon-accent);
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
    font-weight: 600;
    letter-spacing: 0.04em;
}

.tachyon-traffic-dual-box__tag.is-down {
    color: var(--tachyon-accent);
}

.tachyon-traffic-dual-box__tag.is-up {
    color: #10b981;
}

.tachyon-traffic-dual-box__value {
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.02em;
    font-variant-numeric: tabular-nums;
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
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 6px;
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
    border-left: 3px solid var(--tachyon-accent);
}
.tachyon-system-hud-cell.is-accent-2 {
    border-left: 3px solid #10b981;
}
.tachyon-system-hud-cell.is-accent-3 {
    border-left: 3px solid var(--tachyon-accent);
}
.tachyon-system-hud-cell.is-accent-4 {
    border-left: 3px solid #f59e0b;
}

.tachyon-system-tile__label,
.tachyon-system-hud-cell__label {
    font-size: 10px;
    font-weight: 600;
    opacity: 0.68;
}

.tachyon-system-tile__val,
.tachyon-system-hud-cell__val {
    font-size: 13px;
    font-weight: 600;
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
    font-weight: 600;
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
    border-radius: 6px;
    background: var(--background-color-low, rgba(128, 128, 128, 0.07));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    font-size: 12px;
}

.tachyon-system-banner-card__key {
    font-size: 11px;
    font-weight: 600;
    opacity: 0.68;
}

.tachyon-system-banner-card__val {
    font-weight: 600;
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
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 195px), 1fr));
    gap: 8px;
}

.tachyon-router-service-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 8px 11px;
    border-radius: 9px;
    background: var(--tachyon-bg-card-elevated, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--tachyon-border-subtle, rgba(128, 128, 128, 0.16));
    font-size: 12px;
    overflow: hidden;
}

.tachyon-router-service-card__top {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-weight: 600;
    min-width: 0;
    overflow: hidden;
}

.tachyon-router-service-card__bottom {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
}

.tachyon-router-service-res-card {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 9px 12px;
    border-radius: 9px;
    background: var(--tachyon-bg-card-elevated, rgba(128, 128, 128, 0.06));
    border: 1px solid var(--tachyon-border-subtle, rgba(128, 128, 128, 0.16));
    font-size: 12px;
    overflow: hidden;
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
    background: var(--tachyon-accent, #7c86ff);
}

/* Active Clients & Inbounds Alternative Views + Half-Width Responsiveness */
.tachyon-client-cards-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 240px), 1fr));
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
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 220px), 1fr)) !important;
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
    font-weight: 600;
}

.tachyon-dash-editor__section-sub {
    font-size: 12px;
    opacity: 0.72;
}

.tachyon-dash-editor__presets-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 185px), 1fr));
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-dash-preset-card.is-selected,
.tachyon-dash-preset-card.is-active {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 11%, transparent);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 32%, transparent);
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
    font-weight: 600;
}

.tachyon-dash-preset-card__badge {
    align-self: flex-start;
    font-size: 9.5px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 6px;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent-text);
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
    background: var(--tachyon-accent);
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
}

.tachyon-visual-slot-card.is-dragging {
    opacity: 0.45;
    transform: scale(0.99);
}

.tachyon-visual-slot-card.is-drag-over {
    border-color: var(--tachyon-accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
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
    font-weight: 600;
    padding: 1px 7px;
    border-radius: 6px;
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
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

.tachyon-dash-widget-row__check.is-checked {
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    color: var(--tachyon-accent-text);
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
    font-weight: 600;
}

.tachyon-dash-widget-row__desc {
    font-size: 11px;
    opacity: 0.68;
}

.tachyon-dash-widget-row__views-label {
    font-size: 11px;
    font-weight: 600;
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
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent-text);
    opacity: 1;
    font-weight: 600;
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
    font-weight: 600;
    opacity: 0.75;
}


/* ==========================================================================
   Tachyon Studio Deck (Full Redesign of Sections, Outbounds, Conditions,
   Balancers, Inbound Servers, Profiles & Schedules)
   ========================================================================== */

/* Hide legacy LuCI GridSection tables & raw add bars when Studio Deck is mounted */
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
    gap: 10px;
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--tachyon-bg-card, var(--background-color-high, rgba(128, 128, 128, 0.04)));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    box-sizing: border-box;
}

.tachyon-studio-toolbar__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
}

.tachyon-studio-panel__header {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 10px;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
}

.tachyon-studio-panel__header-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
    width: 100%;
}

.tachyon-studio-panel__header-left {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-studio-panel__header-controls {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-studio-panel__header-right {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
    width: 100%;
}

.tachyon-studio-toolbar__titles,
.tachyon-studio-panel__titles {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 200px;
    flex: 1;
}

.tachyon-studio-toolbar__titles > .tachyon-studio-view-switch {
    align-self: flex-start;
    margin-top: 4px;
}

.tachyon-studio-disabled-tray {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 4px;
    padding-top: 8px;
    border-top: 1px dashed var(--border-color-medium, rgba(128, 128, 128, 0.24));
}

.tachyon-studio-disabled-tray.is-hidden,
.tachyon-studio-disabled-tray__body:not(.is-open) {
    display: none !important;
}

.tachyon-studio-disabled-tray__toggle {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 7px 11px;
    border-radius: 9px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.2));
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    text-align: left;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-studio-disabled-tray__toggle:hover,
.tachyon-studio-disabled-tray__toggle.is-open {
    border-color: var(--tachyon-accent-border);
    background: var(--tachyon-accent-soft);
}

.tachyon-studio-disabled-tray__label {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    opacity: 0.85;
}

.tachyon-studio-disabled-tray__chevron {
    font-size: 12px;
    color: var(--tachyon-accent-text);
}

.tachyon-studio-disabled-tray__count {
    font-size: 10.5px;
    font-weight: 600;
    padding: 1px 7px;
    border-radius: 6px;
    background: var(--tachyon-accent-soft);
    color: var(--tachyon-accent-text);
    border: 1px solid var(--tachyon-accent-border);
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
    font-weight: 600;
    letter-spacing: 0.06em;
    color: var(--text-color-medium, #94a3b8);
}

.tachyon-studio-toolbar__counter {
    font-size: 10.5px;
    font-weight: 600;
    padding: 1px 7px;
    border-radius: 6px;
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 26%, transparent);
}

.tachyon-studio-toolbar__title,
.tachyon-studio-panel__title {
    margin: 0 !important;
    font-size: 14.5px !important;
    font-weight: 600 !important;
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
    background: color-mix(in srgb, var(--tachyon-accent) 15%, transparent);
    color: var(--tachyon-accent-text);
    opacity: 1;
    font-weight: 600;
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
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-studio-btn--primary:hover {
    background: color-mix(in srgb, var(--tachyon-accent) 22%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 52%, transparent);
    color: var(--tachyon-accent-text-hover);
}

.tachyon-studio-btn--ghost {
    border: 1px solid var(--border-color-medium, rgba(148, 163, 184, 0.24));
    background: var(--background-color-low, rgba(148, 163, 184, 0.07));
    color: inherit;
}

.tachyon-studio-btn--ghost:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-studio-toolbar__bottom,
.tachyon-studio-panel__controls {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-studio-filter-dropdown {
    position: relative;
    display: inline-flex;
    align-items: center;
}

.tachyon-studio-filter-trigger {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-studio-filter-trigger:hover,
.tachyon-studio-filter-trigger.is-open {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
}

.tachyon-studio-filter-trigger.is-active {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-studio-filter-trigger svg {
    opacity: 0.72;
    transition: transform 0.14s ease;
}

.tachyon-studio-filter-trigger.is-open svg {
    transform: rotate(180deg);
}

.tachyon-studio-filter-menu {
    display: none;
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    min-width: 220px;
    padding: 6px;
    border-radius: 9px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.3));
    background: var(--tachyon-bg-card, var(--background-color-high, #1e1e1e));
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.32);
    z-index: 950;
    flex-direction: column;
    gap: 2px;
}

.tachyon-studio-filter-menu.is-open {
    display: flex;
}

.tachyon-studio-filter-option {
    display: flex !important;
    align-items: center;
    gap: 8px;
    padding: 6px 8px;
    margin: 0 !important;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 500;
    color: inherit;
    cursor: pointer;
    white-space: nowrap;
    user-select: none;
    transition: background-color 0.12s ease;
}

.tachyon-studio-filter-option:hover {
    background: var(--background-color-low, rgba(128, 128, 128, 0.12));
}

.tachyon-studio-filter-option.is-checked {
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent-text);
    font-weight: 600;
}

.tachyon-studio-filter-checkbox {
    margin: 0 !important;
    width: 14px;
    height: 14px;
    cursor: pointer;
    accent-color: var(--tachyon-accent, #38bdf8);
    flex-shrink: 0;
}

.tachyon-studio-body--cards {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr));
    gap: 10px;
    width: 100%;
    min-width: 0;
    box-sizing: border-box;
}

.tachyon-studio-body--pipeline {
    display: flex;
    flex-direction: column;
    gap: 8px;
    width: 100%;
    min-width: 0;
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
    width: 100%;
    min-width: 0;
    max-width: 100%;
    box-sizing: border-box;
    transition: border-color 0.14s ease, background-color 0.14s ease, transform 0.12s ease, box-shadow 0.14s ease;
}

.tachyon-studio-body--pipeline .tachyon-studio-card {
    flex-direction: row;
    align-items: center;
    flex-wrap: wrap;
    padding: 10px 14px;
    gap: 10px 18px;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__head {
    flex: 1 1 290px;
    min-width: 240px;
    max-width: 380px;
}

.tachyon-studio-body--pipeline .tachyon-studio-card--balancer .tachyon-studio-card__head {
    max-width: none;
}

.tachyon-studio-card--section,
.tachyon-studio-card--balancer {
    cursor: default;
}

.tachyon-studio-card__icon.is-clickable {
    cursor: pointer;
    transition: border-color 0.14s ease, transform 0.12s ease;
}

.tachyon-studio-card__icon.is-clickable:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 55%, transparent);
    transform: scale(1.05);
}

.tachyon-studio-body--pipeline .tachyon-studio-card--source-compact {
    flex-direction: column;
    align-items: stretch;
}

.tachyon-studio-body--pipeline .tachyon-studio-card--source-compact > .tachyon-studio-card__head {
    flex: 1 1 100%;
    max-width: 100%;
    width: 100%;
}

.tachyon-studio-card--source-compact .tachyon-studio-card__identity {
    flex: 1 1 260px;
    min-width: 220px;
}

.tachyon-studio-source-compact__right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    justify-content: flex-end;
    flex: 0 1 auto;
    margin-left: auto;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__pipeline {
    flex: 2 1 340px;
    min-width: 260px;
    border-top: none;
    padding-top: 0;
    margin-right: 8px;
}

.tachyon-studio-body--pipeline .tachyon-studio-card__footer {
    flex: 0 0 auto !important;
    flex-shrink: 0 !important;
    border-top: none;
    padding-top: 0;
    margin-left: auto;
    white-space: nowrap;
}

.tachyon-studio-card:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 40%, transparent);
    background: var(--background-color-low, rgba(128, 128, 128, 0.06));
}

.tachyon-studio-card.is-disabled {
    opacity: 0.62;
}

.tachyon-studio-card.is-drag-over {
    border-color: var(--tachyon-accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
}

.tachyon-studio-card__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px 12px;
    min-width: 0;
}

.tachyon-studio-card__identity {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: min(220px, 100%);
    flex: 1 1 220px;
    overflow: hidden;
}

.tachyon-studio-card__head-right {
    display: flex;
    align-items: center;
    flex: 0 0 auto;
    flex-shrink: 0;
    margin-left: auto;
}

.tachyon-studio-card__order {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    flex-shrink: 0;
}

.tachyon-studio-card__priority-badge {
    font-size: 11px;
    font-weight: 600;
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
    font-weight: 600;
    cursor: pointer;
    opacity: 0.7;
}

.tachyon-studio-order-btn:hover:not(:disabled) {
    opacity: 1;
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
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
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-studio-card--balancer .tachyon-studio-card__title {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    word-break: break-word;
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
    display: inline-flex !important;
    align-items: center !important;
    justify-content: flex-start !important;
    width: 40px !important;
    min-width: 40px !important;
    max-width: 40px !important;
    height: 22px !important;
    min-height: 22px !important;
    border-radius: 999px !important;
    border: 1px solid rgba(128, 128, 128, 0.3) !important;
    background: rgba(128, 128, 128, 0.25) !important;
    padding: 2px !important;
    margin: 0 !important;
    box-sizing: border-box !important;
    cursor: pointer;
    flex: 0 0 40px !important;
    flex-shrink: 0 !important;
    transition: background-color 0.16s ease, border-color 0.16s ease;
}

.tachyon-studio-switch.is-on {
    background: var(--tachyon-accent) !important;
    border-color: var(--tachyon-accent-strong) !important;
}

.tachyon-studio-switch__thumb {
    display: block !important;
    width: 16px !important;
    height: 16px !important;
    min-width: 16px !important;
    min-height: 16px !important;
    flex: 0 0 16px !important;
    margin: 0 !important;
    border-radius: 50% !important;
    background: #fff !important;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.28);
    transition: transform 0.16s ease;
}

.tachyon-studio-switch.is-on .tachyon-studio-switch__thumb {
    transform: translateX(18px) !important;
}

/* Studio Badges */
.tachyon-studio-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 5px;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.02em;
    white-space: nowrap;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon-studio-badge--proxy {
    background: color-mix(in srgb, var(--tachyon-accent) 12%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
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
    min-width: 0;
    max-width: 100%;
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
    font-weight: 600;
    letter-spacing: 0.04em;
    opacity: 0.58;
}

.tachyon-studio-card__pipe-arrow {
    font-size: 13px;
    opacity: 0.45;
    font-weight: 600;
}

.tachyon-studio-card__chips {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
    min-width: 0;
    max-width: 100%;
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
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    box-sizing: border-box;
}

.tachyon-studio-chip > span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

button.tachyon-studio-chip {
    cursor: pointer;
}

button.tachyon-studio-chip:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 42%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-studio-chip--cond {
    background: rgba(148, 163, 184, 0.08);
    border-color: rgba(148, 163, 184, 0.2);
}

.tachyon-studio-chip--source {
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 24%, transparent);
}

.tachyon-studio-chip--balancer {
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
    border-color: color-mix(in srgb, var(--tachyon-accent) 24%, transparent);
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
}

.tachyon-studio-action-btn--primary {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
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
    font-weight: 600;
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
    font-weight: 600;
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
    display: grid !important;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 210px), 1fr)) !important;
    gap: 8px !important;
    width: 100% !important;
    max-height: min(68vh, 620px) !important;
    overflow-y: auto !important;
    padding-right: 4px !important;
    box-sizing: border-box !important;
}

.tachyon-studio-create__tpl-card {
    display: flex !important;
    flex-direction: row !important;
    align-items: flex-start !important;
    justify-content: flex-start !important;
    gap: 10px !important;
    width: 100% !important;
    min-width: 0 !important;
    height: auto !important;
    min-height: 64px !important;
    max-height: none !important;
    margin: 0 !important;
    padding: 10px 12px !important;
    border-radius: 10px !important;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.24)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.06)) !important;
    color: inherit !important;
    text-align: left !important;
    white-space: normal !important;
    line-height: 1.35 !important;
    box-sizing: border-box !important;
    overflow: hidden !important;
    cursor: pointer !important;
    user-select: none;
    transition: border-color 0.15s ease, background 0.15s ease;
}

.tachyon-studio-create__tpl-card:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 45%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent) !important;
}

.tachyon-studio-create__tpl-card.is-selected {
    border-color: var(--primary-color-high, var(--tachyon-accent)) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent) !important;
}

.tachyon-studio-create__tpl-icon {
    font-size: 18px;
    flex: 0 0 auto !important;
    display: inline-flex !important;
    align-items: center;
    justify-content: center;
    margin-top: 2px;
}

.tachyon-studio-create__tpl-body {
    display: flex !important;
    flex-direction: column !important;
    align-items: flex-start !important;
    gap: 3px !important;
    flex: 1 1 0% !important;
    min-width: 0 !important;
    max-width: 100% !important;
    white-space: normal !important;
    text-align: left !important;
}

.tachyon-studio-create__tpl-title {
    font-size: 12.5px !important;
    font-weight: 600 !important;
    line-height: 1.3 !important;
    white-space: normal !important;
    overflow-wrap: anywhere !important;
    word-break: break-word !important;
    width: 100%;
}

.tachyon-studio-create__tpl-desc {
    font-size: 11px !important;
    opacity: 0.72;
    line-height: 1.35 !important;
    white-space: normal !important;
    overflow-wrap: anywhere !important;
    word-break: break-word !important;
    width: 100%;
}

.tachyon-studio-create__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 10px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
}

.tachyon-studio-card--source-compact {
    padding: 10px 14px !important;
    gap: 8px !important;
}

.tachyon-studio-source-compact__right {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
    gap: 6px;
    flex: 0 1 auto;
    margin-left: auto;
}

.tachyon-studio-source-compact__sections {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    flex-wrap: wrap;
}

.tachyon-studio-source-inspector {
    display: none;
    flex-direction: column;
    gap: 6px;
    margin-top: 6px;
    padding-top: 10px;
    border-top: 1px dashed var(--border-color-low, rgba(148, 163, 184, 0.2));
    font-size: 12px;
    width: 100%;
    min-width: 0;
    max-width: 100%;
    box-sizing: border-box;
}

.tachyon-studio-card--source-compact.is-expanded .tachyon-studio-source-inspector,
.tachyon-studio-card--group.is-expanded .tachyon-studio-source-inspector {
    display: flex;
}

.tachyon-studio-source-inspector__row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    width: 100%;
    min-width: 0;
    max-width: 100%;
    box-sizing: border-box;
}

.tachyon-studio-source-inspector__row--block {
    flex-direction: column;
    align-items: stretch;
    gap: 6px;
}

.tachyon-studio-source-inspector__label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-color-medium, #94a3b8);
    letter-spacing: 0.03em;
}

.tachyon-studio-source-inspector__code {
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 11.5px;
    padding: 2px 6px;
    border-radius: 5px;
    background: rgba(15, 23, 42, 0.35);
    word-break: break-all;
}

.tachyon-studio-source-inspector__links {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-studio-server-table-wrap {
    width: 100%;
    max-width: 100%;
    max-height: 260px;
    overflow-x: auto;
    overflow-y: auto;
    -webkit-overflow-scrolling: touch;
    box-sizing: border-box;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(148, 163, 184, 0.18));
    background: var(--background-color-low, rgba(15, 23, 42, 0.22));
}

.tachyon-studio-server-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12px;
}

.tachyon-studio-server-table th,
.tachyon-studio-server-table td {
    padding: 6px 10px;
    text-align: left;
    border-bottom: 1px solid var(--border-color-low, rgba(148, 163, 184, 0.12));
    vertical-align: middle;
}

.tachyon-studio-server-table th {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--text-color-medium, #94a3b8);
    background: var(--tachyon-bg-card-elevated, var(--background-color-high, #1a1d28));
    position: sticky;
    top: 0;
    z-index: 2;
}

.tachyon-studio-server-table tbody tr:last-child td {
    border-bottom: none;
}

.tachyon-studio-server-table tbody tr:hover td {
    background: color-mix(in srgb, var(--tachyon-accent) 6%, transparent);
}

.tachyon-studio-server-table__name {
    font-family: "Twemoji Country Flags", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    font-weight: 600;
    word-break: normal;
    overflow-wrap: break-word;
}

.tachyon-studio-copy-link-btn {
    padding: 3px 8px !important;
    font-size: 11px !important;
    gap: 4px !important;
}

/* ==========================================================================
   Wizard Step 4: Smart DNS Auto-Tune & Benchmark + Visual DNS Preset Cards
   ========================================================================== */

.tachyon-wizard__dns-autotune-card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 13px 15px;
    border-radius: 10px;
    background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05));
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.2));
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
    font-weight: 600;
    color: var(--tachyon-accent-text);
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
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent) !important;
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 38%, transparent) !important;
    color: var(--tachyon-accent-text) !important;
    font-weight: 600 !important;
    padding: 6px 13px !important;
    font-size: 12px !important;
    cursor: pointer;
    box-shadow: none !important;
}

.tachyon-wizard__dns-run-btn:hover {
    background: color-mix(in srgb, var(--tachyon-accent) 22%, transparent) !important;
    border-color: color-mix(in srgb, var(--tachyon-accent) 50%, transparent) !important;
}

.tachyon-wizard__dns-progress-box {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 9px 12px;
    border-radius: 8px;
    background: var(--background-color-high, rgba(15, 23, 42, 0.25));
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 26%, transparent);
}

.tachyon-wizard__dns-progress-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-size: 12px;
}

.tachyon-wizard__dns-progress-bar {
    height: 6px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    overflow: hidden;
}

.tachyon-wizard__dns-progress-fill {
    height: 100%;
    border-radius: 999px;
    background: var(--tachyon-accent, #7c86ff);
    transition: width 0.25s cubic-bezier(0.22, 1, 0.36, 1);
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
    border-color: var(--tachyon-accent);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 35%, transparent);
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
    font-weight: 600;
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
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 170px), 1fr));
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
    font-weight: 600;
    opacity: 0.68;
}

.tachyon-wizard__dns-rec-tier-val {
    font-size: 12px;
    font-weight: 600;
    word-break: break-all;
}

.tachyon-wizard__dns-rec-tier-sub {
    font-size: 10.5px;
    opacity: 0.75;
    color: #60a5fa;
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
    font-weight: 600;
}

.tachyon-wizard__dns-top-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 195px), 1fr));
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
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent);
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
    font-weight: 600;
}

.tachyon-wizard__dns-srv-proto {
    font-size: 9.5px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 5px;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent);
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
    font-weight: 600;
    font-variant-numeric: tabular-nums;
}

.tachyon-wizard__dns-presets-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 210px), 1fr));
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
    border-color: var(--tachyon-accent);
}

.tachyon-wizard__dns-preset-card.is-selected {
    border-color: var(--tachyon-accent);
    background: color-mix(in srgb, var(--tachyon-accent) 13%, transparent);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 32%, transparent);
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
    font-weight: 600;
}

.tachyon-wizard__dns-preset-badge {
    font-size: 9.5px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 5px;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent);
    color: var(--tachyon-accent);
    white-space: nowrap;
}

.tachyon-wizard__dns-preset-desc {
    font-size: 11px;
    opacity: 0.74;
    line-height: 1.35;
}

/* ==========================================================================
   Wizard Step 1 & Step 2: 1-Click Quick Start Presets
   ========================================================================== */

.tachyon-wizard__quick-hero {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px 14px;
    border-radius: 10px;
    background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05));
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.22));
    box-sizing: border-box;
}

.tachyon-wizard__quick-hero-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 10px;
}

.tachyon-wizard__quick-hero-titles {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.tachyon-wizard__quick-hero-title {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: 14px;
    font-weight: 600;
    color: var(--text-color-high, inherit);
}

.tachyon-wizard__quick-hero-title svg {
    color: var(--tachyon-accent, #7c86ff);
    flex-shrink: 0;
}

.tachyon-wizard__quick-hero-sub {
    font-size: 12px;
    opacity: 0.82;
    line-height: 1.4;
}

.tachyon-wizard__quick-presets-grid {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-wizard__quick-preset-card {
    display: flex !important;
    flex-direction: column !important;
    align-items: flex-start !important;
    justify-content: flex-start !important;
    gap: 4px !important;
    padding: 8px 12px !important;
    border-radius: 8px !important;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.25)) !important;
    background: var(--background-color-high, rgba(15, 23, 42, 0.28)) !important;
    color: inherit !important;
    text-align: left !important;
    white-space: normal !important;
    width: 100% !important;
    height: auto !important;
    min-height: 0 !important;
    box-sizing: border-box !important;
    cursor: pointer !important;
    user-select: none;
    transition: border-color 0.15s cubic-bezier(0.22, 1, 0.36, 1), background-color 0.15s cubic-bezier(0.22, 1, 0.36, 1), box-shadow 0.15s cubic-bezier(0.22, 1, 0.36, 1);
}

.tachyon-wizard__quick-preset-card:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 55%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 9%, transparent) !important;
}

.tachyon-wizard__quick-preset-card.is-selected {
    border-color: var(--tachyon-accent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 16%, transparent) !important;
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--tachyon-accent) 36%, transparent);
}

.tachyon-wizard__quick-preset-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 8px;
}

.tachyon-wizard__quick-preset-title-wrap {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    min-width: 0;
}

.tachyon-wizard__quick-preset-title {
    font-size: 12.5px;
    font-weight: 600;
    line-height: 1.25;
}

.tachyon-wizard__quick-preset-badge {
    font-size: 10px;
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 5px;
    background: color-mix(in srgb, var(--tachyon-accent) 18%, transparent);
    color: var(--tachyon-accent-text);
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon-wizard__quick-preset-badge.is-hit {
    background: rgba(76, 195, 138, 0.18);
    color: #4cc38a;
    border: 1px solid rgba(76, 195, 138, 0.32);
}

.tachyon-wizard__quick-preset-desc {
    font-size: 11px;
    opacity: 0.78;
    line-height: 1.32;
}

.tachyon-wizard__quick-preset-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 1px;
}

.tachyon-wizard__quick-preset-tag {
    font-size: 10px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 5px;
    background: rgba(148, 163, 184, 0.12);
    border: 1px solid rgba(148, 163, 184, 0.2);
    opacity: 0.9;
}

.tachyon-wizard__quick-input-box {
    display: flex;
    flex-direction: column;
    gap: 5px;
    padding: 8px 11px;
    border-radius: 8px;
    background: var(--background-color-high, rgba(15, 23, 42, 0.32));
    border: 1px solid var(--border-color-low, rgba(148, 163, 184, 0.24));
}

.tachyon-wizard__quick-input-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-wizard__quick-paste-btn {
    padding: 3px 9px !important;
    font-size: 11px !important;
    border-radius: 6px !important;
}

.tachyon-wizard__quick-input {
    width: 100% !important;
    min-height: 44px !important;
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 12px !important;
    box-sizing: border-box !important;
}

.tachyon-wizard__quick-detect {
    font-size: 11.5px;
    font-weight: 600;
    line-height: 1.35;
}

.tachyon-wizard__quick-detect.is-idle {
    opacity: 0.72;
}

.tachyon-wizard__quick-detect.is-valid {
    color: #4cc38a;
}

.tachyon-wizard__quick-detect.is-invalid {
    color: #e5c07b;
}

.tachyon-wizard__quick-actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-wizard__quick-launch-btn {
    display: inline-flex !important;
    align-items: center !important;
    gap: 6px !important;
    font-weight: 600 !important;
    padding: 8px 16px !important;
    border-radius: 8px !important;
}

.tachyon-wizard__manual-divider {
    font-size: 11.5px;
    font-weight: 600;
    letter-spacing: 0.01em;
    opacity: 0.68;
    margin-top: 4px;
}

.tachyon-wizard__step2-preset-bar {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 10px;
    padding: 11px 14px;
    border-radius: 10px;
    background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05));
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.22));
}

.tachyon-wizard__step2-preset-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon-wizard__step2-preset-title {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12.5px;
    font-weight: 600;
}

.tachyon-wizard__step2-preset-controls {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
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
    border-color: color-mix(in srgb, var(--tachyon-accent) 28%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 10%, transparent) !important;
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
    
    outline: none !important;
    box-shadow: none !important;
}

.tachyon-ruleset-picker__hint-bar {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 8px 11px;
    border-radius: 9px;
    background: color-mix(in srgb, var(--tachyon-accent) 6%, transparent);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 20%, transparent);
    transition: border-color 0.15s ease, background-color 0.15s ease;
    box-sizing: border-box;
}

.tachyon-ruleset-picker__hint-bar.is-highlighted {
    border-color: color-mix(in srgb, var(--tachyon-accent) 34%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent) 9%, transparent);
}

.tachyon-ruleset-picker__cats-block {
    display: flex;
    flex-direction: column;
    gap: 7px;
    padding: 8px 10px;
    border-radius: 9px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.20));
    box-sizing: border-box;
}

.tachyon-ruleset-picker__top-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-ruleset-picker__presets-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-ruleset-picker__presets-group {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 4px;
    flex: 0 0 auto;
}

.tachyon-ruleset-picker__presets-label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-color-medium, #888);
    margin-right: 2px;
}

.tachyon-ruleset-picker__preset-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 5px 9px;
    border-radius: 7px;
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 8%, transparent);
    color: var(--text-color-high, inherit);
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease;
}

.tachyon-ruleset-picker__preset-btn:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 48%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 15%, transparent);
}

.tachyon-ruleset-picker__preset-btn.is-clear {
    border-color: var(--border-color-low, rgba(128, 128, 128, 0.24)) !important;
    background: transparent;
    color: var(--text-color-medium, #888);
}

.tachyon-ruleset-picker__preset-btn.is-clear:hover {
    border-color: rgba(239, 68, 68, 0.4) !important;
    color: #ef4444;
    background: rgba(239, 68, 68, 0.08);
}

.tachyon-ruleset-picker__floating-tooltip {
    position: fixed;
    z-index: 100000;
    pointer-events: none;
    max-width: min(340px, calc(100vw - 24px));
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 8px 11px;
    border-radius: 9px;
    background: var(--background-color-high, #1e293b);
    color: var(--text-color-high, #f8fafc);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 38%, transparent);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.28);
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
    font-weight: 600;
    color: var(--text-color-high, inherit);
}

.tachyon-ruleset-picker__hint-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 6px;
    font-size: 10.5px;
    font-weight: 600;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    border: 1px solid color-mix(in srgb, var(--tachyon-accent) 28%, transparent);
}

.tachyon-ruleset-picker__hint-badge.is-vpn {
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
    border-color: color-mix(in srgb, var(--tachyon-accent) 30%, transparent);
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

.tachyon-ruleset-picker__hint-badge.is-subsumed {
    background: rgba(128, 128, 128, 0.16);
    color: var(--text-color-medium, #9ca3af);
    border-color: rgba(128, 128, 128, 0.30);
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
    gap: 4px;
}

.tachyon-ruleset-picker__cat-btn {
    padding: 3px 9px;
    border-radius: 7px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
    color: inherit;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-ruleset-picker__cat-btn:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent) !important;
}

.tachyon-ruleset-picker__cat-btn.is-active,
.tachyon-ruleset-picker__cat-btn.is-active:hover,
.tachyon-ruleset-picker__cat-btn.is-active:focus {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent) !important;
    color: var(--tachyon-accent-text) !important;
    font-weight: 600;
    box-shadow: none !important;
}

.tachyon-ruleset-picker__search {
    flex: 1 1 200px !important;
    min-width: 160px !important;
    width: auto !important;
    max-width: 100% !important;
    padding: 5px 10px !important;
    font-size: 12px !important;
    border-radius: 7px !important;
    box-sizing: border-box !important;
}

.tachyon-ruleset-picker__grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 210px), 1fr));
    gap: 6px;
    max-height: none;
    overflow: visible;
    padding: 0;
}

@media (max-width: 520px) {
    .tachyon-ruleset-picker__grid {
        grid-template-columns: 1fr;
    }
    .tachyon-ruleset-picker__cats {
        flex-wrap: nowrap;
        overflow-x: auto;
        padding-bottom: 2px;
        -webkit-overflow-scrolling: touch;
    }
}

.tachyon-ruleset-picker__chip {
    display: flex;
    align-items: center;
    justify-content: flex-start;
    width: 100%;
    min-width: 0;
    gap: 6px;
    padding: 6px 9px;
    border-radius: 8px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22)) !important;
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
    color: inherit;
    font-size: 11.5px;
    font-weight: 600;
    text-align: left;
    cursor: pointer;
    box-sizing: border-box;
    transition: border-color 0.14s ease, background-color 0.14s ease, color 0.14s ease;
}

.tachyon-ruleset-picker__chip-label {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-ruleset-picker__chip:hover {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 7%, transparent);
}

.tachyon-ruleset-picker__chip.is-selected,
.tachyon-ruleset-picker__chip.is-selected:hover,
.tachyon-ruleset-picker__chip.is-selected:focus {
    border-color: color-mix(in srgb, var(--tachyon-accent) 38%, transparent) !important;
    background: color-mix(in srgb, var(--tachyon-accent) 13%, transparent) !important;
    color: var(--tachyon-accent-text) !important;
    font-weight: 600;
}

.tachyon-ruleset-picker__chip.is-subsumed,
.tachyon-ruleset-picker__chip.is-subsumed:hover,
.tachyon-ruleset-picker__chip:disabled {
    opacity: 0.42;
    cursor: not-allowed;
    border-style: dashed !important;
    border-color: var(--border-color-low, rgba(128, 128, 128, 0.22)) !important;
    background: rgba(128, 128, 128, 0.04) !important;
    color: var(--text-color-medium, inherit) !important;
}

.tachyon-ruleset-picker__chip-check {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 600;
    opacity: 0.85;
}

.tachyon-ruleset-picker__chip-route {
    font-size: 9.5px;
    font-weight: 600;
    padding: 1px 5px;
    border-radius: 4px;
    background: color-mix(in srgb, var(--tachyon-accent) 14%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-ruleset-picker__chip-route.is-subsumed {
    background: rgba(128, 128, 128, 0.18);
    color: var(--text-color-medium, #9ca3af);
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
    font-weight: 600;
    opacity: 0.65;
    margin-left: 2px;
    background: rgba(128, 128, 128, 0.14);
}

.tachyon-ruleset-picker__chip-info:hover {
    opacity: 1;
    background: color-mix(in srgb, var(--tachyon-accent) 20%, transparent);
    color: var(--tachyon-accent-text);
}

.tachyon-ruleset-picker__empty {
    font-size: 12px;
    opacity: 0.68;
    padding: 8px 4px;
}

/* Lucide SVG Icons Integration across UI components */
.tachyon-studio-chip svg,
.tachyon-studio-action-btn svg,
.tachyon-studio-btn svg,
.tachyon-studio-view-btn svg,
.tachyon-topbar__wizard-btn svg,
.tachyon-topbar__eco-btn svg,
.tachyon-routing-row__engine-badge svg,
.tachyon-ruleset-picker__cat-btn svg,
.tachyon-sec-modal__badge-active svg,
.tachyon-sec-modal__badge-type svg,
.tachyon-dash-widget-row__icon svg,
.tachyon-dash-preset-card__icon svg,
.tachyon-dash-preset-pill__icon svg,
.tachyon-icon-picker__chip svg,
.tachyon-wizard__chip svg,
.tachyon-wizard__pill-btn svg {
    flex-shrink: 0;
    stroke: currentColor;
    vertical-align: middle;
}

.tachyon-routing-row__engine-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-sec-modal__badge-active,
.tachyon-sec-modal__badge-type {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-ruleset-picker__cat-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
}

.tachyon-dash-preset-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon-dash-preset-pill__icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon-dash-widget-row__icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon-dash-preset-card__icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

/* Tachyon-UI Pure JSON Mode & Fluid Micro-Animations */
#view > .cbi-page-actions,
#cbi-tachyon ~ .cbi-page-actions,
.cbi-page-actions:not(.modal .cbi-page-actions),
#indicators,
#unsaved-changes,
.uci-change-list,
.uci-change-legend,
body > header,
body > footer {
    display: none !important;
}

@keyframes tachyonUiFadeSlideIn {
    from {
        opacity: 0;
        transform: translateY(4px);
    }
    to {
        opacity: 1;
        transform: translateY(0);
    }
}

@keyframes tachyonUiModalScaleIn {
    from {
        opacity: 0;
        transform: scale(0.97) translateY(6px);
    }
    to {
        opacity: 1;
        transform: scale(1) translateY(0);
    }
}

.tachyon-routing-row,
.tachyon-routing-bento-card,
.tachyon-routing-compact-tile,
.tachyon-routing-matrix-card,
.tachyon-studio-card,
.tachyon-kpi-card {
    transition:
        transform 0.18s cubic-bezier(0.22, 1, 0.36, 1),
        border-color 0.18s cubic-bezier(0.22, 1, 0.36, 1),
        background-color 0.18s cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow 0.18s cubic-bezier(0.22, 1, 0.36, 1);
}

.tachyon-routing-row:hover,
.tachyon-studio-card:hover {
    border-color: rgba(10, 132, 255, 0.34);
    box-shadow: 0 6px 20px -6px rgba(0, 0, 0, 0.45), 0 0 0 1px rgba(10, 132, 255, 0.12);
}

.tachyon-routing-row__icon {
    transition:
        transform 0.18s cubic-bezier(0.22, 1, 0.36, 1),
        border-color 0.18s ease,
        background-color 0.18s ease;
}

.tachyon-routing-row__icon:hover {
    transform: scale(1.06);
    border-color: rgba(10, 132, 255, 0.45) !important;
    background: rgba(10, 132, 255, 0.14) !important;
}

.tachyon-routing-row__accordion {
    animation: tachyonUiFadeSlideIn 0.2s cubic-bezier(0.22, 1, 0.36, 1);
}

#modal_overlay > .modal,
#modal_overlay > .cbi-modal {
    animation: tachyonUiModalScaleIn 0.2s cubic-bezier(0.22, 1, 0.36, 1);
}

.tachyon-topbar__sidebar-pos-btn,
.tachyon-topbar__bg-anim-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
}

.tachyon-topbar__bg-anim-btn.is-disabled {
    opacity: 0.6;
}

/* ==========================================================================
   Snapshots Manager & High-Specificity Button / Scrollbar Overrides
   ========================================================================== */

.tachyon-snapshots-wrap {
    margin-bottom: 18px;
}

.tachyon-snapshots-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
    margin-bottom: 14px;
}

.tachyon-snapshots-header-info {
    display: flex;
    flex-direction: column;
    gap: 3px;
}

.tachyon-snapshots-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text, #f5f5f7);
    letter-spacing: -0.01em;
}

.tachyon-snapshots-subtitle {
    font-size: 12px;
    color: var(--muted, #8e8e93);
    line-height: 1.4;
}

.tachyon-snapshots-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-snapshots-empty {
    padding: 20px 16px;
    text-align: center;
    color: var(--muted, #8e8e93);
    font-size: 12.5px;
    border-radius: 10px;
    border: 1px dashed rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.015);
}

.tachyon-snapshot-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 14px;
    padding: 12px 14px;
    border-radius: 10px;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: border-color 0.15s ease, background-color 0.15s ease;
}

.tachyon-snapshot-row:hover {
    border-color: rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.038);
}

.tachyon-snapshot-main {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
    flex: 1 1 auto;
}

.tachyon-snapshot-title-line {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-snapshot-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text, #f5f5f7);
    word-break: break-word;
}

.tachyon-snapshot-id-badge {
    font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace);
    font-size: 11px;
    font-weight: 500;
    padding: 1px 6px;
    border-radius: 5px;
    background: rgba(255, 255, 255, 0.06);
    color: var(--muted, #8e8e93);
    border: 1px solid rgba(255, 255, 255, 0.06);
}

.tachyon-snapshot-meta {
    font-size: 11.5px;
    color: var(--muted, #8e8e93);
    font-variant-numeric: tabular-nums;
}

.tachyon-snapshot-components {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
}

.tachyon-snapshot-comp-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2px 7px;
    border-radius: 5px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 11px;
    line-height: 1.3;
}

.tachyon-snapshot-comp-name {
    color: #c7c7cc;
    font-weight: 500;
}

.tachyon-snapshot-comp-ver {
    color: #8e8e93;
    font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace);
    font-variant-numeric: tabular-nums;
}

.tachyon-snapshot-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
}

/* Eliminate solid bright-blue LuCI theme overrides on all buttons */
html body #maincontent .cbi-button,
html body #maincontent input.cbi-button,
html body #maincontent button.cbi-button,
html body #maincontent .btn,
html body #modal_overlay .cbi-button,
html body #modal_overlay .btn {
    background-image: none !important;
    text-shadow: none !important;
}

html body #maincontent .cbi-button-action,
html body #maincontent input.cbi-button-action,
html body #maincontent button.cbi-button-action,
html body #maincontent .cbi-button-action.important,
html body #maincontent input.cbi-button-action.important,
html body #maincontent button.cbi-button-action.important,
html body #maincontent .cbi-button-apply,
html body #maincontent input.cbi-button-apply,
html body #maincontent .cbi-button-save,
html body #maincontent .cbi-button-positive,
html body #modal_overlay .cbi-button-action,
html body #modal_overlay .cbi-button-action.important,
html body #modal_overlay .cbi-button-positive,
html body #modal_overlay .cbi-button-apply {
    background: rgba(10, 132, 255, 0.14) !important;
    background-color: rgba(10, 132, 255, 0.14) !important;
    background-image: none !important;
    color: #5eb0ff !important;
    border: 1px solid rgba(10, 132, 255, 0.32) !important;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06) !important;
}

html body #maincontent .cbi-button-action:hover:not(:disabled),
html body #maincontent input.cbi-button-action:hover:not(:disabled),
html body #maincontent button.cbi-button-action:hover:not(:disabled),
html body #maincontent .cbi-button-action.important:hover:not(:disabled),
html body #maincontent .cbi-button-apply:hover:not(:disabled),
html body #maincontent .cbi-button-positive:hover:not(:disabled),
html body #modal_overlay .cbi-button-action:hover:not(:disabled),
html body #modal_overlay .cbi-button-action.important:hover:not(:disabled),
html body #modal_overlay .cbi-button-positive:hover:not(:disabled) {
    background: rgba(10, 132, 255, 0.22) !important;
    background-color: rgba(10, 132, 255, 0.22) !important;
    color: #82c2ff !important;
    border-color: rgba(10, 132, 255, 0.48) !important;
}

/* Remove redundant inner scrollbars in workspace panes */
.tachyon-section-subpane,
.tachyon_dashboard-page,
.tachyon-routing-sections-block,
.tachyon-routing-sections-list,
#cbi-tachyon-dashboard,
#cbi-tachyon-section,
#cbi-tachyon-settings {
    overflow: visible !important;
    max-height: none !important;
}

#cbi-tachyon-settings .cbi-section-node > [data-tab][data-tab-active="true"],
#cbi-tachyon-settings .cbi-tabcontainer > [data-tab][data-tab-active="true"] {
    display: block !important;
    height: auto !important;
    opacity: 1 !important;
    overflow: visible !important;
}

#cbi-tachyon-settings .cbi-section-node > [data-tab][data-tab-active="false"],
#cbi-tachyon-settings .cbi-tabcontainer > [data-tab][data-tab-active="false"] {
    display: none !important;
}

.tachyon-ipv6-status-box {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    border-radius: 8px;
    border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128, 128, 128, 0.24)));
    background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128, 128, 128, 0.05)));
    font-size: 12.5px;
    line-height: 1.4;
}

.tachyon-ipv6-status-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 8px;
    border-radius: 6px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.24));
    background: var(--background-color-low, rgba(128, 128, 128, 0.08));
    font-size: 12px;
    font-weight: 600;
}

.tachyon-ipv6-status-pill--ok {
    border-color: rgba(16, 185, 129, 0.35);
    background: rgba(16, 185, 129, 0.1);
    color: var(--success-color, #10b981);
}

.tachyon-ipv6-status-pill--warn {
    border-color: rgba(245, 158, 11, 0.38);
    background: rgba(245, 158, 11, 0.1);
    color: var(--warning-color, #d97706);
}

.tachyon-ipv6-warning-banner {
    margin-top: 8px;
    padding: 8px 11px;
    border-radius: 8px;
    border: 1px solid rgba(245, 158, 11, 0.38);
    background: rgba(245, 158, 11, 0.09);
    color: inherit;
    font-size: 12px;
    line-height: 1.45;
}

.tachyon-history-btn {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    white-space: nowrap;
}

.tachyon-history-btn--icon {
    padding: 5px 8px;
}

.tachyon-history-btn__badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 16px;
    height: 16px;
    padding: 0 4px;
    border-radius: 999px;
    background: var(--tachyon-accent, #0a84ff);
    color: #fff;
    font-size: 10px;
    font-weight: 700;
    line-height: 1;
    font-variant-numeric: tabular-nums;
}

.tachyon-history-btn__badge.is-hidden {
    display: none;
}

.tachyon-sidebar__update-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 16px;
    height: 16px;
    padding: 0 5px;
    margin-left: auto;
    border-radius: 999px;
    background: var(--tachyon-accent, #0a84ff);
    color: #fff;
    font-size: 10px;
    font-weight: 700;
    line-height: 1;
    font-variant-numeric: tabular-nums;
}

.tachyon-sidebar__update-badge.is-hidden {
    display: none;
}

.tachyon-update-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px 12px;
    margin: 0 0 12px;
    padding: 8px 12px;
    border-radius: 8px;
    border: 1px solid rgba(10, 132, 255, 0.36);
    background: rgba(10, 132, 255, 0.08);
    font-size: 12.5px;
    line-height: 1.4;
}

.tachyon-update-banner.is-hidden {
    display: none;
}

.tachyon-update-banner__lead {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    color: var(--tachyon-text-primary, inherit);
    font-weight: 500;
    font-variant-numeric: tabular-nums;
}

.tachyon-update-banner__controls {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
}

.tachyon-update-banner__action {
    padding: 4px 10px;
    border-radius: 6px;
    border: 1px solid var(--tachyon-accent, #0a84ff);
    background: var(--tachyon-accent, #0a84ff);
    color: #fff;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.tachyon-update-banner__dismiss {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border-radius: 6px;
    border: 1px solid var(--tachyon-border-subtle, rgba(128, 128, 128, 0.25));
    background: transparent;
    color: inherit;
    cursor: pointer;
}

.tachyon-topbar.is-collapsed .tachyon-topbar__history-btn,
.tachyon-shell-layout[data-topbar-collapsed="true"] .tachyon-topbar__history-btn,
#cbi-tachyon[data-topbar-collapsed="true"] .tachyon-topbar__history-btn {
    display: none !important;
}

.tachyon-history-modal {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 4px 0;
}

.tachyon-history-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: var(--background-color-low, rgba(128, 128, 128, 0.05));
}

.tachyon-history-banner {
    border-color: rgba(245, 158, 11, 0.36);
    background: rgba(245, 158, 11, 0.08);
}

.tachyon-history-section__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-history-section__title {
    font-size: 13px;
    font-weight: 600;
    line-height: 1.3;
}

.tachyon-history-actions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-history-action-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 5px 10px;
    border-radius: 7px;
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.3));
    background: var(--background-color-high, rgba(128, 128, 128, 0.08));
    color: inherit;
    font-size: 12px;
    font-weight: 600;
    line-height: 1.25;
    cursor: pointer;
    transition: background-color 0.12s ease, border-color 0.12s ease;
}

.tachyon-history-action-btn:hover:not(:disabled) {
    background: var(--background-color-low, rgba(128, 128, 128, 0.16));
    border-color: var(--border-color-high, rgba(128, 128, 128, 0.45));
}

.tachyon-history-action-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.tachyon-history-action-btn--primary {
    border-color: color-mix(in srgb, var(--tachyon-accent, #0a84ff) 42%, transparent);
    background: color-mix(in srgb, var(--tachyon-accent, #0a84ff) 14%, transparent);
    color: var(--tachyon-accent-text, inherit);
}

.tachyon-history-action-btn.is-confirming {
    border-color: rgba(239, 68, 68, 0.55);
    background: rgba(239, 68, 68, 0.16);
    color: #ef4444;
}

.tachyon-history-status-host {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-history-alert {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 8px 12px;
    border-radius: 8px;
    border: 1px solid rgba(239, 68, 68, 0.38);
    background: rgba(239, 68, 68, 0.1);
}

.tachyon-history-alert__title {
    font-size: 12px;
    font-weight: 600;
    color: #ef4444;
}

.tachyon-history-alert__reason {
    font-size: 12px;
    line-height: 1.35;
    opacity: 0.92;
}

.tachyon-history-guard {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding: 8px 12px;
    border-radius: 8px;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    background: rgba(128, 128, 128, 0.06);
}

.tachyon-history-guard.is-observing {
    border-color: rgba(245, 158, 11, 0.38);
    background: rgba(245, 158, 11, 0.08);
}

.tachyon-history-guard__text {
    font-size: 12px;
    line-height: 1.35;
    flex: 1 1 240px;
}

.tachyon-history-list-host {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon-history-rev {
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.22));
    border-radius: 8px;
    background: var(--background-color-high, rgba(128, 128, 128, 0.04));
    overflow: hidden;
}

.tachyon-history-rev__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding: 8px 12px;
    cursor: pointer;
}

.tachyon-history-rev__head:hover {
    background: rgba(128, 128, 128, 0.06);
}

.tachyon-history-rev__meta {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
}

.tachyon-history-rev__time {
    font-size: 12px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
}

.tachyon-history-status {
    display: inline-flex;
    align-items: center;
    padding: 2px 7px;
    border-radius: 6px;
    font-size: 11px;
    font-weight: 600;
    line-height: 1.25;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.26));
    background: rgba(128, 128, 128, 0.1);
}

.tachyon-history-status--working {
    border-color: rgba(16, 185, 129, 0.36);
    background: rgba(16, 185, 129, 0.12);
    color: var(--success-color, #10b981);
}

.tachyon-history-status--failed {
    border-color: rgba(239, 68, 68, 0.4);
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
}

.tachyon-history-status--checking {
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.12);
    color: var(--warning-color, #d97706);
}

.tachyon-history-status--unverified {
    opacity: 0.78;
}

.tachyon-history-rev__tag {
    display: inline-flex;
    align-items: center;
    padding: 2px 6px;
    border-radius: 6px;
    font-size: 11px;
    font-weight: 600;
    background: rgba(128, 128, 128, 0.14);
}

.tachyon-history-rev__tag.is-rollback {
    border: 1px solid rgba(245, 158, 11, 0.35);
    background: rgba(245, 158, 11, 0.1);
}

.tachyon-history-rev__counts {
    font-size: 11.5px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    opacity: 0.75;
}

.tachyon-history-rev__body {
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.18));
    padding: 8px 12px;
}

.tachyon-history-rev__reason {
    margin-bottom: 8px;
    padding: 6px 8px;
    border-radius: 6px;
    border: 1px solid rgba(239, 68, 68, 0.32);
    background: rgba(239, 68, 68, 0.08);
    color: #ef4444;
    font-size: 11.5px;
    line-height: 1.35;
}

.tachyon-history-diff-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.tachyon-history-diff-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding: 4px 6px;
    border-radius: 6px;
    background: rgba(128, 128, 128, 0.05);
    font-size: 12px;
    line-height: 1.35;
}

.tachyon-history-diff-path {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    flex: 1 1 200px;
}

.tachyon-history-diff-scope {
    flex-shrink: 0;
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 10.5px;
    font-weight: 600;
    background: rgba(128, 128, 128, 0.16);
}

.tachyon-history-diff-target {
    font-weight: 600;
    word-break: break-word;
}

.tachyon-history-diff-vals {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    max-width: 100%;
    font-variant-numeric: tabular-nums;
}

.tachyon-history-val--before {
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
    word-break: break-all;
}

.tachyon-history-val--after {
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(16, 185, 129, 0.12);
    color: var(--success-color, #10b981);
    word-break: break-all;
}

.tachyon-history-diff-arrow {
    opacity: 0.6;
    font-size: 11px;
}

.tachyon-history-diff-more {
    padding: 4px 6px;
    font-size: 11.5px;
    opacity: 0.72;
}

.tachyon-history-empty {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    padding: 10px 12px;
    border-radius: 8px;
    background: rgba(128, 128, 128, 0.06);
    font-size: 12px;
    line-height: 1.4;
    opacity: 0.85;
}

.tachyon-history-empty.is-error {
    border: 1px solid rgba(239, 68, 68, 0.35);
    color: #ef4444;
    opacity: 1;
}

@media (max-width: 640px) {
    #cbi-tachyon {
        padding: 4px 4px 64px !important;
    }
    .tachyon-workspace-body .cbi-section.tachyon-has-studio-deck {
        padding: 0 !important;
        border: none !important;
        background: transparent !important;
        border-radius: 0 !important;
    }
    .tachyon-studio-panel,
    .tachyon-studio-toolbar {
        padding: 10px !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-body--cards {
        grid-template-columns: minmax(0, 1fr) !important;
        gap: 8px !important;
    }
    .tachyon-studio-card,
    .tachyon-studio-card--source-compact {
        padding: 10px !important;
        min-width: 0 !important;
        max-width: 100% !important;
        width: 100% !important;
    }
    .tachyon-studio-card__head {
        align-items: flex-start !important;
        gap: 8px !important;
        width: 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-card__identity,
    .tachyon-studio-card--source-compact .tachyon-studio-card__identity {
        min-width: 0 !important;
        max-width: 100% !important;
        flex: 1 1 0% !important;
        flex-wrap: wrap !important;
        align-items: center !important;
        gap: 6px 8px !important;
        overflow: visible !important;
    }
    .tachyon-studio-card__title-wrap {
        flex: 1 1 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-card__title {
        white-space: normal !important;
        overflow: visible !important;
        text-overflow: clip !important;
        overflow-wrap: anywhere !important;
    }
    .tachyon-studio-card__sid {
        white-space: normal !important;
        overflow-wrap: anywhere !important;
    }
    .tachyon-studio-source-compact__right {
        width: 100% !important;
        margin-left: 0 !important;
        justify-content: flex-start !important;
        gap: 6px !important;
    }
    .tachyon-studio-card__pipe-stage {
        flex: 1 1 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-card__pipe-arrow {
        display: none !important;
    }
    .tachyon-studio-card__chips {
        min-width: 0 !important;
        max-width: 100% !important;
    }
    .tachyon-studio-chip {
        max-width: 100% !important;
        min-width: 0 !important;
    }
    .tachyon-studio-filter-menu {
        left: 0 !important;
        right: auto !important;
        min-width: min(220px, calc(100vw - 32px)) !important;
        max-width: calc(100vw - 24px) !important;
    }
    .tachyon-studio-server-table th,
    .tachyon-studio-server-table td {
        padding: 6px 6px !important;
        font-size: 11.5px !important;
    }
    .tachyon-studio-server-table__idx,
    .tachyon-studio-server-table__proto,
    .tachyon-studio-server-table__actions {
        white-space: nowrap !important;
    }
    .tachyon-studio-server-table__name {
        min-width: 96px !important;
        word-break: normal !important;
        overflow-wrap: break-word !important;
    }
    .tachyon-studio-copy-link-btn {
        padding: 4px 7px !important;
    }
    .tachyon-studio-copy-link-btn > span {
        display: none !important;
    }
    .tachyon-history-diff-row {
        flex-direction: column;
        align-items: flex-start;
    }
}

/* ==========================================================================
   Compact Centered Website Layout (Default 1360px) & Full Width Toggle
   ========================================================================== */
:root:not([data-tachyon-width="full"]) .tachyon-shell-layout:not([data-tachyon-width="full"]) {
    max-width: 1360px !important;
    margin-left: auto !important;
    margin-right: auto !important;
    padding-left: 12px !important;
    padding-right: 12px !important;
}

:root:not([data-tachyon-width="full"]) .tachyon-shell-layout:not([data-sidebar-pos="top"]):not([data-tachyon-width="full"]) .tachyon-topbar,
:root:not([data-tachyon-width="full"]) .tachyon-shell-layout:not([data-sidebar-pos="top"]):not([data-tachyon-width="full"]) .tachyon-topbar__left,
:root:not([data-tachyon-width="full"]) .tachyon-shell-layout:not([data-sidebar-pos="top"]):not([data-tachyon-width="full"]) .tachyon-topbar__right {
    gap: 6px;
}

:root[data-tachyon-width="full"] .tachyon-shell-layout,
.tachyon-shell-layout[data-tachyon-width="full"] {
    max-width: 100% !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
    padding-left: 0 !important;
    padding-right: 0 !important;
}

@media (max-width: 1024px) {
    :root:not([data-tachyon-width="full"]) .tachyon-shell-layout:not([data-tachyon-width="full"]) {
        max-width: 100% !important;
        padding-left: 0 !important;
        padding-right: 0 !important;
    }
}

/* ==========================================================================
   Panel Authentication Card
   ========================================================================== */
.tachyon-auth-card {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
    border-radius: var(--r-card);
    background: var(--surface);
    border: 1px solid var(--border);
}

.tachyon-auth-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
}

.tachyon-auth-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
}

.tachyon-auth-sub {
    margin-top: 4px;
    font-size: 12px;
    color: var(--text2);
    line-height: 1.45;
    max-width: 680px;
}

.tachyon-auth-badge {
    display: inline-flex;
    align-items: center;
    padding: 4px 10px;
    border-radius: var(--r-xs);
    font-size: 11.5px;
    font-weight: 600;
    color: var(--text2);
    background: var(--hover);
    border: 1px solid var(--border);
    white-space: nowrap;
}

.tachyon-auth-badge.is-ok {
    color: var(--success);
    border-color: var(--border-strong);
}

.tachyon-auth-badge.is-warn {
    color: var(--warn);
    border-color: var(--border-strong);
}

.tachyon-auth-switch-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    font-weight: 500;
    color: var(--text);
    cursor: pointer;
}

.tachyon-auth-mode-tabs {
    display: flex;
    gap: 4px;
    padding: 4px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
    max-width: 520px;
}

.tachyon-auth-mode-btn {
    flex: 1 1 0;
    padding: 6px 12px;
    border-radius: var(--r-xs);
    border: none;
    background: transparent;
    color: var(--text2);
    font-size: 12.5px;
    font-weight: 500;
    cursor: pointer;
    transition: background var(--transition), color var(--transition);
}

.tachyon-auth-mode-btn:hover {
    color: var(--text);
    background: var(--hover);
}

.tachyon-auth-mode-btn.is-active {
    background: var(--elevated);
    color: var(--text);
}

.tachyon-auth-fields {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr));
    gap: 12px;
}

.tachyon-auth-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-auth-label {
    font-size: 12px;
    font-weight: 500;
    color: var(--text2);
}

.tachyon-auth-pw-wrap {
    display: flex;
    align-items: center;
    gap: 6px;
}

.tachyon-auth-input {
    width: 100%;
    min-width: 0;
    padding: 7px 10px !important;
    border-radius: var(--r-btn) !important;
    background: var(--bg) !important;
    border: 1px solid var(--border-strong) !important;
    color: var(--text) !important;
    font-size: 13px !important;
}

.tachyon-auth-eye-btn {
    padding: 5px 10px !important;
    font-size: 11.5px !important;
    flex-shrink: 0;
}

.tachyon-auth-note {
    grid-column: 1 / -1;
    padding: 10px 12px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
    font-size: 12px;
    color: var(--text2);
    line-height: 1.45;
}

.tachyon-auth-warn,
.tachyon-auth-error {
    padding: 8px 12px;
    border-radius: var(--r-btn);
    font-size: 12px;
    line-height: 1.4;
}

.tachyon-auth-warn {
    background: rgba(255, 159, 10, 0.12);
    border: 1px solid rgba(255, 159, 10, 0.35);
    color: var(--warn);
}

.tachyon-auth-error {
    background: rgba(255, 69, 58, 0.12);
    border: 1px solid rgba(255, 69, 58, 0.35);
    color: var(--danger);
}

.tachyon-auth-success {
    padding: 8px 12px;
    border-radius: var(--r-btn);
    background: rgba(48, 209, 88, 0.12);
    border: 1px solid rgba(48, 209, 88, 0.35);
    color: var(--success);
    font-size: 12px;
}

.tachyon-auth-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
}

/* ==========================================================================
   Unified 12-Theme Dropdown, Settings Grid & Custom Theme Modal
   ========================================================================== */
.tachyon-theme-dropdown-wrap {
    position: relative;
    display: inline-flex;
    align-items: center;
}

.tachyon-theme-trigger {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon-theme-trigger__dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    flex-shrink: 0;
    border: 1px solid rgba(255, 255, 255, 0.28);
}

.tachyon-theme-trigger__name {
    max-width: 118px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-theme-menu {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    min-width: 224px;
    max-width: calc(100vw - 24px);
    max-height: min(440px, 72vh);
    overflow-y: auto;
    padding: 6px;
    border-radius: 12px;
    background: var(--surface);
    border: 1px solid var(--border-strong);
    box-shadow: 0 18px 44px rgba(0, 0, 0, 0.55);
    display: flex;
    flex-direction: column;
    gap: 2px;
    z-index: 600;
}

.tachyon-theme-menu__item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 10px;
    border: none;
    border-radius: 8px;
    background: transparent;
    color: var(--text2);
    font-size: 12.5px;
    font-weight: 500;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition), color var(--transition);
}

.tachyon-theme-menu__item:hover {
    background: var(--hover);
    color: var(--text);
}

.tachyon-theme-menu__item.is-active {
    background: var(--elevated);
    color: var(--text);
}

.tachyon-theme-menu__swatch-pair {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
}

.tachyon-theme-menu__swatch-bg,
.tachyon-theme-menu__swatch-accent {
    width: 10px;
    height: 10px;
    border-radius: 3px;
    border: 1px solid rgba(255, 255, 255, 0.2);
}

.tachyon-theme-menu__label {
    flex: 1 1 auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-theme-menu__check {
    display: inline-flex;
    color: var(--accent);
    flex-shrink: 0;
}

.tachyon-theme-menu__sep {
    height: 1px;
    margin: 4px 6px;
    background: var(--border);
}

.tachyon-theme-menu__item--create {
    color: var(--accent);
}

.tachyon-theme-settings-card {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
    border-radius: var(--r-card);
    background: var(--surface);
    border: 1px solid var(--border);
}

.tachyon-theme-settings-hdr {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
}

.tachyon-theme-settings-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
}

.tachyon-theme-settings-sub {
    margin-top: 2px;
    font-size: 12px;
    color: var(--text2);
}

.tachyon-theme-settings-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-theme-cards-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 190px), 1fr));
    gap: 10px;
}

.tachyon-theme-card {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px;
    border-radius: 10px;
    background: var(--bg);
    border: 1px solid var(--border);
    cursor: pointer;
    transition: border-color var(--transition), background var(--transition);
}

.tachyon-theme-card:hover {
    border-color: var(--border-strong);
    background: var(--hover);
}

.tachyon-theme-card.is-active {
    border-color: var(--accent);
    background: var(--accent-soft, rgba(10, 132, 255, 0.14));
}

.tachyon-theme-card__preview {
    padding: 8px;
    border-radius: 7px;
    border: 1px solid transparent;
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-theme-card__preview-bar {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 6px;
    border-radius: 5px;
}

.tachyon-theme-card__dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
}

.tachyon-theme-card__preview-lines {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.tachyon-theme-card__line {
    height: 4px;
    border-radius: 2px;
    display: block;
}

.tachyon-theme-card__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
}

.tachyon-theme-card__name-wrap {
    display: flex;
    flex-direction: column;
    min-width: 0;
}

.tachyon-theme-card__name {
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-theme-card__scheme {
    font-size: 11px;
    color: var(--text3);
}

.tachyon-theme-card__active-tag {
    font-size: 11px;
    font-weight: 600;
    color: var(--accent);
    flex-shrink: 0;
}

.tachyon-theme-card__custom-ops {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
}

.tachyon-theme-mini-btn {
    padding: 2px 6px !important;
    min-height: 22px !important;
    font-size: 11px !important;
}

.tachyon-theme-modal-overlay {
    position: fixed;
    inset: 0;
    z-index: 950;
    background: rgba(0, 0, 0, 0.68);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px;
}

.tachyon-theme-modal {
    width: min(760px, 100%);
    max-height: 90vh;
    background: var(--surface);
    border: 1px solid var(--border-strong);
    border-radius: 14px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.65);
}

.tachyon-theme-modal__hdr,
.tachyon-theme-modal__ftr {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--bg);
}

.tachyon-theme-modal__ftr {
    border-bottom: none;
    border-top: 1px solid var(--border);
    justify-content: flex-end;
}

.tachyon-theme-modal__title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
}

.tachyon-theme-modal__body {
    padding: 16px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 14px;
}

.tachyon-theme-meta-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 190px), 1fr));
    gap: 10px;
}

.tachyon-theme-meta-col {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-theme-meta-lbl {
    font-size: 11.5px;
    font-weight: 500;
    color: var(--text2);
}

.tachyon-theme-input {
    width: 100%;
    padding: 6px 10px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border-strong);
    color: var(--text);
    font-size: 12.5px;
}

.tachyon-theme-scheme-tabs {
    display: flex;
    gap: 4px;
    padding: 3px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
}

.tachyon-theme-scheme-btn {
    flex: 1 1 0;
    padding: 5px 8px;
    border: none;
    border-radius: var(--r-xs);
    background: transparent;
    color: var(--text2);
    font-size: 12px;
    cursor: pointer;
}

.tachyon-theme-scheme-btn.is-active {
    background: var(--elevated);
    color: var(--text);
    font-weight: 600;
}

.tachyon-theme-live-preview {
    padding: 10px 12px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
}

.tachyon-theme-live-preview__title {
    font-size: 12px;
    color: var(--text2);
}

.tachyon-theme-live-preview__chips {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
}

.tachyon-theme-live-chip {
    padding: 2px 8px;
    border-radius: var(--r-xs);
    font-size: 11px;
    font-weight: 600;
    background: var(--hover);
    border: 1px solid var(--border);
}

.tachyon-theme-live-chip.is-accent { color: var(--accent); border-color: var(--accent); }
.tachyon-theme-live-chip.is-ok { color: var(--success); border-color: var(--success); }
.tachyon-theme-live-chip.is-warn { color: var(--warn); border-color: var(--warn); }
.tachyon-theme-live-chip.is-err { color: var(--danger); border-color: var(--danger); }

.tachyon-theme-pickers-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 220px), 1fr));
    gap: 8px;
}

.tachyon-theme-picker-row {
    display: flex;
    flex-direction: column;
    gap: 5px;
    padding: 8px 10px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
}

.tachyon-theme-picker-label {
    font-size: 11.5px;
    color: var(--text2);
}

.tachyon-theme-picker-controls {
    display: flex;
    align-items: center;
    gap: 8px;
}

.tachyon-theme-color-swatch {
    width: 34px;
    height: 28px;
    padding: 0;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: transparent;
    cursor: pointer;
    flex-shrink: 0;
}

.tachyon-theme-hex-input {
    flex: 1 1 0;
    min-width: 0;
    padding: 4px 8px;
    border-radius: 6px;
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
}

.tachyon-theme-json-panel {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px;
    border-radius: var(--r-btn);
    background: var(--bg);
    border: 1px solid var(--border);
}

.tachyon-theme-json-area {
    width: 100%;
    padding: 8px;
    border-radius: var(--r-xs);
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: var(--mono);
    font-size: 11.5px;
    resize: vertical;
}

.tachyon-theme-json-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-theme-json-ok {
    font-size: 12px;
    color: var(--success);
}

.tachyon-theme-json-err {
    font-size: 12px;
    color: var(--danger);
}

/* ==========================================================================
   Global Search / Command Palette (Ctrl+K)
   ========================================================================== */
.tachyon-cmdk-trigger {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon-cmdk-kbd {
    display: inline-flex;
    align-items: center;
    padding: 1px 5px;
    border-radius: 4px;
    background: var(--bg);
    border: 1px solid var(--border-strong);
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--text3);
}

.tachyon-cmdk-overlay {
    position: fixed;
    inset: 0;
    z-index: 980;
    background: rgba(0, 0, 0, 0.62);
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: min(10vh, 72px) 16px 20px;
}

.tachyon-cmdk-box {
    width: min(640px, 100%);
    max-height: 76vh;
    background: var(--surface);
    border: 1px solid var(--border-strong);
    border-radius: 14px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.65);
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.tachyon-cmdk-input-wrap {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 14px;
    border-bottom: 1px solid var(--border);
    background: var(--bg);
}

.tachyon-cmdk-input {
    flex: 1 1 auto;
    min-width: 0;
    border: none !important;
    background: transparent !important;
    color: var(--text) !important;
    font-size: 14px !important;
    outline: none !important;
    padding: 2px 0 !important;
    box-shadow: none !important;
}

.tachyon-cmdk-list {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon-cmdk-group {
    padding: 6px 10px 4px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text3);
}

.tachyon-cmdk-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    width: 100%;
    padding: 8px 10px;
    border: 1px solid transparent;
    border-radius: 8px;
    background: transparent;
    color: var(--text);
    text-align: left;
    cursor: pointer;
    transition: background var(--transition), border-color var(--transition);
}

.tachyon-cmdk-item:hover,
.tachyon-cmdk-item.is-selected {
    background: var(--hover);
    border-color: var(--border-strong);
}

.tachyon-cmdk-item.is-selected {
    background: var(--accent-soft, rgba(10, 132, 255, 0.16));
    border-color: var(--accent-ring, rgba(10, 132, 255, 0.34));
}

.tachyon-cmdk-item__main {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon-cmdk-item__title {
    font-size: 13px;
    font-weight: 500;
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-cmdk-item__sub {
    font-size: 11.5px;
    color: var(--text2);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon-cmdk-item__badge {
    flex-shrink: 0;
    padding: 2px 7px;
    border-radius: var(--r-xs);
    background: var(--bg);
    border: 1px solid var(--border);
    font-family: var(--mono);
    font-size: 11px;
    color: var(--text2);
}

.tachyon-cmdk-empty {
    padding: 24px 12px;
    text-align: center;
    font-size: 12.5px;
    color: var(--text3);
}

.tachyon-cmdk-ftr {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 8px 14px;
    border-top: 1px solid var(--border);
    background: var(--bg);
    font-size: 11.5px;
    color: var(--text3);
    flex-wrap: wrap;
}

.tachyon-ruleset-picker__chip-recommended {
    font-size: 10.5px;
    font-weight: 600;
    color: var(--accent, #0a84ff);
    opacity: 0.9;
    white-space: nowrap;
}

.tachyon-exit-country-pill {
    transition: border-color 140ms ease, background-color 140ms ease;
}

.tachyon-exit-country-pill:hover {
    border-color: var(--border-strong, rgba(255, 255, 255, 0.22));
}

.tachyon-exit-country-pill__icon {
    opacity: 0.65;
    flex-shrink: 0;
}

.tachyon-exit-country-pill__icon.is-spinning {
    animation: tachyon-spin 0.9s linear infinite;
}

@keyframes tachyon-spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
}
`;
