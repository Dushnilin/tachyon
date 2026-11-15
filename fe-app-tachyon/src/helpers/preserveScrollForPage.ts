let lastUserScrollTime = 0;
let isProgrammaticScroll = false;
let activeRenderCount = 0;
let userScrollListenersAttached = false;
let activeDocLocks = 0;
let footstrapAnchorOverridden = false;
let previousFootstrapAnchor: string | null = null;
let previousFootstrapFit: string | null = null;
const containerLockCounts = new WeakMap<HTMLElement, number>();

function clearFootstrapFloorLocks() {
  try {
    if (typeof document === 'undefined') {
      return;
    }
    if (document.documentElement?.dataset) {
      delete document.documentElement.dataset.fsFit;
    }
    if (typeof document.querySelectorAll === 'function') {
      const floorNodes =
        document.querySelectorAll<HTMLElement>('[data-fs-floor]');
      floorNodes.forEach((node) => {
        if (node?.style) {
          node.style.minHeight = '';
        }
        node?.removeAttribute?.('data-fs-floor');
      });
    }
  } catch {
    // ignore DOM errors
  }
}

function disableFootstrapScrollAnchor() {
  try {
    clearFootstrapFloorLocks();
    if (typeof localStorage === 'undefined') {
      return;
    }
    if (!footstrapAnchorOverridden) {
      previousFootstrapAnchor = localStorage.getItem('fsAnchor');
      previousFootstrapFit = localStorage.getItem('fsFit');
      footstrapAnchorOverridden = true;
    }
    if (previousFootstrapAnchor !== 'off') {
      localStorage.setItem('fsAnchor', 'off');
    }
    if (previousFootstrapFit !== 'off') {
      localStorage.setItem('fsFit', 'off');
    }
  } catch {
    // ignore storage errors
  }
}

function restoreFootstrapScrollAnchor() {
  try {
    if (!footstrapAnchorOverridden || typeof localStorage === 'undefined') {
      return;
    }
    if (previousFootstrapAnchor === null) {
      localStorage.removeItem('fsAnchor');
    } else {
      localStorage.setItem('fsAnchor', previousFootstrapAnchor);
    }
    if (previousFootstrapFit === null) {
      localStorage.removeItem('fsFit');
    } else {
      localStorage.setItem('fsFit', previousFootstrapFit);
    }
    footstrapAnchorOverridden = false;
    previousFootstrapAnchor = null;
    previousFootstrapFit = null;
  } catch {
    // ignore storage errors
  }
}

export function ensureUserScrollTracking() {
  if (userScrollListenersAttached || typeof window === 'undefined') {
    return;
  }
  userScrollListenersAttached = true;
  disableFootstrapScrollAnchor();

  const onUserInteraction = (e: Event) => {
    if (
      e.type === 'scroll' &&
      (isProgrammaticScroll || activeRenderCount > 0)
    ) {
      return;
    }
    lastUserScrollTime = Date.now();
  };

  window.addEventListener('wheel', onUserInteraction, {
    passive: true,
    capture: true,
  });
  window.addEventListener('touchstart', onUserInteraction, {
    passive: true,
    capture: true,
  });
  window.addEventListener('touchmove', onUserInteraction, {
    passive: true,
    capture: true,
  });
  window.addEventListener('touchend', onUserInteraction, {
    passive: true,
    capture: true,
  });
  window.addEventListener('scroll', onUserInteraction, {
    passive: true,
    capture: true,
  });
  window.addEventListener(
    'pagehide',
    () => {
      restoreFootstrapScrollAnchor();
    },
    { passive: true },
  );
  window.addEventListener(
    'pageshow',
    () => {
      disableFootstrapScrollAnchor();
    },
    { passive: true },
  );
  window.addEventListener(
    'keydown',
    (e: KeyboardEvent) => {
      if (
        [
          'ArrowUp',
          'ArrowDown',
          'PageUp',
          'PageDown',
          'Home',
          'End',
          ' ',
        ].includes(e.key)
      ) {
        lastUserScrollTime = Date.now();
      }
    },
    { passive: true, capture: true },
  );
}

if (typeof window !== 'undefined') {
  ensureUserScrollTracking();
}

export function _resetUserScrollTrackingForTest() {
  restoreFootstrapScrollAnchor();
  userScrollListenersAttached = false;
  lastUserScrollTime = 0;
  isProgrammaticScroll = false;
  activeRenderCount = 0;
  activeDocLocks = 0;
}

export function isUserActivelyScrolling(thresholdMs = 1200): boolean {
  return Date.now() - lastUserScrollTime < thresholdMs;
}

const scheduleFrame = (cb: () => void) => {
  if (typeof requestAnimationFrame !== 'undefined') {
    return requestAnimationFrame(cb);
  }
  return setTimeout(cb, 16);
};

