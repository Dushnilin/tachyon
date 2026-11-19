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
    background: #111114;
    border: 1px solid rgba(255, 255, 255, 0.08);
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
    background: #16161a;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: #d4d4d8;
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
    color: #71717a;
}

.tachyon_diagnostic-sys-head-code {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    font-weight: 500;
    letter-spacing: 0.05em;
    color: #71717a;
}

.tachyon_diagnostic-sys-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
    gap: 1px;
    background: rgba(255, 255, 255, 0.06);
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
    background: #111114;
    border: none;
    min-width: 0;
}

.tachyon_diagnostic-page__right-bar__system-info__row > b {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: #71717a;
}

.tachyon_diagnostic-page__right-bar__system-info__row > div {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    flex-wrap: wrap;
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 12px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: #f4f4f5;
    word-break: break-word;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress {
    width: 100%;
    height: 2px;
    border-radius: 1px;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill {
    display: block;
    height: 100%;
    border-radius: 1px;
    background: #3b82f6;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-success {
    background: #22c55e;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-warning {
    background: #f59e0b;
}

.tachyon_diagnostic-page__right-bar__system-info__row__progress-fill.is-danger {
    background: #ef4444;
}

.tachyon_diagnostic-page__right-bar__system-info__row__sub {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    font-weight: 500;
    font-variant-numeric: tabular-nums;
    color: #71717a;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 9.5px;
    font-weight: 600;
    line-height: 1.3;
    border: 1px solid transparent;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--neutral {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.1);
    color: #a1a1aa;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--warning {
    background: rgba(245, 158, 11, 0.1);
    border-color: rgba(245, 158, 11, 0.25);
    color: #fbbf24;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--success {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.25);
    color: #4ade80;
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
    background: #111114;
    border: 1px solid rgba(255, 255, 255, 0.08);
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
    background: #16161a;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
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
    color: #71717a;
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
}

.tachyon_diag-telemetry__title {
    margin: 0;
    font-size: 11.5px;
    font-weight: 600;
    color: #e4e4e7;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 11px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.03);
}

.tachyon_diag-telemetry__rate-pill.is-down {
    color: #38bdf8;
    border-color: rgba(56, 189, 248, 0.25);
    background: rgba(56, 189, 248, 0.08);
}

.tachyon_diag-telemetry__rate-pill.is-up {
    color: #4ade80;
    border-color: rgba(74, 222, 128, 0.25);
    background: rgba(74, 222, 128, 0.08);
}

.tachyon_diag-telemetry__status-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 7px;
    border-radius: 4px;
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    font-weight: 600;
    white-space: nowrap;
    flex-shrink: 0;
}

.tachyon_diag-telemetry__status-badge.is-ok {
    color: #4ade80;
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.26);
}

.tachyon_diag-telemetry__status-badge.is-warn {
    color: #fbbf24;
    background: rgba(245, 158, 11, 0.12);
    border: 1px solid rgba(245, 158, 11, 0.28);
}

.tachyon_diag-telemetry__sparkline-wrap {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 6px 8px;
    border-radius: 6px;
    background: #0b0b0e;
    border: 1px solid rgba(255, 255, 255, 0.06);
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    color: #71717a;
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
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.06);
    min-width: 0;
}

.tachyon_diag-telemetry__kpi-label {
    font-size: 10px;
    color: #71717a;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon_diag-telemetry__kpi-val {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 12px;
    font-weight: 600;
    color: #f4f4f5;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__split-tag.is-proxied {
    color: #38bdf8;
}

.tachyon_diag-telemetry__split-tag.is-direct {
    color: #a1a1aa;
}

.tachyon_diag-telemetry__split-bar {
    display: flex;
    width: 100%;
    height: 6px;
    border-radius: 3px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.08);
}

.tachyon_diag-telemetry__split-seg.is-proxied {
    background: #0a84ff;
}

.tachyon_diag-telemetry__split-seg.is-direct {
    background: #52525b;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    color: #a1a1aa;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.07);
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    color: #a1a1aa;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__progress-track {
    width: 100%;
    height: 5px;
    border-radius: 3px;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
}

