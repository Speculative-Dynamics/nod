# Security Policy

Nod stores a user's private journal on-device. If you find a way to
expose that data, compromise the app, or break any of the privacy
guarantees in the [README](README.md) or at
[usenod.app/privacy](https://usenod.app/privacy), we want to know
before anyone else does.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Email [security@usenod.app](mailto:security@usenod.app) with:

- A short description of the issue.
- Steps to reproduce, or a proof-of-concept.
- What an attacker could do (impact assessment, even informal).
- Your name or handle if you want credit; we can keep it anonymous.

Alternatively, use GitHub's private
[Security Advisories](https://github.com/Speculative-Dynamics/nod/security/advisories/new)
form to file a private report.

## What happens next

- **Within 72 hours:** we acknowledge your report.
- **Within 7 days:** we confirm the issue or explain why we think it
  is not a security problem.
- **Timeline to fix:** depends on severity. Critical issues (exposure
  of user data, account takeover, remote code execution) get
  prioritized above all other work.
- **Disclosure:** we coordinate public disclosure with you. We aim
  for responsible disclosure within 90 days of confirmation, sooner
  if a fix is already shipped.

## Scope

**In scope:**
- The iOS app (`ios/`)
- The marketing website (`website/`)
- Any issue where Nod behaves differently from its privacy claims
  (data leaving the device, identifiers sent to third parties,
  anything that breaks the "nothing is collected" promise)

**Out of scope:**
- Social-engineering attacks on the maintainers
- Physical attacks on a user's device
- Issues in third-party dependencies that we forward upstream
- Vulnerabilities requiring a jailbroken device

## Recognition

We are a small indie project and cannot offer a bug bounty. We will
credit you in the release notes for the fix (with your permission)
and in the [`CHANGELOG.md`](CHANGELOG.md).

Thank you for helping keep Nod users safe.
