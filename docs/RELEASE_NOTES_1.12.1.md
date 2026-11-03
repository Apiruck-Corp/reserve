# Reserve 1.12.1

Someone installed Reserve and couldn't sign in to Claude. The window said
Reserve "could not verify your sign-in", and trying again changed nothing.

Reserve signs in to Claude through Claude Code, and Claude Code versions
before 2.1.79 refuse the sign-in command before any browser opens. A Mac often
keeps an old copy around, say from npm, next to a current one, and Reserve
could pick the old one first. Reserve now checks each copy's version and signs
in with one that is new enough. If every copy is too old, it says which version
it found and offers Update and continue.

You also hear about it sooner. When Claude has no sign-in and Claude Code is
missing or too old, the Providers list says Install needed or Update needed,
and the card tells you what to install, before you click anything.

While checking this I found that Install and continue had stopped working for
Claude and Codex. Their official install addresses now forward to a separate
download address, and Reserve refused to follow. It now follows the forward,
but only to Anthropic's and OpenAI's own domains. The install also gets ten
minutes instead of three, because Claude Code is a large download on a slow
connection. Once it's installed on a Mac that had no Claude sign-in, the
sign-in page opens straight away.

Two smaller things. If you only have the Claude desktop app, Reserve finds the
Claude Code bundled inside it again. And when a sign-in fails, the window now
shows Claude Code's own error, so you know what went wrong.
