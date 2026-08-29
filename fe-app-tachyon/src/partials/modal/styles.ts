// language=CSS
export const styles = `

.tachyon-partial-modal__body {
    width: 100%;
    box-sizing: border-box;
}

.tachyon-partial-modal__content {
    max-height: 75vh;
    overflow-y: auto;
    overflow-x: hidden;
    -webkit-overflow-scrolling: touch;
    border-radius: 4px;
    box-sizing: border-box;
    width: 100%;
}

.tachyon-partial-modal__footer {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
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
