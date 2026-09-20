#!/bin/bash
# ExecStopPost runs on success, failure, or service timeout. Never retry outputs.
set -u
cd /var/lib/operator-control || exit 1
/usr/bin/python3 - <<'PY'
import datetime, json, os
from pathlib import Path
status = {"ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "service_result": os.environ.get("SERVICE_RESULT"),
          "exit_code": os.environ.get("EXIT_CODE"),
          "exit_status": os.environ.get("EXIT_STATUS"),
          "automatic_rerun": False,
          "outputs_on_retained_persistent_disk": True}
if Path("scope-stop-request.json").exists():
    status["requested_stop"] = json.loads(Path("scope-stop-request.json").read_text())
Path("service-status.json").write_text(json.dumps(status, indent=2) + "\n")
with open("/dev/console", "w") as console:
    console.write("OPERATOR_CONTROL_FINISHED " + json.dumps(status) + "\n")
PY
# Package the completed or partial run for later recovery. Raw files remain
# available even if packaging is interrupted by platform preemption.
files=(bundle.tar.gz instance.json experiment.log service-status.json cloud-run.sh cloud-finalize.sh)
for item in results launch.json CLOUD_RUN.md cohort_stop.py cohort-stop.log scope-amendment.json scope-progress.json scope-summary.json scope-stop-request.json; do
    if test -e "$item"; then files+=("$item"); fi
done
if tar -czf run-artifact.tar.gz.tmp "${files[@]}"; then
    mv run-artifact.tar.gz.tmp run-artifact.tar.gz
    sha256sum run-artifact.tar.gz > run-artifact.tar.gz.sha256
fi
sync
# The service is deliberately not enabled at boot: recovery must not rerun it.
systemctl --no-block poweroff
