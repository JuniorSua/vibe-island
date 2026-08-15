#!/bin/bash
# Verifies the hold + heartbeat-abandon path against a running app.
set -u
cd "$(dirname "$0")/.."
STATE="$HOME/Library/Application Support/VibeIsland/sessions.json"

SID="demo-hb-$(date +%s)"
P='{"session_id":"'$SID'","hook_event_name":"PreToolUse","cwd":"'$PWD'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Test","question":"Heartbeat test?","options":[{"label":"A"},{"label":"B"}]}]}}'

printf '{"v":1,"source":"claude-code","term_program":"iTerm.app","term_session":"","tty":"ttys000","payload":%s}\n' "$P" \
    | nc -w 600 127.0.0.1 43917 > /tmp/nc_out.txt 2>&1 &
NCPID=$!

sleep 3
python3 - "$SID" "$STATE" <<'EOF'
import json, sys
d = json.load(open(sys.argv[2]))
s = [x for x in d if x['id'] == sys.argv[1]][0]
print('held: status =', s['status'], '| pending =', s.get('pendingRequest') is not None)
EOF

kill -9 $NCPID 2>/dev/null
sleep 35
python3 - "$SID" "$STATE" <<'EOF'
import json, sys
d = json.load(open(sys.argv[2]))
s = [x for x in d if x['id'] == sys.argv[1]][0]
print('after client kill: status =', s['status'], '| pending =', s.get('pendingRequest') is not None)
EOF
