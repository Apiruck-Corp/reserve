# Reserve 1.11.0

Share usage used to be a list of limits next to two boxes that said
"Unavailable". Reserve had the data all along. The card just wasn't reading
it. It now uses the same history as the popover, so what you share matches
what you see.

The card shows each account's limits, how fast you're using them and where
you should land at reset. Below that come the period's API-price estimate,
tokens, active days, your busiest day, what caching saved, a daily chart
stacked by provider, each provider's share, the token mix and your top five
models. Pick Today, 7 days or 30 days. Today charts by hour.

Nothing on the card is empty. A period without usage, an account without a
readable limit, or a provider share when only one provider was used is left
off. You won't see a $0 or "Unknown". The API-price estimate keeps the 1.10.1
rule: it counts only providers with a known price, and the card says it isn't
an actual charge.

The card is made to be posted. Accounts show up under the provider name only.
Emails, organizations, file paths and errors never reach it. Plan names come
from a known list, and a model name is kept only when it's made of public
product names. Anything else, like a fine-tuned model ID, is counted under
"other models".

You can narrow the card to one provider and switch off the limits, the
estimate or the models. Then copy the text, copy the image or save it.
