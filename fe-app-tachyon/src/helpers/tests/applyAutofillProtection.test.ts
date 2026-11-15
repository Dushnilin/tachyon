/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  function createField(tag: string) {
    const attrs: Record<string, string> = {};
    return {
      nodeType: 1,
      tagName: tag.toUpperCase(),
      attrs,
      setAttribute(name: string, value: string) {
        attrs[name] = value;
      },
      getAttribute(name: string) {
        return attrs[name] ?? null;
      },
      matches(selector: string) {
        return selector
          .split(',')
          .map((s) => s.trim())
          .includes(tag);
      },
      querySelectorAll: () => [],
    };
  }

  function createContainer(fields: any[]) {
    return {
      nodeType: 1,
      matches: () => false,
      setAttribute() {},
      querySelectorAll: (selector: string) =>
        fields.filter((f) => f.matches(selector)),
    };
  }

  class MockMutationObserver {
    static instances: MockMutationObserver[] = [];
    callback: any;
    observed: any[] = [];

    constructor(callback: any) {
      this.callback = callback;
      MockMutationObserver.instances.push(this);
    }

    observe(target: any, options: any) {
      this.observed.push({ target, options });
    }

    disconnect() {}

    trigger(addedNodes: any[]) {
      this.callback([{ addedNodes }], this);
    }
  }

  return { createField, createContainer, MockMutationObserver };
});

const { createField, createContainer, MockMutationObserver } = mocks;

async function loadHelper(body: any) {
  vi.resetModules();
  (globalThis as any).document = { body };
  (globalThis as any).MutationObserver = MockMutationObserver;
  return await import('../applyAutofillProtection');
}

const PROTECTED = {
  autocomplete: 'off',
  autocorrect: 'off',
  autocapitalize: 'off',
  spellcheck: 'false',
};

function expectProtected(field: any) {
  for (const [name, value] of Object.entries(PROTECTED))
    expect(field.getAttribute(name), name).toBe(value);
}

describe('applyAutofillProtection', () => {
  beforeEach(() => {
    MockMutationObserver.instances.length = 0;
  });

  it('marks the fields already on the page', async () => {
    const textField = createField('input');
    const passwordField = createField('input');
    const body = createContainer([textField, passwordField]);

    const { applyAutofillProtection } = await loadHelper(body);
    applyAutofillProtection();

    expectProtected(textField);
    expectProtected(passwordField);
  });

  it('observes the body for fields created later', async () => {
    const body = createContainer([]);

    const { applyAutofillProtection } = await loadHelper(body);
    applyAutofillProtection();

    const observer = MockMutationObserver.instances[0];
    expect(observer).toBeDefined();
    expect(observer.observed[0].target).toBe(body);
    expect(observer.observed[0].options).toEqual({
      childList: true,
      subtree: true,
    });

    // A modal opened after the view was rendered contributes its own inputs.
    const modalField = createField('textarea');
    observer.trigger([createContainer([modalField]), modalField]);

    expectProtected(modalField);
  });

  it('stays a single observer across repeated renders', async () => {
    const body = createContainer([]);

    const { applyAutofillProtection } = await loadHelper(body);
    applyAutofillProtection();
    applyAutofillProtection();

    expect(MockMutationObserver.instances).toHaveLength(1);
  });

  it('does not throw when the body is missing', async () => {
    const { applyAutofillProtection } = await loadHelper(null);

    expect(() => applyAutofillProtection()).not.toThrow();
    expect(MockMutationObserver.instances).toHaveLength(1);
  });
});
