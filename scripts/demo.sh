#!/bin/bash
# Sends fake agent events to a running Vibe Island so you can see the UI
# without hooking a real agent. Usage: scripts/demo.sh [approval|question]
set -euo pipefail
PORT=43917

TTYDEV=$(tty 2>/dev/null || true)
case "$TTYDEV" in /dev/*) TTYNAME=$(basename "$TTYDEV") ;; *) TTYNAME=ttys000 ;; esac

# send <payload-json> — wraps and fires an event, ignoring the reply.
send() {
    wrap_and_pipe "$1" | nc -w 2 127.0.0.1 $PORT >/dev/null || true
    sleep 0.4
}

# ask <payload-json> — wraps, sends, and prints the interactive reply.
ask() {
    wrap_and_pipe "$1" | nc -w 600 127.0.0.1 $PORT
    echo
}

wrap_and_pipe() {
    printf '{"v":1,"source":"claude-code","term_program":"%s","term_session":"","tty":"%s","payload":%s}\n' \
        "${TERM_PROGRAM:-iTerm.app}" "$TTYNAME" "$1"
}

SID="demo-$(date +%s)"

P='{"session_id":"'$SID'","hook_event_name":"SessionStart","cwd":"'$PWD'","source":"startup"}'
send "$P"
P='{"session_id":"'$SID'","hook_event_name":"UserPromptSubmit","cwd":"'$PWD'","prompt":"fix auth bug in middleware"}'
send "$P"
P='{"session_id":"'$SID'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"src/db/schema.prisma"}}'
send "$P"
P='{"session_id":"'$SID'","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"src/db/schema.prisma"},"tool_response":"model User { id Int @id }"}'
send "$P"
P='{"session_id":"'$SID'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}'
send "$P"

case "${1:-}" in
question)
    echo "Sending AskUserQuestion (answer it in the notch; response prints below)…"
    P='{"session_id":"'$SID'","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Deploy target","question":"Which environment should I deploy to?","options":[{"label":"Production"},{"label":"Staging"},{"label":"Local only"}]}]}}'
    ask "$P"
    ;;
approval)
    echo "Enable Approve-from-notch for the demo session, then respond in the notch…"
    P='{"session_id":"'$SID'","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"## Plan: fix auth bug\n\n1. Add token verification to middleware\n2. Return 401 on invalid token\n3. Add regression test"}}'
    ask "$P"
    ;;
*)
    P='{"session_id":"'$SID'","hook_event_name":"Stop"}'
    send "$P"
    ;;
esac

echo "Demo events sent (session $SID)."
