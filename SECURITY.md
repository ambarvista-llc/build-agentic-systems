# Security Policy

Security is a first-class concern in this project, and reports are welcome.

## Reporting a vulnerability

**Please do not open a public issue, pull request, or comment for security problems.**

Report privately through GitHub's private vulnerability reporting:
**Security tab → Report a vulnerability** on this repository.

Include what you found, how to reproduce it, and the impact you expect. You'll get an acknowledgment, and we'll keep you updated until it's resolved. Credit is given in the fix unless you prefer to stay anonymous.

## Supported versions

The project is pre-release. Only the latest commit on `main` is supported.

## Scope

In scope:

- Code in this repository (pipeline, renderer, review app, infrastructure code)
- Workflows and configuration in `.github/`
- Prompt-injection paths: any way content from outside the allowlist (comments, fetched pages, source documents, model output) can make an agent take an action

Out of scope:

- Vulnerabilities in third-party dependencies with no exploitable path in this project (report those upstream)
- Findings that require physical access to the maintainer's machine
