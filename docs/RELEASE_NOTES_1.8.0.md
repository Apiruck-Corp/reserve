# Reserve 1.8.0

Adding an account now works the same way for every provider. Choose
**Add Account…** at the top of Settings > Providers or Settings > API, and pick
from subscriptions, coding plans or API spend. If that provider's first account
isn't connected yet, Reserve connects it. Otherwise it adds another one beside
it.

OpenAI (Codex) and Grok can now hold several accounts, each in its own folder,
the way Claude already did. Z.ai and Kimi can too, each with its own key.
Cursor, Copilot and Gemini keep one sign-in per Mac, and the menu says so. When
you sign in a second account, your browser may still be signed in to the first
one: switch accounts on the sign-in page.

API providers take several keys as well, for example a personal and a team
Claude API organization. Once a provider has two, you can name each one.
Removing one deletes only its key. The keys you already saved keep working.

A refused API key now tells you why: the key is invalid or revoked, it has no
access to usage data, or it isn't an admin key. Claude's Cost API needs an
admin key (sk-ant-admin…) from a Claude Console organization. Reserve never
repeats the provider's own error text, because it can quote your key.
