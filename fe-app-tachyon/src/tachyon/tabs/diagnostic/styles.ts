// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > div {
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic > h3 {
    display: none;
}

.tachyon_diagnostic-page {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.tachyon_diagnostic-page__top-bar {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
}

.tachyon_diagnostic-page__top-bar button {
    min-width: 0;
}

.tachyon_diagnostic-page__main {
    display: grid;
    grid-template-columns: 2fr 1fr;
    gap: 16px;
    align-items: start;
}

@media (max-width: 800px) {
    .tachyon_diagnostic-page__main {
        grid-template-columns: 1fr;
    }
}

.tachyon_diagnostic-page__left {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon_diagnostic-page__right {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.tachyon_diagnostic-page__right > .cbi-section {
    margin: 0;
    padding: 10px;
}

.tachyon_diagnostic-page__right > .cbi-section > h3 {
    margin: 0 0 8px 0;
    padding: 0 0 4px 0;
    border-bottom: 1px solid var(--border-color-medium, #ccc);
    font-size: 14px;
}

.tachyon_diagnostic-page__actions-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.tachyon_diagnostic-page__actions-list .cbi-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
    text-align: left;
}

.tachyon_diagnostic-page__system-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.tachyon_diagnostic-page__system-info__row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 8px;
    font-size: 13px;
    padding: 2px 0;
    border-bottom: 1px dotted var(--border-color-light, #eee);
}

.tachyon_diagnostic-page__system-info__row:last-child {
    border-bottom: none;
}

.tachyon_diagnostic-page__system-info__row b {
    flex-shrink: 0;
}

.tachyon_diagnostic-page__system-info__row span {
    text-align: right;
    word-break: break-all;
}

.tachyon_check-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    border: 1px solid var(--border-color-medium, #ccc);
    border-radius: 4px;
    background: var(--background-color-primary, #fff);
    transition: border-color 0.2s;
}

.tachyon_check-row--loading {
    border-color: var(--primary-color, #007bff);
    opacity: 0.85;
}

.tachyon_check-row--success {
    border-color: var(--success-color, #28a745);
}

.tachyon_check-row--warning {
    border-color: var(--warn-color, #ffc107);
}

.tachyon_check-row--error {
    border-color: var(--error-color, #dc3545);
}

.tachyon_check-row--skipped {
    opacity: 0.5;
}

.tachyon_check-row__icon {
    flex-shrink: 0;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.tachyon_check-row__body {
    flex: 1;
    min-width: 0;
}

.tachyon_check-row__title {
    font-weight: bold;
    font-size: 13px;
    display: block;
}

.tachyon_check-row__detail {
    font-size: 12px;
    opacity: 0.8;
    display: block;
}

.tachyon_check-row__summary {
    margin-top: 6px;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon_check-row__summary__item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
}

.tachyon_check-row__summary__item--error { color: var(--error-color, #dc3545); }
.tachyon_check-row__summary__item--warning { color: var(--warn-color, #ffc107); }
.tachyon_check-row__summary__item--success { color: var(--success-color, #28a745); }

.tachyon_check-row__summary__item b {
    flex-shrink: 0;
}

.tachyon_wiki-box {
    border: 1px solid var(--border-color-medium, #ccc);
    border-radius: 4px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.tachyon_wiki-box--warning {
    border-color: var(--warn-color, #ffc107);
}

.tachyon_wiki-box--error {
    border-color: var(--error-color, #dc3545);
}

.tachyon_wiki-box__content {
    display: flex;
    gap: 10px;
    align-items: flex-start;
}

.tachyon_wiki-box__content > span {
    flex-shrink: 0;
    margin-top: 2px;
}

.tachyon_ai_chat__messages {
    height: 360px;
    overflow-y: auto;
    padding: 8px;
    background: var(--background-color-secondary, rgba(0,0,0,0.05));
    border: 1px solid var(--border-color-medium, #ccc);
    border-radius: 4px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-bottom: 10px;
}

.tachyon_ai_chat__bubble {
    max-width: 82%;
    padding: 6px 10px;
    border-radius: 8px;
    font-size: 13px;
    line-height: 1.4;
    word-break: break-word;
    border: 1px solid var(--border-color-medium, #ccc);
    background: var(--background-color-primary, #fff);
}

.tachyon_ai_chat__bubble--user {
    align-self: flex-end;
    background: var(--primary-color, #007bff);
    color: #fff;
    border-color: var(--primary-color-dark, #0056b3);
}

.tachyon_ai_chat__bubble small {
    display: block;
    opacity: 0.6;
    text-align: right;
    font-size: 10px;
    margin-top: 2px;
}

.tachyon_ai_chat__toolbar {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
    margin-bottom: 8px;
}

.tachyon_ai_chat__input-row {
    display: flex;
    gap: 8px;
    align-items: center;
}

.tachyon_ai_chat__input-row input {
    flex: 1 1 auto;
    min-width: 0;
}

.tachyon_service_check__mode-bar {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border-color-light, #eee);
}

.tachyon_service_check__stats {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    margin-bottom: 12px;
}

.tachyon_service_check__stat {
    flex: 1 1 100px;
    min-width: 80px;
    padding: 6px 8px;
    border: 1px solid var(--border-color-medium, #ccc);
    border-radius: 4px;
    text-align: center;
    background: var(--background-color-secondary, rgba(0,0,0,0.03));
}

.tachyon_service_check__stat small {
    display: block;
    opacity: 0.7;
    font-size: 11px;
}

.tachyon_service_check__stat b {
    display: block;
    margin-top: 2px;
    font-size: 16px;
}

.tachyon_service_check__table-scroll {
    max-height: 380px;
    overflow-y: auto;
    border: 1px solid var(--border-color-medium, #ccc);
    border-radius: 4px;
}

.tachyon_service_check__footer {
    margin-top: 12px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    border-top: 1px solid var(--border-color-light, #eee);
    padding-top: 10px;
    flex-wrap: wrap;
}
`;
