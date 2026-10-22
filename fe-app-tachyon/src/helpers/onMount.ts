function getTarget(target: string | HTMLElement): HTMLElement | null {
  if (typeof target === 'string') {
    return document.getElementById(target);
  }

  return target;
}

export async function onMount(
  target: string | HTMLElement,
): Promise<HTMLElement> {
  return new Promise((resolve) => {
    let observer: MutationObserver | null = null;
    let watchingAncestors = false;

    const observeAncestors = (el: HTMLElement) => {
      if (!observer || watchingAncestors) {
        return;
      }
      watchingAncestors = true;
      observer.disconnect();
      let curr: HTMLElement | null = el;
      while (curr && curr !== document.body) {
        observer.observe(curr, {
          attributes: true,
          attributeFilter: ['class', 'style', 'hidden'],
        });
        curr = curr.parentElement;
      }
    };

    const resolveIfMountedAndVisible = () => {
      const mountedTarget = getTarget(target);
      if (!mountedTarget || !mountedTarget.isConnected) {
        return false;
      }

      if (mountedTarget.offsetParent !== null) {
        observer?.disconnect();
        resolve(mountedTarget);
        return true;
      }

      observeAncestors(mountedTarget);
      return false;
    };

    if (resolveIfMountedAndVisible()) {
      return;
    }

    observer = new MutationObserver(() => {
      resolveIfMountedAndVisible();
    });

    const initialTarget = getTarget(target);
    if (initialTarget && initialTarget.isConnected) {
      observeAncestors(initialTarget);
    } else {
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class', 'style', 'hidden'],
      });
    }
  });
}
