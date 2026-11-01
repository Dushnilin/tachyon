// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `
.tachyon_monitoring-page {
    --tachyon-monitoring-danger-color: #d9534f;
}

#cbi-${TACHYON_CBI_PREFIX}-monitoring-_mount_node {
    margin: 16px 0 22px;
    padding: 0;
}

#cbi-${TACHYON_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${TACHYON_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-field {
    margin-left: 0;
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-monitoring-_mount_node > div {
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-monitoring > h3 {
    display: none;
}

.tachyon_monitoring-page {
    --tachyon-monitoring-control-height: 36px;
    --tachyon-monitoring-row-action-size: 26px;
    --tachyon-monitoring-divider-color: rgba(148, 163, 184, 0.22);
    --tachyon-monitoring-soft-bg: rgba(148, 163, 184, 0.10);
    --tachyon-monitoring-soft-bg-hover: rgba(148, 163, 184, 0.18);
    --tachyon-monitoring-danger-color: var(--error-color-medium, #ef4444);
    --tachyon-monitoring-success-color: var(--success-color-medium, #10b981);
    --tachyon-monitoring-paused-color: #7c3aed;
    --tachyon-monitoring-tabs-bg: var(--background-color-low, #f1f5f9);
    --tachyon-monitoring-tab-active-bg: rgba(124, 58, 237, 0.14);
    --tachyon-monitoring-tab-active-color: #5b21b6;
    --tachyon-monitoring-tab-badge-active-bg: rgba(124, 58, 237, 0.20);
    --tachyon-monitoring-tab-badge-active-color: #4c1d95;
    --tachyon-monitoring-table-bg: var(--background-color-high, #ffffff);
    --tachyon-monitoring-th-bg: var(--background-color-low, rgba(148, 163, 184, 0.10));
    --tachyon-monitoring-th-color: var(--text-color-medium, #475569);
    --tachyon-monitoring-text-primary: var(--text-color-high, #0f172a);
    --tachyon-monitoring-text-secondary: var(--text-color-medium, #475569);
    --tachyon-monitoring-route-default-fg: #334155;
    --tachyon-monitoring-route-proxy-fg: #6d28d9;
    --tachyon-monitoring-route-dpi-fg: #b45309;
    --tachyon-monitoring-route-direct-fg: #15803d;
    --tachyon-monitoring-route-block-fg: #be123c;
    --tachyon-monitoring-net-tcp-fg: #0369a1;
    --tachyon-monitoring-net-udp-fg: #047857;
    --tachyon-monitoring-net-quic-fg: #4338ca;

    width: 100%;
    min-width: 0;
}

@media (prefers-color-scheme: dark) {
    .tachyon_monitoring-page {
        --tachyon-monitoring-divider-color: rgba(148, 163, 184, 0.18);
        --tachyon-monitoring-soft-bg: rgba(148, 163, 184, 0.08);
        --tachyon-monitoring-soft-bg-hover: rgba(148, 163, 184, 0.15);
        --tachyon-monitoring-paused-color: #9482e0;
        --tachyon-monitoring-tabs-bg: rgba(15, 23, 42, 0.28);
        --tachyon-monitoring-tab-active-bg: rgba(148, 130, 224, 0.18);
        --tachyon-monitoring-tab-active-color: #c4b5fd;
        --tachyon-monitoring-tab-badge-active-bg: rgba(148, 130, 224, 0.28);
        --tachyon-monitoring-tab-badge-active-color: #f1f5f9;
        --tachyon-monitoring-table-bg: rgba(15, 23, 42, 0.18);
        --tachyon-monitoring-th-bg: rgba(148, 163, 184, 0.06);
        --tachyon-monitoring-th-color: #94a3b8;
        --tachyon-monitoring-text-primary: var(--text-color-high, #f1f5f9);
        --tachyon-monitoring-text-secondary: var(--text-color-medium, #cbd5e1);
        --tachyon-monitoring-route-default-fg: #e2e8f0;
        --tachyon-monitoring-route-proxy-fg: #c084fc;
        --tachyon-monitoring-route-dpi-fg: #fbbf24;
        --tachyon-monitoring-route-direct-fg: #4ade80;
        --tachyon-monitoring-route-block-fg: #fb7185;
        --tachyon-monitoring-net-tcp-fg: #38bdf8;
        --tachyon-monitoring-net-udp-fg: #34d399;
        --tachyon-monitoring-net-quic-fg: #818cf8;
    }
}

[data-darkmode="true"] .tachyon_monitoring-page,
body.dark .tachyon_monitoring-page {
    --tachyon-monitoring-divider-color: rgba(148, 163, 184, 0.18);
    --tachyon-monitoring-soft-bg: rgba(148, 163, 184, 0.08);
    --tachyon-monitoring-soft-bg-hover: rgba(148, 163, 184, 0.15);
    --tachyon-monitoring-paused-color: #9482e0;
    --tachyon-monitoring-tabs-bg: rgba(15, 23, 42, 0.28);
    --tachyon-monitoring-tab-active-bg: rgba(148, 130, 224, 0.18);
    --tachyon-monitoring-tab-active-color: #c4b5fd;
    --tachyon-monitoring-tab-badge-active-bg: rgba(148, 130, 224, 0.28);
    --tachyon-monitoring-tab-badge-active-color: #f1f5f9;
    --tachyon-monitoring-table-bg: rgba(15, 23, 42, 0.18);
    --tachyon-monitoring-th-bg: rgba(148, 163, 184, 0.06);
    --tachyon-monitoring-th-color: #94a3b8;
    --tachyon-monitoring-text-primary: var(--text-color-high, #f1f5f9);
    --tachyon-monitoring-text-secondary: var(--text-color-medium, #cbd5e1);
    --tachyon-monitoring-route-default-fg: #e2e8f0;
    --tachyon-monitoring-route-proxy-fg: #c084fc;
    --tachyon-monitoring-route-dpi-fg: #fbbf24;
    --tachyon-monitoring-route-direct-fg: #4ade80;
    --tachyon-monitoring-route-block-fg: #fb7185;
    --tachyon-monitoring-net-tcp-fg: #38bdf8;
    --tachyon-monitoring-net-udp-fg: #34d399;
    --tachyon-monitoring-net-quic-fg: #818cf8;
}

[data-darkmode="false"] .tachyon_monitoring-page {
    --tachyon-monitoring-divider-color: rgba(148, 163, 184, 0.24);
    --tachyon-monitoring-soft-bg: rgba(148, 163, 184, 0.10);
    --tachyon-monitoring-soft-bg-hover: rgba(148, 163, 184, 0.18);
    --tachyon-monitoring-paused-color: #7c3aed;
    --tachyon-monitoring-tabs-bg: var(--background-color-low, #f1f5f9);
    --tachyon-monitoring-tab-active-bg: rgba(124, 58, 237, 0.14);
    --tachyon-monitoring-tab-active-color: #5b21b6;
    --tachyon-monitoring-tab-badge-active-bg: rgba(124, 58, 237, 0.20);
    --tachyon-monitoring-tab-badge-active-color: #4c1d95;
    --tachyon-monitoring-table-bg: var(--background-color-high, #ffffff);
    --tachyon-monitoring-th-bg: var(--background-color-low, rgba(148, 163, 184, 0.10));
    --tachyon-monitoring-th-color: var(--text-color-medium, #475569);
    --tachyon-monitoring-text-primary: var(--text-color-high, #0f172a);
    --tachyon-monitoring-text-secondary: var(--text-color-medium, #475569);
    --tachyon-monitoring-route-default-fg: #334155;
    --tachyon-monitoring-route-proxy-fg: #6d28d9;
    --tachyon-monitoring-route-dpi-fg: #b45309;
    --tachyon-monitoring-route-direct-fg: #15803d;
    --tachyon-monitoring-route-block-fg: #be123c;
    --tachyon-monitoring-net-tcp-fg: #0369a1;
    --tachyon-monitoring-net-udp-fg: #047857;
    --tachyon-monitoring-net-quic-fg: #4338ca;
}

.tachyon_monitoring-page__panel {
    margin-top: 0;
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.22));
    border-radius: var(--tachyon-radius-card, 14px);
    padding: 18px 20px;
    background: var(--tachyon-bg-card, var(--background-color-high, rgba(128, 128, 128, 0.04)));
    box-shadow: var(--tachyon-shadow-card, none);
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 14px;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button {
    width: 36px;
    height: 36px;
    min-width: 36px;
    min-height: 36px;
    padding: 0 !important;
    box-sizing: border-box;
    display: inline-flex !important;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
    border: 1px solid var(--tachyon-monitoring-divider-color) !important;
    border-radius: 9px !important;
    background: var(--tachyon-monitoring-soft-bg) !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
    transition: border-color 0.15s ease, background 0.15s ease, color 0.15s ease;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button:hover:not(:disabled) {
    background: var(--tachyon-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button--active {
    background: var(--tachyon-monitoring-tab-active-bg) !important;
    border-color: rgba(148, 130, 224, 0.4) !important;
    color: var(--tachyon-monitoring-tab-active-color) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button:disabled {
    opacity: 0.42;
    cursor: not-allowed;
}

.tachyon_monitoring-page #monitoring-close-all.btn.tachyon_monitoring-page__icon-button {
    order: 2;
    border-color: rgba(148, 163, 184, 0.24) !important;
    background: rgba(148, 163, 184, 0.06) !important;
    color: var(--text-color-medium, #94a3b8) !important;
}

.tachyon_monitoring-page #monitoring-close-all.btn.tachyon_monitoring-page__icon-button:hover:not(:disabled) {
    border-color: rgba(239, 68, 68, 0.5) !important;
    background: rgba(239, 68, 68, 0.12) !important;
    color: #fca5a5 !important;
}

.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button,
.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button--active {
    order: 1;
    border-color: rgba(148, 163, 184, 0.24) !important;
    background: rgba(148, 163, 184, 0.06) !important;
    color: var(--text-color-medium, #94a3b8) !important;
}

.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button:hover:not(:disabled),
.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button--active:hover:not(:disabled) {
    border-color: rgba(148, 130, 224, 0.4) !important;
    background: rgba(148, 130, 224, 0.12) !important;
    color: var(--text-color-high, #f8fafc) !important;
}

.tachyon_monitoring-page__icon-button svg,
.tachyon_monitoring-page__row-action svg {
    width: 16px;
    height: 16px;
    display: block;
    flex: 0 0 auto;
}

.tachyon_monitoring-page__controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-bottom: 0;
    width: 100%;
    min-width: 0;
}

.tachyon_monitoring-page__actions {
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    flex: 0 0 auto;
    min-width: 0;
}

.tachyon_monitoring-page__tabs {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    width: max-content;
    flex: 0 0 auto;
    height: var(--tachyon-monitoring-control-height);
    padding: 3px;
    border: 1px solid var(--tachyon-monitoring-divider-color);
    border-radius: 10px;
    background: var(--tachyon-monitoring-tabs-bg);
    box-sizing: border-box;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab {
    height: calc(var(--tachyon-monitoring-control-height) - 8px);
    min-height: calc(var(--tachyon-monitoring-control-height) - 8px);
    margin: 0;
    padding: 0 12px !important;
    border: 0 !important;
    border-radius: 7px !important;
    background: transparent !important;
    color: var(--tachyon-monitoring-text-secondary) !important;
    box-shadow: none;
    display: inline-flex !important;
    align-items: center;
    justify-content: center;
    gap: 7px;
    font-size: 12.5px !important;
    font-weight: 600 !important;
    line-height: 1 !important;
    white-space: nowrap !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab:hover {
    background: var(--tachyon-monitoring-soft-bg-hover) !important;
    color: var(--tachyon-monitoring-text-primary) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab--active {
    background: var(--tachyon-monitoring-tab-active-bg) !important;
    color: var(--tachyon-monitoring-tab-active-color) !important;
    font-weight: 700 !important;
}

.tachyon_monitoring-page__tab-label {
    display: inline-block;
}

.tachyon_monitoring-page__tab-badge {
    min-width: 20px;
    height: 18px;
    padding: 0 6px;
    border-radius: 999px;
    background: rgba(148, 163, 184, 0.22);
    color: var(--tachyon-monitoring-text-secondary);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
}

.tachyon_monitoring-page__tab--active .tachyon_monitoring-page__tab-badge {
    background: var(--tachyon-monitoring-tab-badge-active-bg);
    color: var(--tachyon-monitoring-tab-badge-active-color);
}

.tachyon_monitoring-page__filters {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 10px;
    flex: 1 1 auto;
    min-width: 0;
}

.tachyon_monitoring-page__device-filter,
.tachyon_monitoring-page__route-filter {
    flex: 0 1 180px;
    min-width: 130px !important;
    max-width: 220px !important;
    width: auto !important;
    height: var(--tachyon-monitoring-control-height) !important;
    min-height: var(--tachyon-monitoring-control-height) !important;
    padding: 0 28px 0 10px !important;
    margin: 0 !important;
    border-radius: 9px !important;
    box-sizing: border-box !important;
    background-color: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.08)) !important;
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.2)) !important;
    color: var(--tachyon-monitoring-text-primary) !important;
    line-height: calc(var(--tachyon-monitoring-control-height) - 2px) !important;
}

.tachyon_monitoring-page__search {
    position: relative;
    display: flex;
    align-items: center;
    flex: 1 1 200px;
    width: auto;
    max-width: none;
    min-width: 150px;
    height: var(--tachyon-monitoring-control-height);
    margin: 0;
}

.tachyon_monitoring-page__search-icon {
    position: absolute;
    left: 10px;
    width: 15px;
    height: 15px;
    color: var(--text-color-medium);
    pointer-events: none;
    z-index: 1;
}

.tachyon_monitoring-page__search-icon svg {
    width: 15px;
    height: 15px;
    display: block;
}

.tachyon_monitoring-page__search-input {
    width: 100% !important;
    max-width: none !important;
    height: var(--tachyon-monitoring-control-height) !important;
    min-height: var(--tachyon-monitoring-control-height) !important;
    padding-left: 32px !important;
    padding-right: 10px !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    border-radius: 9px !important;
    box-sizing: border-box;
    line-height: calc(var(--tachyon-monitoring-control-height) - 2px) !important;
}

.tachyon_monitoring-page__body {
    margin-top: 0;
    width: 100%;
    min-width: 0;
}

.tachyon_monitoring-page__table-wrap {
    width: 100%;
    overflow-x: auto;
    margin-bottom: 0;
    border-radius: 12px;
    border: 1px solid var(--tachyon-monitoring-divider-color);
    background: var(--tachyon-monitoring-table-bg);
}

.tachyon_monitoring-page__table {
    width: 100%;
    min-width: 820px;
    table-layout: fixed;
    border-collapse: collapse !important;
    border-spacing: 0;
    margin-bottom: 0;
    border: none !important;
    background: transparent !important;
}

.tachyon_monitoring-page__table th,
.tachyon_monitoring-page__table td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--tachyon-monitoring-divider-color);
    box-sizing: border-box;
    text-align: left;
    vertical-align: middle;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap !important;
    word-break: normal !important;
    overflow-wrap: normal !important;
}

.tachyon_monitoring-page__table th {
    color: var(--tachyon-monitoring-th-color);
    background: var(--tachyon-monitoring-th-bg);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    white-space: nowrap !important;
    word-break: normal !important;
    border-bottom: 1px solid rgba(148, 163, 184, 0.22);
}

.tachyon_monitoring-page__table tbody tr:hover {
    background: rgba(139, 92, 246, 0.04);
}

.tachyon_monitoring-page__table th:nth-child(1) {
    width: 26%;
}

.tachyon_monitoring-page__table th:nth-child(2) {
    width: 7%;
}

.tachyon_monitoring-page__table th:nth-child(3) {
    width: 13%;
}

.tachyon_monitoring-page__table th:nth-child(4) {
    width: 8%;
}

.tachyon_monitoring-page__table th:nth-child(5) {
    width: 12%;
}

.tachyon_monitoring-page__table th:nth-child(6) {
    width: 10%;
}

.tachyon_monitoring-page__table th:nth-child(7) {
    width: 16%;
}

.tachyon_monitoring-page__table th:nth-child(8) {
    width: 8%;
}

.tachyon_monitoring-page__table tbody tr:last-child td {
    border-bottom: 0;
}

.tachyon_monitoring-page__table td:last-child {
    padding-top: 0;
    padding-bottom: 0;
}

.tachyon_monitoring-page__table th:nth-child(4),
.tachyon_monitoring-page__table td:nth-child(4),
.tachyon_monitoring-page__table th:nth-child(5),
.tachyon_monitoring-page__table td:nth-child(5),
.tachyon_monitoring-page__table th:nth-child(6),
.tachyon_monitoring-page__table td:nth-child(6) {
    text-align: right;
}

.tachyon_monitoring-page__table th:nth-child(7),
.tachyon_monitoring-page__table td:nth-child(7) {
    text-align: left;
}

.tachyon_monitoring-page__table th:last-child,
.tachyon_monitoring-page__table td:last-child {
    text-align: center;
}

.tachyon_monitoring-page__value {
    display: block;
    max-width: 100%;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    text-align: left;
    line-height: 1.3;
    color: var(--tachyon-monitoring-text-primary);
    font-size: 13px;
    user-select: text;
}

.tachyon_monitoring-page__source-value {
    display: flex;
    align-items: baseline;
    justify-content: flex-start;
    gap: 5px;
}

.tachyon_monitoring-page__source-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_monitoring-page__source-ip {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--tachyon-monitoring-text-secondary);
    font-size: 12px;
}

.tachyon_monitoring-page__source-value--ip-only {
    color: var(--tachyon-monitoring-text-primary);
}

.tachyon_monitoring-page__cell-main {
    color: var(--tachyon-monitoring-text-primary);
    font-weight: 600;
    line-height: 1.25;
}

.tachyon_monitoring-page__cell-secondary {
    margin-top: 2px;
    color: var(--tachyon-monitoring-text-secondary);
    font-size: 12px;
    line-height: 1.25;
}

.tachyon_monitoring-page__route {
    display: inline-block;
    width: auto;
    padding: 2px 7px;
    border-radius: 6px;
    background: rgba(148, 163, 184, 0.14);
    border: 1px solid rgba(148, 163, 184, 0.28);
    color: var(--tachyon-monitoring-route-default-fg);
    font-size: 11px;
    font-weight: 600;
}

.tachyon_monitoring-page__route[data-rule-tooltip] {
    cursor: help;
}

.tachyon_monitoring-page__route--proxy {
    background: rgba(168, 85, 247, 0.14) !important;
    border-color: rgba(168, 85, 247, 0.32) !important;
    color: var(--tachyon-monitoring-route-proxy-fg) !important;
}

.tachyon_monitoring-page__route--dpi {
    background: rgba(245, 158, 11, 0.14) !important;
    border-color: rgba(245, 158, 11, 0.32) !important;
    color: var(--tachyon-monitoring-route-dpi-fg) !important;
}

.tachyon_monitoring-page__route--direct {
    background: rgba(34, 197, 94, 0.14) !important;
    border-color: rgba(34, 197, 94, 0.32) !important;
    color: var(--tachyon-monitoring-route-direct-fg) !important;
}

.tachyon_monitoring-page__route--block {
    background: rgba(244, 63, 94, 0.14) !important;
    border-color: rgba(244, 63, 94, 0.32) !important;
    color: var(--tachyon-monitoring-route-block-fg) !important;
}

.tachyon_monitoring-page__network {
    display: inline-block;
    width: auto;
    padding: 2px 7px;
    border-radius: 6px;
    background: rgba(148, 163, 184, 0.14);
    border: 1px solid rgba(148, 163, 184, 0.24);
    color: var(--tachyon-monitoring-text-secondary);
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
}

.tachyon_monitoring-page__network--tcp {
    background: rgba(56, 189, 248, 0.14) !important;
    border-color: rgba(56, 189, 248, 0.32) !important;
    color: var(--tachyon-monitoring-net-tcp-fg) !important;
}

.tachyon_monitoring-page__network--udp {
    background: rgba(52, 211, 153, 0.14) !important;
    border-color: rgba(52, 211, 153, 0.32) !important;
    color: var(--tachyon-monitoring-net-udp-fg) !important;
}

.tachyon_monitoring-page__network--quic {
    background: rgba(99, 102, 241, 0.16) !important;
    border-color: rgba(129, 140, 248, 0.38) !important;
    color: var(--tachyon-monitoring-net-quic-fg) !important;
}

.tachyon_monitoring-page__table td:nth-child(4) .tachyon_monitoring-page__value,
.tachyon_monitoring-page__table td:nth-child(5) .tachyon_monitoring-page__value,
.tachyon_monitoring-page__table td:nth-child(6) .tachyon_monitoring-page__value {
    color: var(--tachyon-monitoring-text-secondary);
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 12px;
    text-align: right;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__row-action {
    width: var(--tachyon-monitoring-row-action-size);
    height: var(--tachyon-monitoring-row-action-size);
    min-width: var(--tachyon-monitoring-row-action-size);
    min-height: var(--tachyon-monitoring-row-action-size);
    padding: 0;
    box-sizing: border-box;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    margin: 0;
    border: 0 !important;
    border-radius: 999px;
    background: transparent !important;
    color: var(--tachyon-monitoring-danger-color) !important;
    box-shadow: none;
    cursor: pointer;
}

.tachyon_monitoring-page__row-action svg {
    width: 14px;
    height: 14px;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__row-action:hover:not(:disabled) {
    background: var(--tachyon-monitoring-soft-bg-hover) !important;
    color: var(--tachyon-monitoring-danger-color) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__row-action:disabled {
    opacity: 0.45;
    cursor: wait;
}

.tachyon_monitoring-page__row--closing {
    opacity: 0.55;
}

.tachyon_monitoring-page__state {
    min-height: 130px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--tachyon-text-muted, #94a3b8);
    font-size: 13px;
    font-weight: 500;
    text-align: center;
    box-sizing: border-box;
}

.tachyon_monitoring-page__state-cell {
    padding: 0 !important;
}

.tachyon_monitoring-page__state--error {
    color: var(--error-color-medium, #d32f2f);
}

@media (max-width: 900px) {
    .tachyon_monitoring-page__controls {
        align-items: center;
    }

    .tachyon_monitoring-page__tabs {
        flex: 1 0 100%;
    }

    .tachyon_monitoring-page__filters {
        flex: 1 1 0;
    }

    .tachyon_monitoring-page__device-filter,
    .tachyon_monitoring-page__search {
        max-width: none;
    }

    .tachyon_monitoring-page__table {
        min-width: 0;
    }

    .tachyon_monitoring-page__table thead {
        display: none;
    }

    .tachyon_monitoring-page__table,
    .tachyon_monitoring-page__table tbody,
    .tachyon_monitoring-page__table tr,
    .tachyon_monitoring-page__table td {
        display: block;
        width: 100%;
    }

    .tachyon_monitoring-page__table tr {
        border: 1px var(--background-color-low, lightgray) solid;
        border-radius: 4px;
        padding: 8px;
        box-sizing: border-box;
        margin-bottom: 8px;
    }

    .tachyon_monitoring-page__table td {
        display: grid;
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        gap: 8px;
        border: 0;
        border-bottom: 1px solid var(--tachyon-monitoring-divider-color);
        padding: 4px 0;
        box-sizing: border-box;
        text-align: left;
    }

    .tachyon_monitoring-page__table td::before {
        content: attr(data-label);
        color: var(--text-color-medium);
        font-weight: 700;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .tachyon_monitoring-page__table td:last-child {
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        align-items: center;
        border-bottom: 0;
        min-height: var(--tachyon-monitoring-row-action-size);
        padding: 0;
    }

    .tachyon_monitoring-page__value {
        text-align: right;
    }

    .tachyon_monitoring-page__source-value {
        justify-content: flex-end;
    }

    .tachyon_monitoring-page__state-row td::before {
        display: none;
    }
}

@media (max-width: 520px) {
    .tachyon_monitoring-page__controls,
    .tachyon_monitoring-page__filters {
        align-items: stretch;
    }

    .tachyon_monitoring-page__tabs,
    .tachyon_monitoring-page__filters,
    .tachyon_monitoring-page__device-filter,
    .tachyon_monitoring-page__search {
        width: 100%;
    }

    .tachyon_monitoring-page__controls,
    .tachyon_monitoring-page__filters {
        flex-direction: column;
    }

    .tachyon_monitoring-page__actions {
        align-self: flex-end;
    }

    .tachyon_monitoring-page__tabs {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        width: 100%;
    }

    .tachyon_monitoring-page__table td {
        grid-template-columns: 1fr;
        gap: 2px;
    }

    .tachyon_monitoring-page__value {
        text-align: left;
    }

    .tachyon_monitoring-page__source-value {
        justify-content: flex-start;
    }
}
`;
