/* eslint-disable @typescript-eslint/no-explicit-any */
type HtmlTag = keyof HTMLElementTagNameMap;

type HtmlElement<T extends HtmlTag> = HTMLElementTagNameMap[T];

type HtmlAttributes<T extends HtmlTag = 'div'> = Partial<
  Omit<HtmlElement<T>, 'style' | 'children' | 'click' | 'disabled'> & {
    style?: string | Partial<CSSStyleDeclaration>;
    class?: string;
    disabled?: boolean | string | null;
    'aria-busy'?: string;
    'aria-checked'?: string;
    'aria-disabled'?: string;
    'aria-label'?: string;
    'data-sid'?: string;
    'data-slot-idx'?: string;
    'data-latency-section'?: string;
    'data-client-ip'?: string;
    'data-client-name'?: string;
    'data-domain'?: string;
    'data-system-view'?: string;
    'data-services-view'?: string;
    'data-clients-view'?: string;
    'data-kpi'?: string;
    'data-chart-view'?: string;
    'data-dashboard-preset'?: string;
    click?: (event: MouseEvent) => void;
    onclick?: (event: MouseEvent) => void;
    input?: (event: Event) => void;
    change?: (event: Event) => void;
    error?: (event: Event) => void;
    mouseenter?: (event: MouseEvent) => void;
    mouseleave?: (event: MouseEvent) => void;
  }
>;

declare global {
  const fs: {
    read(path: string): Promise<string>;
    write(path: string, data: string): Promise<void>;
    remove(path: string): Promise<void>;
    exec(
      command: string,
      args?: string[],
      env?: Record<string, string>,
    ): Promise<{
      stdout: string;
      stderr: string;
      code?: number;
    }>;
  };

  const E: <T extends HtmlTag>(
    type: T,
    attr?: HtmlAttributes<T> | null,
    children?: (Node | string)[] | Node | string,
  ) => HTMLElementTagNameMap[T];

  const uci: {
    load: (packages: string | string[]) => Promise<string>;
    unload?: (packages: string | string[]) => void;
    sections: <_T = any>(conf: string, type?: string, cb?: () => void) => any;
    get: (conf: string, sec: string, opt?: string) => any;
    set: (conf: string, sec: string, opt: string, val: any) => void;
    unset?: (conf: string, sec: string, opt: string) => void;
    add: (conf: string, type: string, name?: string) => string;
    remove?: (conf: string, sec: string) => void;
    save: () => Promise<unknown>;
  };

  const _: (_key: string) => string;

  const ui: {
    showModal: (
      _title: string | Node | null,
      _content: HTMLElement | Node[],
      ..._classes: string[]
    ) => HTMLElement;
    hideModal: () => void;
    addNotification: (
      _title: string | null,
      _children: HtmlElement | HtmlElement[] | Node,
      ..._classNames: string[]
    ) => HTMLElement;
    addValidator?: (..._args: unknown[]) => void;
    changes?: {
      apply: (_checked?: boolean) => Promise<unknown>;
    };
    DynamicList?: new (
      _values: string[],
      _choices: Record<string, string>,
      _opts: Record<string, unknown>,
    ) => {
      render: () => HTMLElement;
      clearChoices: () => void;
      addChoices: (_keys: string[], _choices: Record<string, string>) => void;
    };
  };

  const baseclass: {
    extend: <T extends Record<string, unknown>>(_proto: T) => T;
  };

  const view: {
    extend: <T extends Record<string, unknown>>(_proto: T) => T;
  };

  const form: Record<string, any>;
  const rpc: {
    declare: <T = (..._args: any[]) => Promise<any>>(
      _spec: Record<string, unknown>,
    ) => T;
  };
  const dom: Record<string, any>;
  const network: Record<string, any>;
  const widgets: Record<string, any>;
}

export {};
