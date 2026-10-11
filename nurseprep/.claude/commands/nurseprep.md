---
description: Start the local nurseprep stack (Evolution API WhatsApp gateway + mix phx.server)
---

Run `bin/nurseprep_dev_up.sh` from the repo root and report its output to the user verbatim
(it prints the app URL, the Evolution instance's pairing state, and the log file path). If it
exits non-zero, show the error and the relevant log tail rather than trying to silently fix
anything-surface it and ask how to proceed.
