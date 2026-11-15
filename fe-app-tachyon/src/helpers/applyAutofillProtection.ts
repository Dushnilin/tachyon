// Browsers with a built-in password manager decide that a page contains a
// login form as soon as one password input is present, and then treat the
// surrounding text inputs as usernames. Tachyon pages always carry real
// credential fields (server_password, mixed_proxy_password, openvpn_password,
// ...), so the manager was offering to store plain settings — a DNS cache size
// of "300000", a section name, a list of domains — as a saved login.
//
// The attributes below are what the managers actually read. autocomplete=off
// is honoured for the username side even where it is ignored for passwords,
// which is the half that was misfiring.
const AUTOFILL_ATTRIBUTES: Record<string, string> = {
  autocomplete: 'off',
  autocorrect: 'off',
  autocapitalize: 'off',
  spellcheck: 'false',
};

const FIELD_SELECTOR = 'input, textarea, select';

function protectField(field: Element) {
  for (const [name, value] of Object.entries(AUTOFILL_ATTRIBUTES))
    field.setAttribute(name, value);
}

// Only elements can carry fields, so text nodes handed over by the observer
// are dropped here rather than guarded at every call site.
function protectFields(root: Node | null | undefined) {
  if (!root || root.nodeType !== 1) return;

  const element = root as Element;
  if (element.matches(FIELD_SELECTOR)) protectField(element);

  for (const field of element.querySelectorAll(FIELD_SELECTOR))
    protectField(field);
}

let observer: MutationObserver | null = null;

/**
 * Marks every form field on the page as not-a-credential and keeps doing so
 * for fields created later (modals, tab switches, dynamic lists). Idempotent.
 */
export function applyAutofillProtection() {
  protectFields(document.body);

  if (observer) return;
  observer = new MutationObserver((records) => {
    for (const record of records)
      for (const node of record.addedNodes) protectFields(node);
  });
  observer.observe(document.body, { childList: true, subtree: true });
}
