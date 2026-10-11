---
description: Stop the local nurseprep stack (mix phx.server + Evolution API Docker containers)
---

Run `bin/nurseprep_dev_down.sh` from the repo root and report its output to the user verbatim.
This stops (not removes) the Evolution API containers, so the paired WhatsApp session survives
for next time `/nurseprep` is run.
