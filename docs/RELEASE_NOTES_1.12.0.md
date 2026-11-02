# Reserve 1.12.0

I use two Claude accounts on the same Mac, a personal one and a work one. Their
limits in Reserve were right. Their token history wasn't.

Reserve only read Claude Code's default folder, `~/.claude`, and counted all of
it toward the first Claude card. A second account added in Reserve got no history
at all. And when another app runs Claude Code with its own folder (some agent
apps do), none of that work showed up anywhere. Most of my work account's usage
was simply missing.

Now each Claude folder on your Mac counts toward the account that is signed in
there. Reserve finds them by itself: your default folder, the folder of each
account you added, and any other `~/.claude…` folder signed in to the same
person in the same organization. A colleague's seat in your team never counts
for you. Reserve only reads each folder's profile to compare signed-in
identities. It never reads credentials.

The history you already have stays. A folder reached twice through a link is
counted once. If you used Reserve's status-line connection, each reading now goes
to the account the running Claude session belongs to, so one account's limits
can't briefly show on the other's card.

Nothing to set up, and no new Keychain prompt. One thing to know: a folder
follows whoever is signed in there now. If you sign a folder into another
account, its past usage moves with it.
