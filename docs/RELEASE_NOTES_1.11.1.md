# Reserve 1.11.1

I installed Reserve on a new Mac and couldn't connect Codex. Codex was signed
in. Reserve just couldn't start it.

That Mac had Codex from npm, which is a small script that needs Node to run.
When you open Reserve from the Dock or Finder, macOS hands it only the system
folders to search, and Node is never in them. So Codex quit before saying a
word, the card read "Provider process closed unexpectedly", and Connect failed
the same way. Try again could never fix it.

Reserve now looks for Node where npm, Homebrew and nvm put it: in the folder
that holds the helper, and in each folder its links lead through. Those are
folders Reserve already checks before it trusts a helper, so nothing new is
trusted. If you open Reserve from a terminal, your own PATH still comes first.

The same fix covers Claude Code and Copilot when they come from npm. If you
installed a second copy of Codex just to make Reserve work, you can keep it or
remove it. Either one works now.
