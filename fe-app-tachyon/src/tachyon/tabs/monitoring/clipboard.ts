export function isElementOverflowing(element: HTMLElement): boolean {
  return element.scrollWidth > element.clientWidth + 1;
}

export function getMonitoringValueOverflowElements(
  element: HTMLElement,
): HTMLElement[] {
  return [
    element,
    ...Array.from(element.querySelectorAll<HTMLElement>('*')),
  ].filter(isElementOverflowing);
}

export function getElementCopyText(
  element: HTMLElement,
  fallback: string,
): string {
  return (
    element.getAttribute('data-copy-value') || element.textContent || fallback
  );
}

export function compactMonitoringText(value: string): string {
  return value
    .replace(/\u2026/g, '')
    .trim()
    .replace(/\s+/g, '');
}

export function getMonitoringValueTextElements(
  element: HTMLElement,
): HTMLElement[] {
  const children = Array.from(element.children).filter(
    (child): child is HTMLElement => child instanceof HTMLElement,
  );

  if (children.length === 0) {
    return [element];
  }

  const textElements = children
    .flatMap(getMonitoringValueTextElements)
    .filter((child) => compactMonitoringText(getElementCopyText(child, '')));

  return textElements.length > 0 ? textElements : [element];
}

export function estimateVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const text = compactMonitoringText(getElementCopyText(element, fallbackText));

  if (!text) {
    return 0;
  }

  if (!isElementOverflowing(element)) {
    return text.length;
  }

  return Math.floor(
    (element.clientWidth / Math.max(element.scrollWidth, 1)) * text.length,
  );
}

export function getEstimatedVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const textElements = getMonitoringValueTextElements(element);

  if (textElements.length === 1 && textElements[0] === element) {
    return estimateVisibleMonitoringTextLength(element, fallbackText);
  }

  return textElements.reduce(
    (total, textElement) =>
      total + estimateVisibleMonitoringTextLength(textElement, fallbackText),
    0,
  );
}

export function isCompactTextSubsequence(
  needle: string,
  haystack: string,
): boolean {
  let haystackIndex = 0;

  for (let needleIndex = 0; needleIndex < needle.length; needleIndex += 1) {
    haystackIndex = haystack.indexOf(needle[needleIndex], haystackIndex);

    if (haystackIndex === -1) {
      return false;
    }

    haystackIndex += 1;
  }

  return true;
}

export function getSelectionValueElements(
  selection: Selection,
  rootElement?: HTMLElement | null,
): HTMLElement[] {
  const root = rootElement ?? document.getElementById('monitoring-status');
  if (!root) {
    return [];
  }

  return Array.from(
    root.querySelectorAll<HTMLElement>(
      '.tachyon_monitoring-page__value[data-copy-value]',
    ),
  ).filter((element) => {
    for (let index = 0; index < selection.rangeCount; index += 1) {
      try {
        if (selection.getRangeAt(index).intersectsNode(element)) {
          return true;
        }
      } catch (_error) {
        return false;
      }
    }

    return false;
  });
}

export function shouldCopyFullMonitoringValue(
  element: HTMLElement,
  selectedText: string,
  fullText: string,
): boolean {
  const normalizedSelectedText = selectedText.replace(/\u2026/g, '').trim();
  const normalizedFullText = fullText.trim();
  const compactSelectedText = compactMonitoringText(selectedText);
  const compactFullText = compactMonitoringText(fullText);
  const overflowElements = getMonitoringValueOverflowElements(element);
  const hasCompositeText = getMonitoringValueTextElements(element).length > 1;

  if (!normalizedSelectedText || !normalizedFullText) {
    return false;
  }

  if (normalizedSelectedText === normalizedFullText) {
    return true;
  }

  if (overflowElements.length === 0) {
    return false;
  }

  if (hasCompositeText) {
    const selectedPrefix = compactSelectedText.slice(
      0,
      Math.min(4, compactSelectedText.length),
    );

    if (
      !compactFullText.startsWith(selectedPrefix) ||
      !isCompactTextSubsequence(compactSelectedText, compactFullText)
    ) {
      return false;
    }
  } else if (!compactFullText.startsWith(compactSelectedText)) {
    return false;
  }

  const estimatedVisibleChars = getEstimatedVisibleMonitoringTextLength(
    element,
    normalizedFullText,
  );

  return compactSelectedText.length >= Math.max(4, estimatedVisibleChars - 2);
}

export function handleMonitoringValueCopy(
  event: ClipboardEvent,
  rootElement?: HTMLElement | null,
): void {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return;
  }

  const valueElements = getSelectionValueElements(selection, rootElement);
  if (valueElements.length !== 1) {
    return;
  }

  const valueElement = valueElements[0];
  const fullText =
    valueElement.getAttribute('data-copy-value') ||
    valueElement.textContent ||
    '';
  const selectedText = selection.toString();

  if (!shouldCopyFullMonitoringValue(valueElement, selectedText, fullText)) {
    return;
  }

  event.clipboardData?.setData('text/plain', fullText);
  event.preventDefault();
}
