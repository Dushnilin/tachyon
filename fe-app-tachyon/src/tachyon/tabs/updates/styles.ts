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
    display: flex;
    align-items: flex-start;
    gap: 10px;
    width: 100%;
    flex-wrap: wrap;
}

.tachyon_updates-page__components-column {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    gap: 10px;
    min-width: max-content;
}

@media (max-width: 760px) {
    .tachyon_updates-page__components {
        flex-direction: column;
    }

    .tachyon_updates-page__components-column {
        width: 100%;
        min-width: 0;
    }
}

.tachyon_updates-page__component {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: max-content;
}

.tachyon_updates-page__component__header {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    border-bottom: 1px var(--background-color-low, lightgray) solid;
    padding-bottom: 8px;
    margin-bottom: 2px;
}

.tachyon_updates-page__component__title {
    color: var(--text-color-high);
    font-size: 16px;
    font-weight: bold;
    line-height: 1.2;
}

.tachyon_updates-page__component__header-version {
    color: var(--text-color-medium, #888);
    font-size: 13px;
    font-weight: normal;
}

.tachyon_updates-page__component__repo-link {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: 3px;
    color: var(--text-color-medium, #888);
    text-decoration: none;
    transition: color 0.15s, background-color 0.15s;
    flex-shrink: 0;
}

.tachyon_updates-page__component__repo-link:hover {
    color: var(--link-color, #3498db);
    background-color: var(--background-color-low, rgba(0, 0, 0, 0.05));
}

.tachyon_updates-page__component__details {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon_updates-page__component__info-row {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    min-height: 24px;
    gap: 8px;
    white-space: nowrap;
}

.tachyon_updates-page__component__info-label {
    color: var(--text-color-medium, #888);
    font-size: 12px;
}

.tachyon_updates-page__component__info-value {
    color: var(--text-color-high, #000);
    font-weight: 500;
    font-size: 13px;
    text-align: left;
    display: flex;
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
    font-weight: bold;
}

.tachyon_updates-page__component__release-version-link:hover {
    color: var(--link-color-dark, #2980b9) !important;
}

.tachyon_updates-page__component__sha-info {
    font-family: monospace;
    font-size: 11px;
    color: var(--text-color-medium, #888);
    background: var(--background-color-low, rgba(0,0,0,0.06));
    border-radius: 3px;
    padding: 1px 5px;
    letter-spacing: 0.02em;
}

.tachyon_updates-page__component__actions {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: auto;
}

.tachyon_updates-page__component__actions--with-details {
    border-top: 1px var(--background-color-low, lightgray) solid;
    padding-top: 10px;
}

.tachyon_updates-page__component__actions-main {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    flex-wrap: nowrap;
    gap: 6px;
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
    flex-wrap: nowrap;
    gap: 6px;
}

.tachyon-update-modal__body {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 100%;
    max-width: 640px;
    box-sizing: border-box;
    padding: 6px 0;
}

.tachyon-update-modal__header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 10px;
    border-bottom: 1px solid var(--border-color, rgba(255,255,255,0.12));
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
    color: var(--text-color-high, #fff);
}

.tachyon-update-modal__version-badge {
    font-size: 12px;
    font-family: monospace;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--background-color-low, rgba(0,0,0,0.1));
    color: var(--text-color-medium, #aaa);
    border: 1px solid var(--border-color, rgba(255,255,255,0.1));
}

.tachyon-update-modal__timer-badge {
    font-size: 13px;
    font-family: monospace;
    color: var(--text-color-medium, #888);
}

.tachyon-update-modal__success-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #2ecc71;
    font-weight: bold;
}

.tachyon-update-modal__error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #e74c3c;
    font-weight: bold;
}

.tachyon-update-modal__actions {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    gap: 8px;
    margin-top: 6px;
    border-top: 1px solid var(--border-color, rgba(255,255,255,0.12));
    padding-top: 10px;
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
    color: var(--text-color, #ddd);
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid var(--border-color, rgba(255,255,255,0.12));
    border-radius: 4px;
    padding: 8px;
    flex: 1 1 auto;
    min-height: 0;
}
`;
