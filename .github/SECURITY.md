# Security policy

## Scope and support

This repository is a synthetic Azure infrastructure proof of concept, not a
production service. Security review and fixes target the latest default-branch
revision on a best-effort basis; there is no support SLA.

Known sample limitations include unauthenticated synthetic API responses, private
HTTP between APIM and AKS, and no persistent-data recovery strategy. Review the
[project limitations](../README.md#poc-only-concessions) before deploying.

## Reporting a vulnerability

Use the repository's **Security -> Report a vulnerability** option when private
vulnerability reporting is enabled. Do not put credentials, live endpoints,
customer information, or exploitable details in public issues or pull requests.

If that option is unavailable, use a verified private contact supplied by the
maintainer. Do not assume a private channel exists or publish sensitive details
as a fallback. Maintainers must enable private vulnerability reporting or supply
a verified private reporting channel before publication.

Include affected files/revision, impact, and minimal reproduction steps with
synthetic values. Do not test against another person's Azure deployment without
explicit authorization.

## Credentials and deployment data

- Never commit local `.azure` settings/plans/history, environment files,
  kubeconfigs, private keys, tokens, or real deployment reports.
- Use placeholders in documentation and OIDC for approved GitHub deployments;
  do not introduce client secrets into workflows.
- Review staged files and, when importing a repository, its complete history.
  `.gitignore` does not untrack files or purge earlier commits.
- Revoke/rotate exposed credentials immediately. Removing a file or making a
  repository private again is not sufficient remediation.
- Enable GitHub secret scanning and push protection where available. Static
  checks and ignore rules do not guarantee that all secrets will be detected.
