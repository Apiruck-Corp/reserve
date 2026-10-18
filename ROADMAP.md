# Roadmap
Last updated: 2026-10-18

## Now

- 2026-10-18: Fix Anthropic API key validation and check what TypeSafe information is available to add. PR #67 adds ordinary-key validation, richer TypeSafe details, and native replacement/error-label regression tests. Local test build 1.9.0 (1056.2) is installed. Investigation found a fresh HTTP 400 hidden by an older "Key valid" heading. Added bounded recovery for Anthropic's documented missing workspace-context response, endpoint-specific errors, current-error priority, and clearing previous validation on replacement. Workspace context does not filter organization spend. Live billing remains unverified while the next build is validated. Awaiting review and merge.

## Next

## Later

## Done