.tachyon_diag-telemetry__progress-fill {
    display: block;
    height: 100%;
    border-radius: 3px;
}

.tachyon_diag-telemetry__progress-fill.is-accent {
    background: #0a84ff;
}

.tachyon_diag-telemetry__progress-fill.is-warn {
    background: #f59e0b;
}

.tachyon_diag-telemetry__progress-fill.is-danger {
    background: #ef4444;
}

.tachyon_diag-telemetry__section-caption {
    font-size: 10.5px;
    font-weight: 600;
    color: #a1a1aa;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
}

.tachyon_diag-telemetry__outbound-tag {
    color: #e4e4e7;
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__outbound-stats {
    color: #71717a;
    flex-shrink: 0;
}

.tachyon_diag-telemetry__outbound-bar {
    width: 100%;
    height: 4px;
    border-radius: 2px;
    background: rgba(255, 255, 255, 0.06);
    overflow: hidden;
}

.tachyon_diag-telemetry__outbound-fill {
    display: block;
    height: 100%;
    border-radius: 2px;
    background: #3b82f6;
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
    background: rgba(255, 255, 255, 0.04) !important;
    border: 1px solid rgba(255, 255, 255, 0.1) !important;
    color: #e4e4e7 !important;
    cursor: pointer;
}

.tachyon_diag-telemetry__action-btn:hover {
    background: rgba(255, 255, 255, 0.08) !important;
    border-color: rgba(255, 255, 255, 0.18) !important;
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
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-left: 2px solid #22c55e;
}

.tachyon_diag-telemetry__leak-chip.is-warn {
    border-left-color: #f59e0b;
}

.tachyon_diag-telemetry__leak-name {
    font-size: 10.5px;
    color: #a1a1aa;
}

.tachyon_diag-telemetry__leak-val {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    font-weight: 600;
    color: #e4e4e7;
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
    background: rgba(255, 255, 255, 0.04) !important;
    border: 1px solid rgba(255, 255, 255, 0.1) !important;
    color: #d4d4d8 !important;
    cursor: pointer;
}

.tachyon_diag-telemetry__mini-btn:hover {
    background: rgba(255, 255, 255, 0.09) !important;
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
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
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
    color: #e4e4e7;
    font-size: 11px;
    white-space: nowrap;
}

.tachyon_diag-telemetry__failover-node {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    color: #71717a;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    color: #a1a1aa;
}

.tachyon_diag-telemetry__backup-pill {
    padding: 1px 5px;
    border-radius: 4px;
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 9.5px;
    font-weight: 600;
}

.tachyon_diag-telemetry__backup-pill.is-ok {
    color: #4ade80;
    background: rgba(34, 197, 94, 0.1);
}

.tachyon_diag-telemetry__backup-pill.is-warn {
    color: #fbbf24;
    background: rgba(245, 158, 11, 0.14);
}

.tachyon_diag-telemetry__flight-row {
    display: grid;
    grid-template-columns: 32px 34px minmax(0, 1fr) auto auto;
    align-items: center;
    gap: 6px;
    padding: 3px 6px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.04);
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
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
    color: #4ade80;
    background: rgba(34, 197, 94, 0.12);
}

.tachyon_diag-telemetry__flight-pill.is-warn {
    color: #fbbf24;
    background: rgba(245, 158, 11, 0.14);
}

.tachyon_diag-telemetry__flight-pill.is-danger {
    color: #f87171;
    background: rgba(239, 68, 68, 0.14);
}

.tachyon_diag-telemetry__flight-net {
    color: #71717a;
    font-size: 10px;
}

.tachyon_diag-telemetry__flight-host {
    color: #e4e4e7;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.tachyon_diag-telemetry__flight-out {
    color: #38bdf8;
    font-size: 10px;
}

.tachyon_diag-telemetry__flight-dur {
    color: #71717a;
    font-size: 10px;
    text-align: right;
}

