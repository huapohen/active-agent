# Contributing

Active Agent is building a document-native collaboration loop with Doc Free. Current development is on `evolve`.

For changes to observation or model handling, run `python -m unittest discover -s tests -v`. For protocol or workbench changes, also run Doc Free's `npm test` and `npm run build`. Keep live model checks opt-in and record the model, reasoning effort, time, commit and observed result without credentials.

Please describe the user-visible trigger and resulting document behavior in each pull request. Explain how changes handle concurrent editing, repeated delivery, cancellation and process interruption when relevant. Keep protocol examples credential-free.

High-value contributions include reproducible collaboration failure cases, rich-text round-trip support, accessible review UX, scoped identity, and provider compatibility tests. See the dated roadmap for release gates. IM integration is outside the current scope.

Submit bug reports with reproduction steps, relevant commits, expected/actual document revisions and sanitized logs. Never include `.env`, document contents containing private information, tokens, local databases or exported browser sessions.

Contributions are licensed under the project's MIT license.
