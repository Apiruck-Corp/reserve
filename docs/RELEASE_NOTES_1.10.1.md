# Reserve 1.10.1

Click the menu bar icon and you now see your usage next to your limits. The
window is wider to make room. The new column covers Today, 7 days or 30 days:
total tokens, a trend, each provider's share, the mix of input, cached, cache
write and output tokens, what caching saved, and your top models. It also says
how fresh it is, for example "updated 3 min ago".

I held every number in it to one rule: if Reserve can't back a figure, it
doesn't show it. The API-price estimate counts only providers with a known
price for every day you used them. Cursor and Codex have none today, so they're
named under the total instead of counted as $0. When only some days recorded
token types, the token mix says so.

Insights follows the same rule. It lists only the providers and sources that
have data in the period you picked, and Cost is off when nothing has a price.
On the heatmap, an outlined cell is a day with no data, not a day with zero.
Today shows the real hourly activity from the Claude and Codex logs on this
Mac, with token types and models, and the charts scale to the period.

Usage history comes from this Mac's logs, plus the daily totals Codex and
Cursor report for your whole account. Limits were already account-wide.

TypeSafe is gone. It reported no usage and no spend, so it didn't earn its
place. Reserve deletes its saved key from your Keychain at launch.

A personal Claude account and a Team account no longer mix limits or token
history. Two Claude cards on the same organization ask you to sign in to the
other one instead of showing the same quota twice. Team plans show model
limits such as Fable, and plan limits still appear when Anthropic leaves out
the weekly window.

A working Anthropic API key without spend access now reads "Key works · spend
unavailable", with one short line instead of a wall of text.

Settings is an ordinary window again and no longer stays in front of other
apps. Settings and Insights follow the appearance you chose.

Local history can grow larger before it hits its storage limit, its errors say
what went wrong, and it no longer claims to be gathering after a failure. Older
caches get their missing model names back where the logs allow it.
