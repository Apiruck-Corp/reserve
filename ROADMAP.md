# Roadmap
Last updated: 2026-10-18

## Now

- 2026-10-18: Fix Anthropic API key validation and check what TypeSafe information is available to add. PR #67 adds ordinary-key validation, richer TypeSafe details, and native replacement/error-label regression tests. Build 1056.4 completed Keychain access and its live Models API error identifies workspace context, API key and request header. Workspace recovery previously depended on the exact words "is required"; it now recognizes an explicit reference to an absent workspace header and cannot restart discovery after supplying it. Organization requests follow the Admin API guide's x-api-key form. Current errors override stale readings and replacing a key clears previous validation. All 379 unit tests and the latest native refresh-reliability check pass. Build 1056.5 is installed and running on the MBA, package/signature/binary verified, with the previous app backed up. Live verification is waiting for the updated build's Keychain prompt. Earlier 43 domain checks and native UI/lifecycle/connections/stress gates passed. Billing remains unverified. Awaiting review and merge.

## Next

## Later

## Done
