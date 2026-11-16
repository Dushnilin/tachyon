# Security Policy

## Supported Versions

I provide security patches only for the latest stable releases. If you are running an older version, I strongly recommend upgrading immediately.

| Version | Supported |
| ------- | --------- |
| >= 1.0.0 | Yes |
| < 1.0.0 | No |

## Reporting a Vulnerability

I take the security of Tachyon seriously. If you discover a vulnerability, **please do not open a public issue**.

Instead, report it through one of the following channels:

1. **Email:** Send details to **dushnilin@gmail.com**
2. **GitHub Private Vulnerability Reporting:** Use the built-in "Private vulnerability reporting" feature in the Security tab of this repository.

### What to include in your report

- A clear description of the vulnerability and its potential impact.
- Steps to reproduce the issue.
- Any supporting material: screenshots, logs, proof-of-concept code.

### Response timeline

- **Acknowledgment:** I will confirm receipt of your report within **48 hours**.
- **Assessment:** I aim to provide an initial assessment within **7 days**.
- **Fix:** Security patches are prioritized and released as soon as the fix is validated.

I will keep you informed throughout the process and credit you in the release notes unless you prefer to remain anonymous.

## Scope

The following are considered in scope:

- Remote code execution on the router via Tachyon.
- Authentication or authorization bypass in the LuCI web interface or Telegram bot.
- Command injection through any user-supplied input (domains, proxy URLs, subscription links, etc.).
- Path traversal leading to unauthorized file access.
- DNS rebinding or DNS manipulation exploitable through Tachyon.
- Information disclosure of sensitive configuration data (API keys, proxy credentials).

The following are **out of scope**:

- Vulnerabilities in upstream third-party projects (such as OpenWrt itself or third-party core upstreams) — report those to the respective maintainers.
- Issues that require physical access to the router.
- Denial of service through resource exhaustion from the local network only.

## Safe Harbor

I support responsible disclosure. If you make a good-faith effort to report a vulnerability in accordance with this policy, I will not take legal action against you or report your activities to law enforcement.

## Encryption

If you need to communicate sensitive information, you may encrypt your email using PGP. Contact me at **dushnilin@gmail.com** to obtain my public key.

---

Thank you for helping keep Tachyon and its users safe.
