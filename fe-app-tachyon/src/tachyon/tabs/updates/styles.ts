// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${TACHYON_CBI_PREFIX}-updates-_mount_node > div {
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-updates > h3 {
    display: none;
}

.tachyon_updates-page {
    width: 100%;
}

.tachyon_updates-page__components {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    align-items: stretch;
    gap: 12px;
    width: 100%;
}

.tachyon_updates-page__components-column {
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-width: 0;
}

@media (max-width: 820px) {
    .tachyon_updates-page__components {
        grid-template-columns: 1fr;
    }

    .tachyon_updates-page__engine-card {
        flex: 1 1 100%;
        width: 100%;
        margin-bottom: 10px;
    }

    .tachyon_updates-page__components-column {
        width: 100%;
        min-width: 0;
    }

    .tachyon_updates-page__component {
        width: 100%;
        min-width: 0;
        box-sizing: border-box;
    }
}

.tachyon_updates-page__component {
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.22));
    border-radius: 12px;
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    justify-content: flex-start;
    gap: 10px;
    min-width: 0;
    height: 100%;
    box-sizing: border-box;
    transition: border-color 0.15s ease;
}

.tachyon_updates-page__component__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    border-bottom: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.14));
    padding-bottom: 10px;
    margin-bottom: 0;
    min-height: 28px;
}

.tachyon_updates-page__component__header-main {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    min-width: 0;
    flex: 1 1 auto;
}

.tachyon_updates-page__component__header-tools {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
    margin-left: auto;
}

.tachyon_updates-page__component__header-main .tachyon-badge {
    margin-left: 0 !important;
}

.tachyon_updates-page__component__title {
    color: var(--text-color-high);
    font-size: 14px;
    font-weight: 700;
    line-height: 1.25;
    white-space: nowrap;
}

