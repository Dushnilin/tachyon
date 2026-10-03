import { describe, expect, it } from 'vitest';
import { styles } from '../styles';

/**
 * The log dialog wraps its output in <pre class="tachyon-partial-modal__content">.
 * Under the default pre formatting plus overflow-x: hidden, a line with no spaces
 * to wrap at - a stack trace, a single long token, a base64 blob - was clipped at
 * the right edge of the dialog with no way to scroll to the tail. The interesting
 * part of the error sat exactly where the user could not see it.
 *
 * This asserts against the real stylesheet export, not a copy of it, so it fails
 * if the rule is ever reverted.
 */
describe('modal content styles', () => {
  // Comments are stripped first: prose about the old rule must never satisfy or
  // break a declaration assertion.
  const rule = () => {
    const declarations = styles.replace(/\/\*[\s\S]*?\*\//g, '');
    const start = declarations.indexOf('.tachyon-partial-modal__content {');
    expect(start).toBeGreaterThan(-1);
    return declarations.slice(start, declarations.indexOf('}', start));
  };

  it('wraps long unbroken lines instead of clipping them', () => {
    const content = rule();

    expect(content).toMatch(/white-space:\s*pre-wrap/);
    expect(content).toMatch(/overflow-wrap:\s*anywhere/);
  });

  it('does not clip the horizontal axis', () => {
    expect(rule()).not.toMatch(/overflow-x:\s*hidden/);
  });

  it('keeps vertical scrolling for long logs', () => {
    expect(rule()).toMatch(/overflow-y:\s*auto/);
  });
});