.tachyon_diag-telemetry__empty {
    font-size: 11px;
    color: #71717a;
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
    background: #111114;
    border: 1px solid rgba(255, 255, 255, 0.08);
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
    background: #16161a;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
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
    color: #f4f4f5;
    line-height: 1.25;
}

.tachyon_diagnostic-page__left-bar__title svg {
    color: #71717a;
    flex-shrink: 0;
}

.tachyon_diagnostic-page__left-bar__subtitle {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    color: #71717a;
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
    border: 1px solid rgba(255, 255, 255, 0.09);
    background: #151519;
}

.tachyon_diagnostic-summary-banner--loading {
    border-color: rgba(59, 130, 246, 0.28);
}

.tachyon_diagnostic-summary-banner--loading .tachyon_diagnostic-summary-banner__title svg {
    color: #60a5fa;
}

.tachyon_diagnostic-summary-banner--success {
    border-color: rgba(34, 197, 94, 0.24);
}

.tachyon_diagnostic-summary-banner--success .tachyon_diagnostic-summary-banner__title svg {
    color: #4ade80;
}

.tachyon_diagnostic-summary-banner--warning {
    border-color: rgba(245, 158, 11, 0.32);
}

.tachyon_diagnostic-summary-banner--warning .tachyon_diagnostic-summary-banner__title svg {
    color: #fbbf24;
}

.tachyon_diagnostic-summary-banner--error {
    border-color: rgba(239, 68, 68, 0.36);
}

.tachyon_diagnostic-summary-banner--error .tachyon_diagnostic-summary-banner__title svg {
    color: #f87171;
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
    color: #f4f4f5;
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
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    color: #a1a1aa;
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
    background: #111114;
    border: 1px solid rgba(255, 255, 255, 0.08);
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
    background: #16161a;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
}

.tachyon_diagnostic-action-group__title {
    font-size: 12px;
    font-weight: 600;
    color: #e4e4e7;
    line-height: 1.25;
}

.tachyon_diagnostic-action-group__subtitle {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 9.5px;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: #71717a;
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
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: #111114;
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
    background: #16161a;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
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
    color: #71717a;
    flex-shrink: 0;
}

.tachyon_diagnostic-page__right-bar__wiki__icon svg {
    width: 14px;
    height: 14px;
}

.tachyon_diagnostic-page__right-bar__wiki__texts b {
    font-size: 12px;
    font-weight: 600;
    color: #e4e4e7;
}

.tachyon_diagnostic-page__right-bar__wiki__meta {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 9.5px;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: #71717a;
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
    border: 1px solid rgba(255, 255, 255, 0.08) !important;
    background: #16161a !important;
    color: #d4d4d8 !important;
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon-partial-button:hover,
.tachyon_diagnostic-page__right-bar__wiki > button:hover {
    border-color: rgba(255, 255, 255, 0.16) !important;
    background: #1c1c21 !important;
    color: #f4f4f5 !important;
}

/* GPUI-Kit Subsystem Inspector Cards (Flat dark surface, zero full-box tint, zero left-border callout) */
.tachyon_diagnostic_alert {
    padding: 9px 11px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 4px;
    background: #141418;
    display: grid;
    grid-template-columns: 22px minmax(0, 1fr);
    gap: 7px 9px;
    align-content: start;
    transition: border-color 0.12s ease, background-color 0.12s ease;
}

.tachyon_diagnostic_alert:hover {
    border-color: rgba(255, 255, 255, 0.15);
    background: #17171c;
}

.tachyon_diagnostic_alert__icon {
    width: 22px;
    height: 22px;
    border-radius: 4px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: #1a1a20;
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: #a1a1aa;
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
    color: #f4f4f5;
    line-height: 1.25;
}

.tachyon_diagnostic_alert__counts-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 6px;
    border-radius: 3px;
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    background: #1a1a20;
    border: 1px solid rgba(255, 255, 255, 0.09);
    color: #a1a1aa;
}

.tachyon_diagnostic_alert__counts-badge--success {
    border-color: rgba(34, 197, 94, 0.25);
    color: #4ade80;
}

