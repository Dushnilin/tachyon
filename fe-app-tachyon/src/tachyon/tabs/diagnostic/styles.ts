// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `

#cbi-${TACHYON_CBI_PREFIX}-diagnostic {
    width: 100% !important;
    max-width: none !important;
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    box-shadow: none !important;
    box-sizing: border-box !important;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic > .cbi-section-node,
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node {
    display: block !important;
    width: 100% !important;
    max-width: none !important;
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    background: transparent !important;
    box-shadow: none !important;
    box-sizing: border-box !important;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-title {
    display: none !important;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > output,
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-field,
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-field > output,
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-field > div,
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > div {
    display: block !important;
    margin: 0 !important;
    padding: 0 !important;
    width: 100% !important;
    max-width: none !important;
    flex: 1 1 100% !important;
    box-sizing: border-box !important;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic > h3 {
    display: none !important;
}

.tachyon_diagnostic-root {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 100%;
    max-width: none;
    min-width: 0;
    box-sizing: border-box;
}

.tachyon_diagnostic-system-strip,
.tachyon_diagnostic-core-telemetry-mount {
    width: 100%;
    max-width: none;
    min-width: 0;
    box-sizing: border-box;
}

/* GPUI-Kit System Node Telemetry Strip (1px Divided Instrument Matrix) */
.tachyon_diagnostic-page__right-bar__system-info {
    padding: 0;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    width: 100%;
    box-sizing: border-box;
}

.tachyon_diagnostic-page__right-bar__system-info__title {
    padding: 7px 12px;
    min-height: 32px;
    background: var(--hover);
    border-bottom: 1px solid var(--border);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: var(--text);
    margin: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    box-sizing: border-box;
}

.tachyon_diagnostic-sys-head-left {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon_diagnostic-sys-head-left svg {
    color: var(--text3);
}

.tachyon_diagnostic-sys-head-code {
    font-family: var(--mono);
    font-size: 10px;
    font-weight: 500;
    letter-spacing: 0.05em;
    color: var(--text3);
}

.tachyon_diagnostic-sys-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
    gap: 1px;
    background: var(--border);
    width: 100%;
    box-sizing: border-box;
}

.tachyon_diagnostic-page__right-bar__system-info__row {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 5px;
    padding: 9px 12px;
    border-radius: 0;
    background: var(--surface);
    border: none;
    min-width: 0;
}

.tachyon_diagnostic-page__right-bar__system-info__row > b {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: var(--text3);
}

.tachyon_diagnostic-page__right-bar__system-info__row > div {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    flex-wrap: wrap;
    font-family: var(--mono);
    font-size: 12px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--text);
    word-break: break-word;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress {
    width: 100%;
    height: 2px;
    border-radius: 1px;
    background: var(--border);
    overflow: hidden;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill {
    display: block;
    height: 100%;
    border-radius: 1px;
    background: var(--accent);
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-success {
    background: var(--success);
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-warning {
    background: var(--warn);
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-danger {
    background: var(--danger);
}

.tachyon_diagnostic-page__right-bar__system-info__row__sub {
    font-family: var(--mono);
    font-size: 10px;
    font-weight: 500;
    font-variant-numeric: tabular-nums;
    color: var(--text3);
    line-height: 1.3;
    word-break: break-word;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag {
    display: none;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--neutral,
.tachyon_diagnostic-page__right-bar__system-info__row__tag--warning,
.tachyon_diagnostic-page__right-bar__system-info__row__tag--success {
    display: inline-flex;
    align-items: center;
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--mono);
    font-size: 9.5px;
    font-weight: 600;
    line-height: 1.3;
    border: 1px solid transparent;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--neutral {
    background: var(--hover);
    border-color: var(--border);
    color: var(--text2);
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--warning {
    background: var(--warn-soft);
    border-color: var(--warn-border);
    color: var(--warn);
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--success {
    background: var(--success-soft);
    border-color: var(--success-border);
    color: var(--success);
}

/* GPUI-Kit 3-Pane Tachyon-Core Deep Telemetry Workbench */
.tachyon_diag-telemetry {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 10px;
    width: 100%;
    box-sizing: border-box;
    align-items: stretch;
}

.tachyon_diag-telemetry__card {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    padding: 12px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    min-width: 0;
    box-sizing: border-box;
}

.tachyon_diag-telemetry__card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin: -12px -12px 2px -12px;
    padding: 8px 12px;
    background: var(--hover);
    border-bottom: 1px solid var(--border);
}

.tachyon_diag-telemetry__title-group {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
}

.tachyon_diag-telemetry__title-icon {
    width: 14px;
    height: 14px;
    color: var(--text3);
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
}

.tachyon_diag-telemetry__title {
    margin: 0;
    font-size: 11.5px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.25;
}

.tachyon_diag-telemetry__subtitle {
    display: none;
}

.tachyon_diag-telemetry__rate-pills {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
}

.tachyon_diag-telemetry__rate-pill {
    display: inline-flex;
    align-items: center;
    padding: 2px 7px;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    border: 1px solid var(--border);
    background: var(--bg);
}

.tachyon_diag-telemetry__rate-pill.is-down {
    color: var(--accent-text);
    border-color: var(--accent-ring);
    background: var(--accent-soft);
}

.tachyon_diag-telemetry__rate-pill.is-up {
    color: var(--success);
    border-color: var(--success-border);
    background: var(--success-soft);
}

.tachyon_diag-telemetry__status-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 7px;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: 10.5px;
    font-weight: 600;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon_diag-telemetry__status-badge.is-ok {
    color: var(--success);
    background: var(--success-soft);
    border: 1px solid var(--success-border);
}

.tachyon_diag-telemetry__status-badge.is-warn {
    color: var(--warn);
    background: var(--warn-soft);
    border: 1px solid var(--warn-border);
}

.tachyon_diag-telemetry__sparkline-wrap {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 6px 8px;
    border-radius: 6px;
    background: var(--bg);
    border: 1px solid var(--border);
}

.tachyon_diag-telemetry__sparkline {
    width: 100%;
    height: 92px;
    display: block;
}

.tachyon_diag-telemetry__sparkline-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-family: var(--mono);
    font-size: 10px;
    color: var(--text3);
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__kpi-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 6px;
}

.tachyon_diag-telemetry__kpi {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 6px 8px;
    border-radius: 6px;
    background: var(--bg);
    border: 1px solid var(--border);
    min-width: 0;
}

.tachyon_diag-telemetry__kpi-label {
    font-size: 10px;
    color: var(--text3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon_diag-telemetry__kpi-val {
    font-family: var(--mono);
    font-size: 12px;
    font-weight: 600;
    color: var(--text);
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__split-box {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding-top: 4px;
}

.tachyon_diag-telemetry__split-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-family: var(--mono);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__split-tag.is-proxied {
    color: var(--accent-text);
}

.tachyon_diag-telemetry__split-tag.is-direct {
    color: var(--text2);
}

.tachyon_diag-telemetry__split-bar {
    display: flex;
    width: 100%;
    height: 6px;
    border-radius: 3px;
    overflow: hidden;
    background: var(--border);
}

.tachyon_diag-telemetry__split-seg.is-proxied {
    background: var(--accent);
}

.tachyon_diag-telemetry__split-seg.is-direct {
    background: var(--text3);
}

.tachyon_diag-telemetry__proto-row {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
}

.tachyon_diag-telemetry__proto-chip {
    padding: 1px 6px;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: 10px;
    color: var(--text2);
    background: var(--bg);
    border: 1px solid var(--border);
}

.tachyon_diag-telemetry__mem-strip {
    display: flex;
    flex-direction: column;
    gap: 5px;
}

.tachyon_diag-telemetry__mem-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--text2);
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__progress-track {
    width: 100%;
    height: 5px;
    border-radius: 3px;
    background: var(--border);
    overflow: hidden;
}

.tachyon_diag-telemetry__progress-fill {
    display: block;
    height: 100%;
    border-radius: 3px;
}

.tachyon_diag-telemetry__progress-fill.is-accent {
    background: var(--accent);
}

.tachyon_diag-telemetry__progress-fill.is-warn {
    background: var(--warn);
}

.tachyon_diag-telemetry__progress-fill.is-danger {
    background: var(--danger);
}

.tachyon_diag-telemetry__section-caption {
    font-size: 10.5px;
    font-weight: 600;
    color: var(--text2);
}

.tachyon_diag-telemetry__outbounds {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon_diag-telemetry__outbound-list {
    display: flex;
    flex-direction: column;
    gap: 5px;
}

.tachyon_diag-telemetry__outbound-row {
    display: flex;
    flex-direction: column;
    gap: 3px;
}

.tachyon_diag-telemetry__outbound-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-family: var(--mono);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__outbound-tag {
    color: var(--text);
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__outbound-stats {
    color: var(--text3);
    flex-shrink: 0;
}

.tachyon_diag-telemetry__outbound-bar {
    width: 100%;
    height: 4px;
    border-radius: 2px;
    background: var(--border);
    overflow: hidden;
}

.tachyon_diag-telemetry__outbound-fill {
    display: block;
    height: 100%;
    border-radius: 2px;
    background: var(--accent);
}

.tachyon_diag-telemetry__card-actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
    padding-top: 4px;
}

.tachyon_diag-telemetry__action-btn {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 6px !important;
    height: 30px !important;
    min-height: 30px !important;
    padding: 0 10px !important;
    font-size: 11.5px !important;
    font-weight: 600 !important;
    border-radius: 6px !important;
    background: var(--hover) !important;
    border: 1px solid var(--border-strong) !important;
    color: var(--text) !important;
    cursor: pointer;
}

.tachyon_diag-telemetry__action-btn:hover {
    background: var(--elevated) !important;
    border-color: var(--accent-ring) !important;
}

.tachyon_diag-telemetry__btn-icon {
    width: 13px;
    height: 13px;
    display: inline-flex;
}

.tachyon_diag-telemetry__leak-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
}

.tachyon_diag-telemetry__leak-chip {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    padding: 5px 8px;
    border-radius: 6px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-left: 2px solid var(--success);
}

.tachyon_diag-telemetry__leak-chip.is-warn {
    border-left-color: var(--warn);
}

.tachyon_diag-telemetry__leak-name {
    font-size: 10.5px;
    color: var(--text2);
}

.tachyon_diag-telemetry__leak-val {
    font-family: var(--mono);
    font-size: 10.5px;
    font-weight: 600;
    color: var(--text);
}

.tachyon_diag-telemetry__subhead {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.tachyon_diag-telemetry__mini-btn {
    height: 22px !important;
    min-height: 22px !important;
    padding: 0 8px !important;
    font-size: 10.5px !important;
    font-weight: 600 !important;
    border-radius: 4px !important;
    background: var(--hover) !important;
    border: 1px solid var(--border-strong) !important;
    color: var(--text2) !important;
    cursor: pointer;
}

.tachyon_diag-telemetry__mini-btn:hover {
    background: var(--elevated) !important;
    color: var(--text) !important;
}

.tachyon_diag-telemetry__failover-box,
.tachyon_diag-telemetry__flight-box {
    display: flex;
    flex-direction: column;
    gap: 5px;
}

.tachyon_diag-telemetry__failover-list,
.tachyon_diag-telemetry__flight-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    max-height: 118px;
    overflow-y: auto;
}

.tachyon_diag-telemetry__failover-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 4px 8px;
    border-radius: 5px;
    background: var(--bg);
    border: 1px solid var(--border);
    font-size: 11px;
}

.tachyon_diag-telemetry__failover-main {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    overflow: hidden;
}

.tachyon_diag-telemetry__failover-tag {
    color: var(--text);
    font-size: 11px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__failover-node {
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--text3);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__failover-badges {
    display: flex;
    align-items: center;
    gap: 5px;
    flex-shrink: 0;
}

.tachyon_diag-telemetry__rtt-pill {
    font-family: var(--mono);
    font-size: 10px;
    color: var(--text2);
}

.tachyon_diag-telemetry__backup-pill {
    padding: 1px 5px;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: 9.5px;
    font-weight: 600;
}

.tachyon_diag-telemetry__backup-pill.is-ok {
    color: var(--success);
    background: var(--success-soft);
}

.tachyon_diag-telemetry__backup-pill.is-warn {
    color: var(--warn);
    background: var(--warn-soft);
}

.tachyon_diag-telemetry__flight-row {
    display: grid;
    grid-template-columns: 32px 34px minmax(0, 1fr) auto auto;
    align-items: center;
    gap: 6px;
    padding: 3px 6px;
    border-radius: 4px;
    background: var(--bg);
    border: 1px solid var(--border);
    font-family: var(--mono);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__flight-pill {
    text-align: center;
    padding: 1px 4px;
    border-radius: 3px;
    font-size: 9.5px;
    font-weight: 600;
}

.tachyon_diag-telemetry__flight-pill.is-ok {
    color: var(--success);
    background: var(--success-soft);
}

.tachyon_diag-telemetry__flight-pill.is-warn {
    color: var(--warn);
    background: var(--warn-soft);
}

.tachyon_diag-telemetry__flight-pill.is-danger {
    color: var(--danger);
    background: var(--danger-soft);
}

.tachyon_diag-telemetry__flight-net {
    color: var(--text3);
    font-size: 10px;
}

.tachyon_diag-telemetry__flight-host {
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__flight-out {
    color: var(--accent-text);
    font-size: 10px;
    max-width: 16ch;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__flight-dur {
    color: var(--text3);
    font-size: 10px;
    text-align: right;
}

.tachyon_diag-telemetry__empty {
    font-size: 11px;
    color: var(--text3);
    padding: 6px 0;
}

/* Main 2-Pane GPUI-Kit Desktop Workspace */
.tachyon_diagnostic-page {
    display: grid;
    grid-template-columns: minmax(0, 1.08fr) minmax(0, 1fr);
    gap: 10px;
    align-items: start;
    width: 100%;
    box-sizing: border-box;
}

.tachyon_diagnostic-page__left-bar {
    display: flex;
    flex-direction: column;
    gap: 0;
    padding: 0;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    min-width: 0;
    overflow: hidden;
    box-sizing: border-box;
}

.tachyon_diagnostic-page__left-bar__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
    min-height: 38px;
    padding: 6px 12px;
    background: var(--hover);
    border-bottom: 1px solid var(--border);
}

.tachyon_diagnostic-page__left-bar__header-titles {
    display: flex;
    align-items: baseline;
    gap: 10px;
    flex-wrap: wrap;
    min-width: 0;
}

.tachyon_diagnostic-page__left-bar__title {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.25;
}

.tachyon_diagnostic-page__left-bar__title svg {
    color: var(--text3);
    flex-shrink: 0;
}

.tachyon_diagnostic-page__left-bar__subtitle {
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--text3);
    line-height: 1.25;
}

.tachyon_diagnostic-page__checks {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px 12px 12px;
}

.tachyon_diagnostic-page__checks-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
    align-items: start;
}

/* GPUI-Kit Summary Banner (Flat instrument bar, zero full-box tint, zero left-border callout) */
.tachyon_diagnostic-summary-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 12px;
    border-radius: 4px;
    border: 1px solid var(--border);
    background: var(--hover);
}

.tachyon_diagnostic-summary-banner--loading {
    border-color: var(--accent-ring);
}

.tachyon_diagnostic-summary-banner--loading .tachyon_diagnostic-summary-banner__title svg {
    color: var(--accent);
}

.tachyon_diagnostic-summary-banner--success {
    border-color: var(--success-border);
}

.tachyon_diagnostic-summary-banner--success .tachyon_diagnostic-summary-banner__title svg {
    color: var(--success);
}

.tachyon_diagnostic-summary-banner--warning {
    border-color: var(--warn-border);
}

.tachyon_diagnostic-summary-banner--warning .tachyon_diagnostic-summary-banner__title svg {
    color: var(--warn);
}

.tachyon_diagnostic-summary-banner--error {
    border-color: var(--danger-border);
}

.tachyon_diagnostic-summary-banner--error .tachyon_diagnostic-summary-banner__title svg {
    color: var(--danger);
}

.tachyon_diagnostic-summary-banner__main {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
}

.tachyon_diagnostic-summary-banner__title {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.25;
}

.tachyon_diagnostic-summary-banner__title svg,
.tachyon_diagnostic-summary-banner__title > svg {
    width: 18px;
    height: 18px;
    flex-shrink: 0;
}

.tachyon_diagnostic-summary-banner__title > svg {
    width: 18px;
    height: 18px;
    flex-shrink: 0;
}

.tachyon_diagnostic-summary-banner__subtitle {
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--text2);
    font-variant-numeric: tabular-nums;
}

.tachyon_diagnostic-page__run_check_wrapper {
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.tachyon_diagnostic-page__run_check_wrapper button {
    width: auto;
    min-width: 148px;
    height: 28px !important;
    min-height: 28px !important;
    padding: 0 10px !important;
    font-size: 11.5px !important;
    font-weight: 600;
    border-radius: 4px !important;
}

/* Right Operations Dock */
.tachyon_diagnostic-page__right-bar {
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: 0;
}

.tachyon_diagnostic-page__right-bar__actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    align-items: stretch;
}

.tachyon_diagnostic-action-group {
    display: flex;
    flex-direction: column;
    gap: 0;
    padding: 0;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    overflow: hidden;
}

.tachyon_diagnostic-action-group__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-height: 34px;
    padding: 5px 11px;
    background: var(--hover);
    border-bottom: 1px solid var(--border);
}

.tachyon_diagnostic-action-group__title {
    font-size: 12px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.25;
}

.tachyon_diagnostic-action-group__subtitle {
    font-family: var(--mono);
    font-size: 9.5px;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: var(--text3);
    white-space: nowrap;
}

.tachyon_diagnostic-action-group__grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
    padding: 9px 10px;
}

.tachyon_diagnostic-action-group__grid > .tachyon-partial-button,
.tachyon_diagnostic-action-group__grid button.btn,
.tachyon_diagnostic-action-group__grid button.cbi-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: flex-start;
    gap: 6px;
    text-align: left;
    padding: 6px 9px !important;
    min-height: 32px;
    height: auto !important;
    font-size: 11.5px;
    font-weight: 500;
    line-height: 1.25 !important;
    white-space: normal !important;
    border-radius: 4px !important;
    box-sizing: border-box !important;
}

/* GPUI-Kit Documentation & Links Dock Module */
.tachyon_diagnostic-page__right-bar__wiki {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 6px;
    padding: 0 10px 8px 10px;
    border-radius: 4px;
    border: 1px solid var(--border);
    background: var(--surface);
    overflow: hidden;
}

.tachyon_diagnostic-page__right-bar__wiki__content {
    grid-column: 1 / -1;
    margin: 0 -10px 2px -10px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    min-height: 32px;
    padding: 4px 11px;
    background: var(--hover);
    border-bottom: 1px solid var(--border);
}

.tachyon_diagnostic-page__right-bar__wiki__texts {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
}

.tachyon_diagnostic-page__right-bar__wiki__icon {
    width: 16px;
    height: 16px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--text3);
    flex-shrink: 0;
}

.tachyon_diagnostic-page__right-bar__wiki__icon svg {
    width: 14px;
    height: 14px;
}

.tachyon_diagnostic-page__right-bar__wiki__texts b {
    font-size: 12px;
    font-weight: 600;
    color: var(--text);
}

.tachyon_diagnostic-page__right-bar__wiki__meta {
    font-family: var(--mono);
    font-size: 9.5px;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: var(--text3);
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon-partial-button,
.tachyon_diagnostic-page__right-bar__wiki > button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 6px;
    padding: 5px 8px !important;
    min-height: 30px;
    height: auto !important;
    font-size: 11.5px;
    font-weight: 500;
    border-radius: 4px !important;
    border: 1px solid var(--border) !important;
    background: var(--hover) !important;
    color: var(--text2) !important;
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon-partial-button:hover,
.tachyon_diagnostic-page__right-bar__wiki > button:hover {
    border-color: var(--border-strong) !important;
    background: var(--elevated) !important;
    color: var(--text) !important;
}

/* GPUI-Kit Subsystem Inspector Cards (Flat surface, zero full-box tint, zero left-border callout) */
.tachyon_diagnostic_alert {
    padding: 9px 11px;
    border: 1px solid var(--border);
    border-radius: 4px;
    background: var(--surface);
    display: grid;
    grid-template-columns: 22px minmax(0, 1fr);
    gap: 7px 9px;
    align-content: start;
    transition: border-color 0.12s ease, background-color 0.12s ease;
}

.tachyon_diagnostic_alert:hover {
    border-color: var(--border-strong);
    background: var(--hover);
}

.tachyon_diagnostic_alert__icon {
    width: 22px;
    height: 22px;
    border-radius: 4px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--hover);
    border: 1px solid var(--border);
    color: var(--text2);
}

.tachyon_diagnostic_alert__icon svg {
    width: 13px;
    height: 13px;
}

.tachyon_diagnostic_alert__content {
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 3px;
    min-width: 0;
}

.tachyon_diagnostic_alert__title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
    font-size: 12px;
    font-weight: 600;
    color: var(--text);
    line-height: 1.25;
}

.tachyon_diagnostic_alert__counts-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 3px;
    font-family: var(--mono);
    font-size: 10px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    background: var(--hover);
    border: 1px solid var(--border);
    color: var(--text2);
}

.tachyon_diagnostic_alert__counts-badge--success {
    border-color: var(--success-border);
    color: var(--success);
}

.tachyon_diagnostic_alert__counts-badge--warning {
    border-color: var(--warn-border);
    color: var(--warn);
}

.tachyon_diagnostic_alert__counts-badge--error {
    border-color: var(--danger-border);
    color: var(--danger);
}

.tachyon_diagnostic_alert__description {
    font-size: 11px;
    font-weight: 400;
    color: var(--text2);
    line-height: 1.3;
}

/* Inline GPUI Monospace Preview Chips */
.tachyon_diagnostic_alert__preview {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 2px;
}

.tachyon_diagnostic_alert--expanded .tachyon_diagnostic_alert__preview {
    display: none;
}

.tachyon_diagnostic_alert__preview-chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    max-width: 100%;
    padding: 1px 5px;
    border-radius: 3px;
    background: var(--bg);
    border: 1px solid var(--border);
    font-family: var(--mono);
    font-size: 10px;
    line-height: 1.3;
}

.tachyon_diagnostic_alert__preview-chip--error {
    border-color: var(--danger-border);
}

.tachyon_diagnostic_alert__preview-chip--warning {
    border-color: var(--warn-border);
}

.tachyon_diagnostic_alert__preview-chip--info {
    border-color: var(--border-strong);
}

.tachyon_diagnostic_alert__preview-dot {
    width: 5px;
    height: 5px;
    border-radius: 999px;
    flex-shrink: 0;
    background: var(--success);
}

.tachyon_diagnostic_alert__preview-dot--warning {
    background: var(--warn);
}

.tachyon_diagnostic_alert__preview-dot--error {
    background: var(--danger);
}

.tachyon_diagnostic_alert__preview-dot--info {
    background: var(--text3);
}

.tachyon_diagnostic_alert__preview-key {
    color: var(--text2);
    white-space: nowrap;
}

.tachyon_diagnostic_alert__preview-val {
    color: var(--text);
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 170px;
}

.tachyon_diagnostic_alert--collapsible {
    cursor: pointer;
    user-select: none;
}

.tachyon_diagnostic_alert__toggle-hint {
    font-size: 10.5px;
    font-weight: 500;
    color: var(--text3);
    margin-top: 2px;
}

.tachyon_diagnostic_alert:hover .tachyon_diagnostic_alert__toggle-hint {
    color: var(--text);
}

.tachyon_diagnostic_alert__summary {
    grid-column: 1 / -1;
    display: none;
    flex-direction: column;
    gap: 1px;
    margin-top: 4px;
    border-radius: 4px;
    overflow: hidden;
    border: 1px solid var(--border);
    background: var(--border);
}

.tachyon_diagnostic_alert__summary--expanded {
    display: flex;
    max-height: 260px;
    overflow-y: auto;
}

.tachyon_diagnostic_alert__summary:empty {
    display: none;
    border: none;
}

.tachyon_diagnostic_alert__summary__item {
    display: grid;
    grid-template-columns: 16px minmax(0, 1fr) auto;
    gap: 8px;
    align-items: center;
    font-size: 11px;
    padding: 5px 9px;
    background: var(--bg);
}

.tachyon_diagnostic_alert__summary__item b {
    font-weight: 500;
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon_diagnostic_alert__summary__item > div {
    font-family: var(--mono);
    font-size: 10.5px;
    font-weight: 600;
    color: var(--text2);
    text-align: right;
    font-variant-numeric: tabular-nums;
}

.tachyon_diagnostic_alert__summary__item__icon {
    width: 14px;
    height: 14px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon_diagnostic_alert__summary__item__icon svg {
    width: 13px;
    height: 13px;
}

.tachyon_diagnostic_alert__summary__item--error {
    color: var(--danger);
}

.tachyon_diagnostic_alert__summary__item--error b {
    color: var(--danger);
}

.tachyon_diagnostic_alert__summary__item--error > div {
    color: var(--danger);
}

.tachyon_diagnostic_alert__summary__item--warning {
    color: var(--warn);
}

.tachyon_diagnostic_alert__summary__item--warning > div {
    color: var(--warn);
}

.tachyon_diagnostic_alert__summary__item--success {
    color: var(--success);
}

.tachyon_diagnostic_alert__summary__item--info {
    color: var(--text2);
}

.tachyon_diagnostic_alert__summary__item--info > div {
    color: var(--text2);
}

.tachyon_diagnostic_alert--loading {
    border-color: var(--accent-ring);
}

.tachyon_diagnostic_alert--loading .tachyon_diagnostic_alert__icon {
    color: var(--accent);
    border-color: var(--accent-ring);
}

.tachyon_diagnostic_alert--warning {
    border-color: var(--warn-border);
}

.tachyon_diagnostic_alert--warning .tachyon_diagnostic_alert__icon {
    color: var(--warn);
    border-color: var(--warn-border);
}

.tachyon_diagnostic_alert--error {
    border-color: var(--danger-border);
}

.tachyon_diagnostic_alert--error .tachyon_diagnostic_alert__icon {
    color: var(--danger);
    border-color: var(--danger-border);
}

.tachyon_diagnostic_alert--success {
    border-color: var(--border);
}

.tachyon_diagnostic_alert--success .tachyon_diagnostic_alert__icon {
    color: var(--success);
    border-color: var(--success-border);
}

.tachyon_diagnostic_alert--skipped {
    border-color: var(--border);
    opacity: 0.72;
}

/* GPUI-Kit Diagnostics Modal */
.modal:has(.tachyon_diagnostic-modal) {
    width: min(1020px, 95vw) !important;
    max-width: min(1020px, 95vw) !important;
}

.tachyon_diagnostic-modal {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    overflow-x: hidden;
    box-sizing: border-box;
}

.tachyon_diagnostic-modal__toolbar {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    flex-shrink: 0;
}

.tachyon_diagnostic-modal__toolbar button {
    height: 28px !important;
    min-height: 28px !important;
    padding: 0 9px !important;
    font-size: 11.5px !important;
    border-radius: 4px !important;
    white-space: nowrap !important;
}

.tachyon_diagnostic-modal__progress-track {
    width: 100%;
    height: 3px;
    border-radius: 2px;
    background: var(--border);
    overflow: hidden;
}

.tachyon_diagnostic-modal__progress-bar {
    height: 100%;
    border-radius: 2px;
    background: var(--accent);
    transition: width 0.2s ease;
}

.tachyon_diagnostic-modal__checks-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
    max-height: 65vh;
    overflow-y: auto;
    overflow-x: hidden;
    padding-right: 2px;
}

.tachyon_diagnostic-modal__footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--border);
}

@media (max-width: 1200px) {
    .tachyon_diag-telemetry {
        grid-template-columns: 1fr;
    }
    .tachyon_diagnostic-page {
        grid-template-columns: 1fr;
    }
}

@media (max-width: 820px) {
    .tachyon_diagnostic-page__checks-grid,
    .tachyon_diagnostic-modal__checks-grid,
    .tachyon_diagnostic-page__right-bar__actions {
        grid-template-columns: 1fr;
    }
    .tachyon_diagnostic-summary-banner {
        flex-direction: column;
        align-items: stretch;
    }
}

@media (max-width: 640px) {
    .tachyon_diagnostic-page__right-bar__wiki {
        grid-template-columns: 1fr;
    }
    .tachyon_diag-telemetry__kpi-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .tachyon_diagnostic-page__left-bar__header {
        flex-direction: column;
        align-items: stretch;
    }
    .tachyon_diagnostic-page__run_check_wrapper button {
        width: 100%;
    }
}
`;
