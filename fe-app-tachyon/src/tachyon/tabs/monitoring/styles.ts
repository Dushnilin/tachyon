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
    --tachyon-monitoring-control-height: 34px;
    --tachyon-monitoring-row-action-size: 24px;
    --tachyon-monitoring-divider-color: rgba(127, 127, 127, 0.22);
    --tachyon-monitoring-soft-bg: rgba(127, 127, 127, 0.08);
    --tachyon-monitoring-soft-bg-hover: rgba(127, 127, 127, 0.14);
    --tachyon-monitoring-danger-color: var(--error-color-medium, #d32f2f);
    --tachyon-monitoring-success-color: var(--success-color-medium, #2e7d32);
    --tachyon-monitoring-paused-color: var(--primary-color-high, #1976d2);

    width: 100%;
    min-width: 0;
}

.tachyon_monitoring-page__panel {
    margin-top: 0;
    border: 0;
    border-radius: 0;
    padding: 0;
    background: transparent;
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button {
    width: 32px;
    height: 32px;
    min-width: 32px;
    min-height: 32px;
    padding: 0;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
    border: 1px solid var(--tachyon-monitoring-divider-color) !important;
    border-radius: 6px;
    background: var(--tachyon-monitoring-soft-bg) !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button:hover:not(:disabled) {
    background: var(--tachyon-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__icon-button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
}

.tachyon_monitoring-page #monitoring-close-all.btn.tachyon_monitoring-page__icon-button {
    order: 2;
    border-color: rgba(217, 83, 79, 0.4) !important;
    background: transparent !important;
    color: var(--tachyon-monitoring-danger-color) !important;
}

.tachyon_monitoring-page #monitoring-close-all.btn.tachyon_monitoring-page__icon-button:hover:not(:disabled) {
    border-color: rgba(217, 83, 79, 0.6) !important;
    background: transparent !important;
    color: color-mix(in srgb, var(--tachyon-monitoring-danger-color) 70%, white) !important;
}

.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button,
.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button--active {
    order: 1;
    border-color: rgba(128, 128, 128, 0.3) !important;
    background: transparent !important;
    color: var(--text-color-medium, #888) !important;
}

.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button:hover:not(:disabled),
.tachyon_monitoring-page #monitoring-pause-toggle.btn.tachyon_monitoring-page__icon-button--active:hover:not(:disabled) {
    border-color: rgba(128, 128, 128, 0.6) !important;
    background: transparent !important;
    color: var(--text-color-high, #eee) !important;
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
    gap: 16px;
    margin-bottom: 12px;
    width: 100%;
    min-width: 0;
}

.tachyon_monitoring-page__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    min-width: 0;
}

.tachyon_monitoring-page__tabs {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    width: max-content;
    padding: 2px;
    border: 1px solid var(--tachyon-monitoring-divider-color);
    border-radius: 6px;
    background: var(--tachyon-monitoring-soft-bg);
    box-sizing: border-box;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab {
    height: calc(var(--tachyon-monitoring-control-height) - 6px);
    min-height: calc(var(--tachyon-monitoring-control-height) - 6px);
    margin: 0;
    padding: 0 12px;
    border: 0 !important;
    border-radius: 4px;
    background: transparent !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-weight: 600;
    line-height: 1;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab:hover {
    background: var(--tachyon-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.tachyon_monitoring-page .btn.tachyon_monitoring-page__tab--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
    font-weight: 700;
}

.tachyon_monitoring-page__tab-label {
    display: inline-block;
}

.tachyon_monitoring-page__tab-badge {
    min-width: 18px;
    height: 18px;
    padding: 0 6px;
    border-radius: 999px;
    background: rgba(127, 127, 127, 0.22);
    color: var(--text-color-medium);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    font-size: 12px;
    font-weight: 700;
    line-height: 1;
}

.tachyon_monitoring-page__tab--active .tachyon_monitoring-page__tab-badge {
    background: rgba(25, 118, 210, 0.22);
    color: var(--primary-color-high, #1976d2);
}

.tachyon_monitoring-page__filters {
    display: flex;
    flex: 1 1 auto;
    flex-wrap: wrap;
    align-items: center;
    justify-content: flex-start;
    gap: 12px;
    min-width: 0;
}

.tachyon_monitoring-page__device-filter {
    width: min(220px, 100%);
    min-width: 0;
    height: var(--tachyon-monitoring-control-height) !important;
    min-height: var(--tachyon-monitoring-control-height) !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    box-sizing: border-box;
    line-height: calc(var(--tachyon-monitoring-control-height) - 2px) !important;
}

.tachyon_monitoring-page__search {
    position: relative;
    display: flex;
    align-items: center;
    width: min(320px, 100%);
    min-width: 0;
    height: var(--tachyon-monitoring-control-height);
    margin: 0;
}

.tachyon_monitoring-page__search-icon {
    position: absolute;
    left: 8px;
    width: 16px;
    height: 16px;
    color: var(--text-color-medium);
    pointer-events: none;
}

.tachyon_monitoring-page__search-icon svg {
    width: 16px;
    height: 16px;
    display: block;
}

.tachyon_monitoring-page__search-input {
    width: 100%;
    height: var(--tachyon-monitoring-control-height) !important;
    min-height: var(--tachyon-monitoring-control-height) !important;
    padding-left: 30px !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
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
}

.tachyon_monitoring-page__table {
    width: 100%;
    min-width: 840px;
    table-layout: fixed;
    border-collapse: collapse;
    border-spacing: 0;
    margin-bottom: 0;
}

.tachyon_monitoring-page__table th,
.tachyon_monitoring-page__table td {
    padding: 8px 6px;
    border-bottom: 1px solid var(--tachyon-monitoring-divider-color);
    box-sizing: border-box;
    text-align: left;
    vertical-align: middle;
    overflow: hidden;
    white-space: nowrap;
}

.tachyon_monitoring-page__table th {
    color: var(--text-color-medium);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    white-space: nowrap;
    border-bottom-color: rgba(127, 127, 127, 0.32);
}

.tachyon_monitoring-page__table th:nth-child(1) {
    width: 28%;
}

.tachyon_monitoring-page__table th:nth-child(2) {
    width: 6%;
}

.tachyon_monitoring-page__table th:nth-child(3) {
    width: 16%;
}

.tachyon_monitoring-page__table th:nth-child(4) {
    width: 8%;
}

.tachyon_monitoring-page__table th:nth-child(5) {
    width: 9.5%;
}

.tachyon_monitoring-page__table th:nth-child(6) {
    width: 8.5%;
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
    color: var(--text-color-high);
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
    color: var(--text-color-medium);
    font-size: 12px;
}

.tachyon_monitoring-page__source-value--ip-only {
    color: var(--text-color-high);
}

.tachyon_monitoring-page__cell-main {
    color: var(--text-color-high);
    font-weight: 600;
    line-height: 1.25;
}

.tachyon_monitoring-page__cell-secondary {
    margin-top: 2px;
    color: var(--text-color-medium);
    font-size: 12px;
    line-height: 1.25;
}

.tachyon_monitoring-page__route {
    display: inline-block;
    width: auto;
    padding: 2px 6px;
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    color: var(--text-color-high, #eee);
    font-size: 11px;
    font-weight: 500;
}

.tachyon_monitoring-page__network {
    background: transparent;
    border: 0;
    padding: 0;
    color: var(--text-color-medium, #bbb);
    font-family: inherit;
    font-size: 13px;
    text-transform: lowercase;
}

.tachyon_monitoring-page__table td:nth-child(4) .tachyon_monitoring-page__value,
.tachyon_monitoring-page__table td:nth-child(5) .tachyon_monitoring-page__value,
.tachyon_monitoring-page__table td:nth-child(6) .tachyon_monitoring-page__value {
    color: var(--text-color-medium, #bbb);
    font-family: inherit;
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
    min-height: 90px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-color-medium);
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