function isContainerScroller(el: HTMLElement): boolean {
  if (el.scrollTop > 0) {
    return true;
  }
  try {
    if (
      typeof window !== 'undefined' &&
      typeof window.getComputedStyle === 'function'
    ) {
      const overflowY = window.getComputedStyle(el)?.overflowY;
      if (
        overflowY === 'auto' ||
        overflowY === 'scroll' ||
        overflowY === 'overlay'
      ) {
        return true;
      }
    }
  } catch {
    // ignore style errors
  }
  return false;
}

function getScrollPosition(): {
  target: Window | HTMLElement | null;
  top: number;
} {
  if (typeof window === 'undefined') {
    return { target: null, top: 0 };
  }
  const mainContent =
    typeof document !== 'undefined' &&
    typeof document.getElementById === 'function'
      ? document.getElementById('maincontent')
      : null;
  if (mainContent && mainContent.scrollTop > 0) {
    return { target: mainContent, top: mainContent.scrollTop };
  }
  const winTop =
    window.scrollY ??
    window.pageYOffset ??
    document.documentElement?.scrollTop ??
    0;
  if (winTop > 0 || !mainContent) {
    return { target: window, top: winTop };
  }
  if (isContainerScroller(mainContent)) {
    return { target: mainContent, top: mainContent.scrollTop || 0 };
  }
  return { target: window, top: 0 };
}

export function preserveScrollForPage(
  renderFn: () => void,
  targetContainer?: HTMLElement | null,
) {
  ensureUserScrollTracking();
  clearFootstrapFloorLocks();

  const pos = getScrollPosition();
  const scrollTimeAtStart = lastUserScrollTime;

  const isFootstrapShell =
    typeof document !== 'undefined' &&
    typeof document.querySelector === 'function' &&
    Boolean(document.querySelector('.fs-shell, .fs-main'));

  // Only lock documentElement height when window itself is the scrolling element.
  // In container-scrolling themes (e.g. Footstrap's #maincontent) or when Footstrap's
  // .fs-shell flex wrapper is active and targetContainer is already height-locked,
  // setting minHeight on <html> causes layout distortion and reflow loops.
  const isWindowScroll =
    pos.target === (typeof window !== 'undefined' ? window : null);
  const root =
    isWindowScroll &&
    !(isFootstrapShell && targetContainer) &&
    typeof document !== 'undefined'
      ? document.documentElement
      : null;
  const prevDocHeight = root ? root.scrollHeight : 0;
  if (root && prevDocHeight > 0 && root.style) {
    activeDocLocks += 1;
    root.style.minHeight = `${prevDocHeight}px`;
  }

  if (targetContainer) {
    const currentCount = containerLockCounts.get(targetContainer) || 0;
    containerLockCounts.set(targetContainer, currentCount + 1);
    const containerHeight = targetContainer.offsetHeight || 0;
    if (containerHeight > 0 && targetContainer.style) {
      targetContainer.style.minHeight = `${containerHeight}px`;
    }
  }

  const restoreClampedScrollIfNeeded = () => {
    if (typeof window === 'undefined' || !pos.target) {
      return;
    }

    // If the user has scrolled or interacted recently, do not fight the user's scroll gesture.
    if (
      lastUserScrollTime !== scrollTimeAtStart ||
      isUserActivelyScrolling(1200)
    ) {
      return;
    }

    const currentPos = getScrollPosition();

    // Only restore if layout shift caused the scroll position to jump downward (clamped).
    // Do NOT pull the user back if they scrolled further down (currentPos.top >= pos.top).
    // Layout shift typically collapses scroll downward (currentPos.top < pos.top).
    const hasClampedShift =
      pos.top > 0 && currentPos.top < pos.top && pos.top - currentPos.top > 2;

    if (hasClampedShift) {
      isProgrammaticScroll = true;
      if (pos.target === window) {
        window.scrollTo({ top: pos.top });
      } else if ('scrollTop' in pos.target) {
        (pos.target as HTMLElement).scrollTop = pos.top;
      }
      scheduleFrame(() => {
        isProgrammaticScroll = false;
      });
    }
  };

  activeRenderCount += 1;
  try {
    renderFn();
    restoreClampedScrollIfNeeded();
  } finally {
    scheduleFrame(() => {
      activeRenderCount = Math.max(0, activeRenderCount - 1);

      if (targetContainer) {
        const remainingCount =
          (containerLockCounts.get(targetContainer) || 1) - 1;
        if (remainingCount <= 0) {
          containerLockCounts.delete(targetContainer);
          if (targetContainer.style) {
            targetContainer.style.minHeight = '';
          }
        } else {
          containerLockCounts.set(targetContainer, remainingCount);
        }
      }

      if (root) {
        activeDocLocks = Math.max(0, activeDocLocks - 1);
        if (activeDocLocks === 0 && root.style) {
          root.style.minHeight = '';
        }
      }

      restoreClampedScrollIfNeeded();
    });
  }
}
