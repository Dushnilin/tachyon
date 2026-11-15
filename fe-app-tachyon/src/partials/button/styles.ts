// language=CSS
export const styles = `
.tachyon-partial-button {
    text-align: center;
    white-space: normal !important;
    word-break: normal !important;
    overflow-wrap: break-word !important;
    line-height: 1.3 !important;
    height: auto !important;
    box-sizing: border-box !important;
}

.tachyon-partial-button > span {
    min-width: 0;
}

.tachyon-partial-button--with-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
}

.tachyon-partial-button--loading {
}

.tachyon-partial-button--disabled {
}

.tachyon-partial-button__icon {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.tachyon-partial-button__icon svg {
    width: 16px;
    height: 16px;
    display: block;
    flex: 0 0 auto;
}
`;
