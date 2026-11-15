// language=CSS
export const styles = `

.tachyon-partial-modal__body {
    width: 100%;
    box-sizing: border-box;
}

.tachyon-partial-modal__content {
    max-height: 75vh;
    overflow-y: auto;
    /* Log lines, stack traces and long single-token output have no spaces to wrap
       at. Under the default pre formatting combined with overflow-x: hidden the
       tail of such a line was clipped with no way to scroll to it, so the error
       that mattered sat just past the right edge of the dialog. */
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    border-radius: 10px;
    padding: 12px 14px;
    margin: 4px 0 12px 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 12px;
    line-height: 1.5;
    background: var(--background-color-low, rgba(15, 23, 42, 0.05));
    border: 1px solid var(--border-color-medium, rgba(128, 128, 128, 0.2));
    box-sizing: border-box;
    width: 100%;
}

.tachyon-partial-modal__footer {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    padding-top: 12px;
    border-top: 1px solid var(--border-color-low, rgba(128, 128, 128, 0.16));
}

.tachyon-partial-modal__footer button {
    margin-left: 0;
}

.tachyon-partial-modal__checkbox {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin-right: auto;
    cursor: pointer;
    user-select: none;
}

.tachyon-partial-modal__checkbox-text {
    line-height: 1.2;
}

@media (max-width: 640px) {
    .tachyon-partial-modal__content {
        max-height: 82vh;
    }
    .tachyon-partial-modal__footer {
        flex-direction: column-reverse;
        align-items: stretch;
    }
    .tachyon-partial-modal__footer button {
        width: 100%;
        min-height: 38px;
    }
    .tachyon-partial-modal__checkbox {
        margin-right: 0;
        margin-bottom: 6px;
        width: 100%;
    }
}
`;
