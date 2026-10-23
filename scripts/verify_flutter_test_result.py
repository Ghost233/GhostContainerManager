"""Verify standard Flutter test completion in addition to its process exit."""
import json
import pathlib
import re
import sys

log_path, command_exit, result_path = sys.argv[1:]
log = pathlib.Path(log_path).read_text(errors="replace")
completed = "All tests passed!" in log
failed = bool(re.search(r"(?:^|[\r\n])\d+:\d+(?::\d+)?\s+\+\d+(?:\s+~\d+)?\s+-[1-9]\d*:", log))
passed = int(command_exit) == 0 and completed and not failed
pathlib.Path(result_path).write_text(json.dumps({
    "command_exit": int(command_exit),
    "successful_completion": completed,
    "failure_reported": failed,
    "passed": passed,
}, indent=2) + "\n")
if not passed:
    print("Flutter test completion is failed or missing; raw process exit is preserved.", file=sys.stderr)
raise SystemExit(0 if passed else 1)
