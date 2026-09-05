# Security

The 0.2 workspace is intended for a trusted, self-hosted development environment. The bearer token grants workspace access. Display names and `actor_id` are audit labels, not cryptographically verified identities. Per-document ACLs, separate human/agent principals and multi-tenant isolation are not implemented.

The included worker can read documents and publish proposed text. It has no shell, external browsing, IM, email, deployment or transaction tools. Proposal acceptance must be explicitly requested; the worker never calls the review endpoint. Other clients holding the same workspace token can invoke that endpoint, so this is not a strong separation-of-duties system.

A document is untrusted model input. The runtime instructs the model to stay within the mission and validates output shape and exact evidence quotes. These checks do not prove semantic correctness or fully solve prompt injection. Review changes before accepting them.

Keep model credentials in ignored local `.env` files for development. For deployment, inject secrets from a managed secret store. `.env` files are excluded from Git and Docker build context. Do not expose the legacy 0.1 API without `AA_API_TOKEN`, or expose the workspace without a trusted TLS/authentication boundary.

Report a vulnerability through GitHub private vulnerability reporting when available. If unavailable, open a public issue containing only a request for a private reporting channel; do not post an exploit or any credentials. Maintainers should arrange a private channel before details are shared. No security-response SLA is promised for this preview.