.tachyon_diagnostic_alert__counts-badge--warning {
    border-color: rgba(245, 158, 11, 0.3);
    color: #fbbf24;
}

.tachyon_diagnostic_alert__counts-badge--error {
    border-color: rgba(239, 68, 68, 0.32);
    color: #f87171;
}

.tachyon_diagnostic_alert__description {
    font-size: 11px;
    font-weight: 400;
    color: #8f8f99;
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
    background: #101013;
    border: 1px solid rgba(255, 255, 255, 0.07);
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10px;
    line-height: 1.3;
}

.tachyon_diagnostic_alert__preview-chip--error {
    border-color: rgba(239, 68, 68, 0.3);
}

.tachyon_diagnostic_alert__preview-chip--warning {
    border-color: rgba(245, 158, 11, 0.28);
}

.tachyon_diagnostic_alert__preview-dot {
    width: 5px;
    height: 5px;
    border-radius: 999px;
    flex-shrink: 0;
    background: #22c55e;
}

.tachyon_diagnostic_alert__preview-dot--warning {
    background: #f59e0b;
}

.tachyon_diagnostic_alert__preview-dot--error {
    background: #ef4444;
}

.tachyon_diagnostic_alert__preview-key {
    color: #a1a1aa;
    white-space: nowrap;
}

.tachyon_diagnostic_alert__preview-val {
    color: #e4e4e7;
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
    color: #71717a;
    margin-top: 2px;
}

.tachyon_diagnostic_alert:hover .tachyon_diagnostic_alert__toggle-hint {
    color: #d4d4d8;
}

.tachyon_diagnostic_alert__summary {
    grid-column: 1 / -1;
    display: none;
    flex-direction: column;
    gap: 1px;
    margin-top: 4px;
    border-radius: 4px;
    overflow: hidden;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.06);
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
    background: #0e0e11;
}

.tachyon_diagnostic_alert__summary__item b {
    font-weight: 500;
    color: #d4d4d8;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon_diagnostic_alert__summary__item > div {
    font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 10.5px;
    font-weight: 600;
    color: #a1a1aa;
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
    color: #f87171;
}

.tachyon_diagnostic_alert__summary__item--error b {
    color: #fca5a5;
}

.tachyon_diagnostic_alert__summary__item--error > div {
    color: #f87171;
}

.tachyon_diagnostic_alert__summary__item--warning {
    color: #fbbf24;
}

.tachyon_diagnostic_alert__summary__item--warning > div {
    color: #fbbf24;
}

.tachyon_diagnostic_alert__summary__item--success {
    color: #4ade80;
}

.tachyon_diagnostic_alert--loading {
    border-color: rgba(59, 130, 246, 0.28);
}

.tachyon_diagnostic_alert--loading .tachyon_diagnostic_alert__icon {
    color: #60a5fa;
    border-color: rgba(59, 130, 246, 0.28);
}

.tachyon_diagnostic_alert--warning {
    border-color: rgba(245, 158, 11, 0.3);
}

.tachyon_diagnostic_alert--warning .tachyon_diagnostic_alert__icon {
    color: #fbbf24;
    border-color: rgba(245, 158, 11, 0.28);
}

.tachyon_diagnostic_alert--error {
    border-color: rgba(239, 68, 68, 0.34);
}

.tachyon_diagnostic_alert--error .tachyon_diagnostic_alert__icon {
    color: #f87171;
    border-color: rgba(239, 68, 68, 0.32);
}

.tachyon_diagnostic_alert--success {
    border-color: rgba(255, 255, 255, 0.08);
}

.tachyon_diagnostic_alert--success .tachyon_diagnostic_alert__icon {
    color: #4ade80;
    border-color: rgba(34, 197, 94, 0.24);
}

.tachyon_diagnostic_alert--skipped {
    border-color: rgba(255, 255, 255, 0.05);
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
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
}

.tachyon_diagnostic-modal__progress-bar {
    height: 100%;
    border-radius: 2px;
    background: #3b82f6;
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
    border-top: 1px solid rgba(255, 255, 255, 0.08);
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