.tachyon_updates-page__component__header-version {
    color: var(--text-color-medium, #888);
    font-size: 12px;
    font-weight: 500;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 260px;
    padding: 2px 7px;
    border-radius: 6px;
    background: rgba(128, 128, 128, 0.1);
    border: 1px solid rgba(128, 128, 128, 0.16);
    line-height: 1.35;
}

.tachyon_updates-page__component__repo-link {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    padding: 0;
    border: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
    background: rgba(128, 128, 128, 0.06);
    border-radius: 6px;
    color: var(--text-color-medium, #888);
    text-decoration: none;
    cursor: pointer;
    transition: color 0.15s, background-color 0.15s, border-color 0.15s;
    flex-shrink: 0;
}

.tachyon_updates-page__component__repo-link:hover {
    color: var(--link-color, #3498db);
    background-color: var(--background-color-low, rgba(128, 128, 128, 0.14));
    border-color: var(--border-color-medium, rgba(128, 128, 128, 0.3));
}

.tachyon_updates-page__component__details {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    width: 100%;
}

.tachyon_updates-page__component__info-row {
    display: inline-flex;
    justify-content: flex-start;
    align-items: center;
    flex-wrap: wrap;
    min-height: 26px;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 8px;
    background: rgba(148, 163, 184, 0.08);
    border: 1px solid rgba(148, 163, 184, 0.18);
    width: 100%;
    box-sizing: border-box;
}

.tachyon_updates-page__component__info-row--outdated {
    background: rgba(139, 92, 246, 0.1);
    border-color: rgba(139, 92, 246, 0.28);
}

.tachyon_updates-page__component__info-row--latest {
    background: rgba(16, 185, 129, 0.08);
    border-color: rgba(16, 185, 129, 0.22);
}

.tachyon_updates-page__component__info-label {
    color: var(--text-color-medium, #888);
    font-size: 12px;
    line-height: 1.3;
}

.tachyon_updates-page__component__info-value {
    color: var(--text-color-high, #000);
    font-weight: 600;
    font-size: 12px;
    text-align: left;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    overflow-wrap: anywhere;
}

.tachyon_updates-page__component__info-value--latest {
    flex-wrap: wrap;
    justify-content: flex-start;
}

.tachyon_updates-page__component__release-version-link {
    color: var(--link-color, #3498db) !important;
    text-decoration: underline;
    font-weight: 700;
}

.tachyon_updates-page__component__release-version-link:hover {
    color: var(--link-color-dark, #2980b9) !important;
}

.tachyon_updates-page__component__sha-info {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 11px;
    color: var(--text-color-medium, #888);
    background: var(--background-color-low, rgba(0,0,0,0.06));
    border-radius: 4px;
    padding: 1px 6px;
    letter-spacing: 0.02em;
}

.tachyon_updates-page__engine-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    flex-wrap: nowrap;
}

.tachyon_updates-page__engine-bar > select.cbi-input-select {
    flex: 1 1 auto !important;
    width: auto !important;
    min-width: 0 !important;
    max-width: none !important;
    height: 32px !important;
    min-height: 32px !important;
    padding: 4px 10px !important;
    font-size: 12px !important;
    font-weight: 500 !important;
    border-radius: 8px !important;
    margin: 0 !important;
}

.tachyon_updates-page__engine-bar > .btn,
.tachyon_updates-page__engine-bar > .cbi-button,
.tachyon_updates-page__engine-bar > .tachyon-partial-button {
    flex-shrink: 0 !important;
    padding: 5px 12px !important;
    min-height: 32px !important;
    font-size: 12px !important;
    font-weight: 600 !important;
    border-radius: 8px !important;
    margin: 0 !important;
    white-space: nowrap !important;
}

.tachyon_updates-page__component__actions {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: auto;
    padding-top: 2px;
}

.tachyon_updates-page__component__actions--with-details {
    border-top: 1px var(--background-color-low, lightgray) solid;
    padding-top: 10px;
}

.tachyon_updates-page__component__actions-main {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon_updates-page__component__actions-main > .btn,
.tachyon_updates-page__component__actions-main > .cbi-button,
.tachyon_updates-page__component__actions-main > .tachyon-partial-button {
    padding: 5px 11px !important;
    min-height: 32px !important;
    font-size: 12px !important;
    font-weight: 600 !important;
    border-radius: 8px !important;
    margin: 0 !important;
    white-space: nowrap !important;
}

.tachyon_updates-page__component__actions-main > select.cbi-input-select {
    height: 32px !important;
    min-height: 32px !important;
    padding: 4px 8px !important;
    font-size: 12px !important;
    border-radius: 8px !important;
    margin: 0 !important;
}

.tachyon_updates-page__component__variants {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-top: 4px;
}

.tachyon_updates-page__component__variants-title {
    font-size: 11px;
    font-weight: bold;
    color: var(--text-color-medium, gray);
}

.tachyon_updates-page__component__variants-buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

.tachyon-update-modal__body {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 100%;
    box-sizing: border-box;
    padding: 6px 0;
}

.tachyon-update-modal__header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 10px;
    border-bottom: 1px solid var(--border-color-low, rgba(128,128,128,0.2));
    padding-bottom: 10px;
}

.tachyon-update-modal__header-info {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon-update-modal__component-name {
    font-size: 16px;
    font-weight: bold;
    color: var(--text-color-high, inherit);
}

.tachyon-update-modal__version-badge {
    font-size: 12px;
    font-family: monospace;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--background-color-low, rgba(0, 0, 0, 0.05));
    color: var(--text-color-high, inherit);
    border: 1px solid var(--border-color-low, #dee2e6);
}

.tachyon-update-modal__timer-badge {
    font-size: 13px;
    font-family: monospace;
    color: var(--text-color-medium, #6c757d);
}

.tachyon-update-modal__phase-badge {
    font-size: 12px;
    font-family: monospace;
    color: var(--color-blue-base, #3498db);
    background: var(--color-blue-bg, #ebf5fb);
    padding: 2px 8px;
    border-radius: 4px;
    white-space: nowrap;
}

.tachyon-update-modal__phase-badge--hidden {
    display: none;
}

.tachyon-update-modal__success-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--color-green-base, #2ecc71);
    font-weight: bold;
}

.tachyon-update-modal__error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--color-red-base, #e74c3c);
    font-weight: bold;
}

.tachyon-update-modal__actions {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    margin-top: 6px;
    border-top: 1px solid var(--border-color-low, #dee2e6);
    padding-top: 10px;
    flex-wrap: wrap;
}

.tachyon-update-modal__action-buttons {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
}

.tachyon-update-modal__log-panel {
    display: flex;
    flex-direction: column;
    gap: 6px;
    flex: 1 1 auto;
    min-height: 0;
}

.tachyon-update-modal__log-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    color: var(--text-color-high, inherit);
}

.tachyon-update-modal__log-copy {
    padding: 2px 8px;
    font-size: 12px;
}

.tachyon-update-modal__log {
    margin: 0;
    height: 350px;
    min-height: 200px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-all;
    font-family: monospace;
    font-size: 11px;
    line-height: 1.5;
    color: var(--text-color-high, #212529);
    background: var(--background-color-low, #f8f9fa);
    border: 1px solid var(--border-color-low, #dee2e6);
    border-radius: 4px;
    padding: 8px;
    flex: 1 1 auto;
    min-height: 0;
}

.tachyon-version-picker {
    margin-top: 8px;
    padding: 8px;
    border: 1px solid var(--border-color-low, #dee2e6);
    border-radius: 4px;
    background: var(--background-color-low, #f8f9fa);
}

.tachyon-version-picker__loading,
.tachyon-version-picker__error {
    padding: 6px 0;
    font-size: 12px;
    color: var(--text-color-medium, #6c757d);
}

.tachyon-version-picker__error {
    color: var(--color-red-base, #e74c3c);
}

.tachyon-version-picker__list {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon-version-picker__item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0;
    border-bottom: 1px solid var(--border-color-low, #e9ecef);
}

.tachyon-version-picker__item:last-child {
    border-bottom: none;
}

.tachyon-version-picker__tag {
    font-weight: bold;
    font-size: 13px;
    color: var(--text-color-high, inherit);
    white-space: nowrap;
}

.tachyon-version-picker__date {
    font-size: 11px;
    color: var(--text-color-medium, #6c757d);
    white-space: nowrap;
}

.tachyon-version-picker__prerelease {
    font-size: 10px;
    color: var(--color-yellow-base, #f39c12);
    border: 1px solid var(--color-yellow-base, #f39c12);
    border-radius: 3px;
    padding: 1px 4px;
    white-space: nowrap;
}

.tachyon-version-picker__actions {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin-left: auto;
    flex-shrink: 0;
}

.tachyon-version-picker__custom {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border-color-low, #dee2e6);
}

.tachyon-version-picker__custom-input {
    flex: 1 1 auto;
    font-size: 12px;
    padding: 4px 8px;
    height: 30px;
}

.tachyon-version-picker__empty {
    padding: 6px 0;
    font-size: 12px;
    color: var(--text-color-medium, #6c757d);
    font-style: italic;
}

.tachyon-version-picker__pagination {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color-low, #dee2e6);
}

.tachyon-version-picker__page-num {
    font-size: 12px;
    font-weight: 500;
    color: var(--text-color-medium, #6c757d);
}
`;
