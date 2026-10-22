type TabInfo = {
  el: HTMLElement;
  id: string;
  active: boolean;
};

type TabChangeCallback = (activeId: string | null, allTabs: TabInfo[]) => void;

class TabService {
  private static instance: TabService;
  private observer: MutationObserver | null = null;
  private callback?: TabChangeCallback;
  private lastActiveId: string | null = null;

  private constructor() {
    this.init();
  }

  public static getInstance(): TabService {
    if (!TabService.instance) {
      TabService.instance = new TabService();
    }
    return TabService.instance;
  }

  private init() {
    this.observer = new MutationObserver((mutations) =>
      this.handleMutations(mutations),
    );
    this.observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });

    this.notify();
  }

  private isTabMutation(mutations: MutationRecord[]): boolean {
    for (const m of mutations) {
      if (m.type === 'attributes') {
        const el = m.target as HTMLElement;
        if (
          el.dataset?.tab !== undefined ||
          el.classList?.contains('cbi-tab') ||
          el.classList?.contains('cbi-tab-disabled')
        ) {
          return true;
        }
        continue;
      }
      for (let i = 0; i < m.addedNodes.length; i++) {
        const node = m.addedNodes[i];
        if (
          node instanceof HTMLElement &&
          (node.dataset?.tab !== undefined ||
            node.classList?.contains('cbi-tab') ||
            node.classList?.contains('cbi-tab-disabled') ||
            node.querySelector?.('.cbi-tab, .cbi-tab-disabled') !== null)
        ) {
          return true;
        }
      }
    }
    return false;
  }

  private handleMutations(mutations: MutationRecord[]) {
    if (!this.isTabMutation(mutations)) {
      return;
    }
    this.notify();
  }

  private cleanTabId(tab: string | null | undefined): string | null {
    if (!tab) return null;
    return tab.replace(/^(?:cbi-tachyon-|tab-)/, '');
  }

  private getTabsInfo(): TabInfo[] {
    const tabs = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab, .cbi-tab-disabled'),
    );
    return tabs.map((el) => ({
      el,
      id: this.cleanTabId(el.dataset.tab) || '',
      active:
        el.classList.contains('cbi-tab') &&
        !el.classList.contains('cbi-tab-disabled'),
    }));
  }

  private getActiveTabId(): string | null {
    const active = document.querySelector<HTMLElement>(
      '.cbi-tab:not(.cbi-tab-disabled)',
    );
    return this.cleanTabId(active?.dataset.tab);
  }

  private notify() {
    const tabs = this.getTabsInfo();
    const activeId = this.getActiveTabId();

    if (activeId !== this.lastActiveId) {
      this.lastActiveId = activeId;
      this.callback?.(activeId, tabs);
    }
  }

  public onChange(callback: TabChangeCallback) {
    this.callback = callback;
    this.notify();
  }
}

export const TabServiceInstance = TabService.getInstance();
