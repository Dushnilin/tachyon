// language=CSS
import { TACHYON_UCI_PACKAGE as TACHYON_CBI_PREFIX } from '../../../constants';

export const styles = `

#cbi-${TACHYON_CBI_PREFIX}-diagnostic-_mount_node > div {
    width: 100%;
}

#cbi-${TACHYON_CBI_PREFIX}-diagnostic > h3 {
    display: none;
}

.tachyon_diagnostic-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.tachyon_diagnostic-system-strip {
    width: 100%;
}

.tachyon_diagnostic-page {
    display: grid;
    grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr);
    gap: 16px;
    align-items: start;
}

.tachyon_diagnostic-page__left-bar {
    display: flex;
    flex-direction: column;
    gap: 16px;
    padding: 18px 20px;
    background: var(--tachyon-bg-card, var(--background-color-high, rgba(128, 128, 128, 0.04)));
    border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128, 128, 128, 0.22)));
    border-radius: var(--tachyon-radius-card, 14px);
    box-shadow: var(--tachyon-shadow-card, none);
}

.tachyon_diagnostic-page__left-bar__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    flex-wrap: wrap;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));
}

.tachyon_diagnostic-page__left-bar__header-titles {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
}

.tachyon_diagnostic-page__left-bar__title {
    font-size: 15px;
    font-weight: 700;
    color: var(--tachyon-text-main, inherit);
    letter-spacing: -0.01em;
}

.tachyon_diagnostic-page__left-bar__subtitle {
    font-size: 12px;
    color: var(--tachyon-text-muted, #94a3b8);
    line-height: 1.4;
}

.tachyon_diagnostic-page__checks {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(265px, 1fr));
    gap: 12px;
    align-items: stretch;
}

.tachyon_diagnostic-page__run_check_wrapper button {
    width: auto;
    min-width: 175px;
    height: 36px;
    font-weight: 600;
}

.tachyon_diagnostic-page__right-bar {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.tachyon_diagnostic-page__right-bar__actions {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.tachyon_diagnostic-action-group {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px 18px;
    background: var(--tachyon-bg-card, var(--background-color-high, rgba(128, 128, 128, 0.04)));
    border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128, 128, 128, 0.22)));
    border-radius: var(--tachyon-radius-card, 14px);
    box-shadow: var(--tachyon-shadow-card, none);
}

.tachyon_diagnostic-action-group__header {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));
}

.tachyon_diagnostic-action-group__title {
    font-size: 14px;
    font-weight: 700;
    color: var(--tachyon-text-main, inherit);
    letter-spacing: -0.01em;
}

.tachyon_diagnostic-action-group__subtitle {
    font-size: 11.5px;
    color: var(--tachyon-text-muted, #94a3b8);
}

.tachyon_diagnostic-action-group__grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(185px, 1fr));
    gap: 10px;
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
    text-align: left;
    padding: 9px 12px !important;
    min-height: 38px;
    height: auto !important;
    font-size: 12.5px;
    font-weight: 600;
    line-height: 1.3 !important;
    white-space: normal !important;
    word-break: normal !important;
    overflow-wrap: break-word !important;
    border-radius: 10px !important;
    box-sizing: border-box !important;
}

/* System Info Bento Strip */
.tachyon_diagnostic-page__right-bar__system-info {
    padding: 16px 20px;
    background: var(--tachyon-bg-card, var(--background-color-high, rgba(128, 128, 128, 0.04)));
    border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128, 128, 128, 0.22)));
    border-radius: var(--tachyon-radius-card, 14px);
    box-shadow: var(--tachyon-shadow-card, none);
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(165px, 1fr));
    gap: 10px;
    align-items: stretch;
}

.tachyon_diagnostic-page__right-bar__system-info__title {
    grid-column: 1 / -1;
    font-size: 12px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--tachyon-text-muted, #94a3b8);
    margin-bottom: 2px;
    display: flex;
    align-items: center;
    gap: 8px;
}

.tachyon_diagnostic-page__right-bar__system-info__title::before {
    content: "🖥️";
    font-size: 14px;
}

.tachyon_diagnostic-page__right-bar__system-info__row {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 6px;
    padding: 10px 12px;
    border-radius: 10px;
    background: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.05));
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));
    min-width: 0;
}

.tachyon_diagnostic-page__right-bar__system-info__row > b {
    font-size: 10.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--tachyon-text-muted, #94a3b8);
}

.tachyon_diagnostic-page__right-bar__system-info__row > div {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    flex-wrap: wrap;
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 12.5px;
    font-weight: 600;
    color: var(--tachyon-text-main, inherit);
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
    padding: 2px 7px;
    border-radius: 999px;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    line-height: 1.2;
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--neutral {
    background: rgba(148, 163, 184, 0.14);
    color: var(--tachyon-text-secondary, gray);
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--warning {
    background: var(--tachyon-warning-soft, rgba(245, 158, 11, 0.15));
    color: var(--tachyon-warning-text, #f59e0b);
}

.tachyon_diagnostic-page__right-bar__system-info__row__tag--success {
    background: var(--tachyon-success-soft, rgba(16, 185, 129, 0.15));
    color: var(--tachyon-success-text, #10b981);
}

/* Wiki / Troubleshooting & Support Bento Card */
.tachyon_diagnostic-page__right-bar__wiki {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    padding: 16px 18px;
    border-radius: var(--tachyon-radius-card, 14px);
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.22));
    background: var(--tachyon-bg-card, rgba(128, 128, 128, 0.04));
    box-shadow: var(--tachyon-shadow-card, none);
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon-partial-button,
.tachyon_diagnostic-page__right-bar__wiki > button.btn,
.tachyon_diagnostic-page__right-bar__wiki > button.cbi-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    padding: 9px 12px !important;
    min-height: 38px;
    height: auto !important;
    font-size: 12.5px;
    font-weight: 600;
    line-height: 1.3 !important;
    white-space: normal !important;
    word-break: normal !important;
    overflow-wrap: break-word !important;
    border-radius: 10px !important;
    box-sizing: border-box !important;
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.24)) !important;
    background: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.08)) !important;
    color: var(--tachyon-text-main, inherit) !important;
    transition: border-color 0.16s ease, background 0.16s ease, transform 0.12s ease;
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon-partial-button:hover,
.tachyon_diagnostic-page__right-bar__wiki > button.btn:hover {
    border-color: rgba(148, 130, 224, 0.38) !important;
    background: rgba(148, 130, 224, 0.1) !important;
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon_diagnostic-wiki-btn--support,
.tachyon_diagnostic-page__right-bar__wiki > button:last-child {
    grid-column: 1 / -1;
    border-color: var(--tachyon-border-subtle, rgba(148, 163, 184, 0.24)) !important;
    background: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.08)) !important;
    color: var(--tachyon-text-main, inherit) !important;
}

.tachyon_diagnostic-page__right-bar__wiki > .tachyon_diagnostic-wiki-btn--support:hover,
.tachyon_diagnostic-page__right-bar__wiki > button:last-child:hover {
    border-color: rgba(148, 130, 224, 0.38) !important;
    background: rgba(148, 130, 224, 0.12) !important;
}

.tachyon_diagnostic-page__right-bar__wiki--warning {
    border-color: var(--tachyon-warning-border, rgba(245, 158, 11, 0.45));
    background: linear-gradient(145deg, var(--tachyon-warning-soft, rgba(245, 158, 11, 0.1)), var(--tachyon-bg-card, transparent));
}

.tachyon_diagnostic-page__right-bar__wiki--error {
    border-color: var(--tachyon-danger-border, rgba(239, 68, 68, 0.45));
    background: linear-gradient(145deg, var(--tachyon-danger-soft, rgba(239, 68, 68, 0.1)), var(--tachyon-bg-card, transparent));
}

.tachyon_diagnostic-page__right-bar__wiki__content {
    grid-column: 1 / -1;
    display: grid;
    grid-template-columns: 36px minmax(0, 1fr);
    gap: 12px;
    align-items: center;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));
}

.tachyon_diagnostic-page__right-bar__wiki__icon {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: rgba(99, 102, 241, 0.14);
    color: var(--tachyon-accent, #6366f1);
}

.tachyon_diagnostic-page__right-bar__wiki__texts {
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tachyon_diagnostic-page__right-bar__wiki__texts b {
    font-size: 14px;
    font-weight: 700;
    color: var(--tachyon-text-main, inherit);
}

.tachyon_diagnostic-page__right-bar__wiki__texts div {
    font-size: 12px;
    color: var(--tachyon-text-secondary, #94a3b8);
}

/* Subsystem Check Bento Tiles */
.tachyon_diagnostic_alert {
    padding: 14px 16px;
    border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.22));
    border-radius: 12px;
    background: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.04));
    display: grid;
    grid-template-columns: 34px minmax(0, 1fr);
    gap: 10px 12px;
    align-content: start;
    transition: border-color 0.18s ease, box-shadow 0.18s ease;
}

.tachyon_diagnostic_alert:hover {
    box-shadow: 0 6px 16px -6px rgba(0, 0, 0, 0.22);
}

.tachyon_diagnostic_alert__icon {
    width: 34px;
    height: 34px;
    border-radius: 9px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: rgba(148, 163, 184, 0.12);
    color: var(--tachyon-text-secondary, inherit);
}

.tachyon_diagnostic_alert__content {
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 2px;
    min-width: 0;
}

.tachyon_diagnostic_alert__title {
    display: block;
    font-size: 13.5px;
    font-weight: 700;
    color: var(--tachyon-text-main, inherit);
    line-height: 1.25;
}

.tachyon_diagnostic_alert__description {
    font-size: 11.5px;
    font-weight: 500;
    color: var(--tachyon-text-muted, #94a3b8);
    line-height: 1.35;
}

.tachyon_diagnostic_alert__summary {
    grid-column: 1 / -1;
    display: flex;
    flex-direction: column;
    gap: 5px;
    margin-top: 2px;
    padding-top: 8px;
    border-top: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));
}

.tachyon_diagnostic_alert__summary:empty {
    display: none;
    padding-top: 0;
    border-top: none;
}

.tachyon_diagnostic_alert__summary__item {
    display: grid;
    grid-template-columns: 18px minmax(0, 1fr) auto;
    gap: 8px;
    align-items: center;
    font-size: 11.5px;
    padding: 4px 8px;
    border-radius: 7px;
    background: rgba(15, 23, 42, 0.18);
}

.tachyon_diagnostic_alert__summary__item b {
    font-weight: 600;
    color: var(--tachyon-text-secondary, inherit);
    overflow: hidden;
    text-overflow: ellipsis;
}

.tachyon_diagnostic_alert__summary__item > div {
    font-family: var(--tachyon-font-mono, monospace);
    font-size: 11px;
    color: var(--tachyon-text-muted, #94a3b8);
    text-align: right;
}

.tachyon_diagnostic_alert__summary__item__icon {
    width: 16px;
    height: 16px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon_diagnostic_alert__summary__item--error {
    color: var(--tachyon-danger, var(--error-color-medium, #ef4444));
}

.tachyon_diagnostic_alert__summary__item--warning {
    color: var(--tachyon-warning, var(--warn-color-medium, #f59e0b));
}

.tachyon_diagnostic_alert__summary__item--success {
    color: var(--tachyon-success, var(--success-color-medium, #10b981));
}

.tachyon_diagnostic_alert--loading {
    border-color: rgba(99, 102, 241, 0.38);
    background: linear-gradient(145deg, rgba(99, 102, 241, 0.08), rgba(148, 163, 184, 0.03));
}

.tachyon_diagnostic_alert--loading .tachyon_diagnostic_alert__icon {
    background: rgba(99, 102, 241, 0.16);
    color: var(--tachyon-accent, #6366f1);
}

.tachyon_diagnostic_alert--warning {
    border-color: var(--tachyon-warning-border, rgba(245, 158, 11, 0.45));
    background: linear-gradient(145deg, var(--tachyon-warning-soft, rgba(245, 158, 11, 0.1)), rgba(148, 163, 184, 0.03));
}

.tachyon_diagnostic_alert--warning .tachyon_diagnostic_alert__icon {
    background: var(--tachyon-warning-soft, rgba(245, 158, 11, 0.18));
    color: var(--tachyon-warning-text, #f59e0b);
}

.tachyon_diagnostic_alert--warning .tachyon_diagnostic_alert__description {
    color: var(--tachyon-warning-text, #f59e0b);
}

.tachyon_diagnostic_alert--error {
    border-color: var(--tachyon-danger-border, rgba(239, 68, 68, 0.45));
    background: linear-gradient(145deg, var(--tachyon-danger-soft, rgba(239, 68, 68, 0.1)), rgba(148, 163, 184, 0.03));
}

.tachyon_diagnostic_alert--error .tachyon_diagnostic_alert__icon {
    background: var(--tachyon-danger-soft, rgba(239, 68, 68, 0.18));
    color: var(--tachyon-danger-text, #ef4444);
}

.tachyon_diagnostic_alert--error .tachyon_diagnostic_alert__description {
    color: var(--tachyon-danger-text, #ef4444);
}

.tachyon_diagnostic_alert--success {
    border-color: var(--tachyon-success-border, rgba(16, 185, 129, 0.45));
    background: linear-gradient(145deg, var(--tachyon-success-soft, rgba(16, 185, 129, 0.1)), rgba(148, 163, 184, 0.03));
}

.tachyon_diagnostic_alert--success .tachyon_diagnostic_alert__icon {
    background: var(--tachyon-success-soft, rgba(16, 185, 129, 0.18));
    color: var(--tachyon-success-text, #10b981);
}

.tachyon_diagnostic_alert--success .tachyon_diagnostic_alert__description {
    color: var(--tachyon-success-text, #10b981);
}

.tachyon_diagnostic_alert--skipped {
    opacity: 0.85;
}

@media (max-width: 1024px) {
    .tachyon_diagnostic-page {
        grid-template-columns: 1fr;
    }
}

@media (max-width: 640px) {
    .tachyon_diagnostic-page__right-bar__wiki {
        grid-template-columns: 1fr;
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
