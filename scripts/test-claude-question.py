#!/usr/bin/env python3
"""Live regression: keep a question answerable despite concurrent child events.
Run against Vibe Island, then click Test answer in the synthetic popup.
"""
import json, socket, time, pathlib, uuid
sid = 'test-question-' + str(uuid.uuid4())
state = pathlib.Path.home() / 'Library/Application Support/VibeIsland/sessions.json'
def send(event, **payload):
    s = socket.create_connection(('127.0.0.1', 43917), timeout=5)
    wire = {'v': 1, 'source': 'claude-code', 'term_program': 't3code',
            'payload': {'session_id': sid, 'hook_event_name': event, 'cwd': '/tmp/VibeIsland-test', **payload}}
    s.sendall((json.dumps(wire) + '\n').encode())
    return s

def ordinary(event, **payload):
    with send(event, **payload) as s:
        assert json.loads(s.recv(8192)) == {}

held = send('PreToolUse', tool_name='AskUserQuestion', tool_input={'questions': [{
    'question': 'Synthetic test: can you click this answer?', 'header': 'Test',
    'options': [{'label': 'Test answer'}, {'label': 'Other test'}]}]})
try:
    for event in ['SubagentStop', 'PostToolUse', 'Notification', 'Stop']:
        ordinary(event, tool_name='Read', message='Background event')
    time.sleep(0.5)
    session = next(s for s in json.loads(state.read_text()) if s['id'] == sid)
    assert session['status'] == 'waiting' and session['pendingRequest']['kind'] == 'question', session
    print('PASS: child completion and background events preserved the question.', flush=True)
    ordinary('VibeShow')
    print('Click Test answer in the island. Waiting for the actual reply…', flush=True)
    held.settimeout(120)
    stream = held.makefile('rb')
    for line in stream:
        if not line.strip(): continue
        response = json.loads(line)
        reason = response['hookSpecificOutput']['permissionDecisionReason']
        assert 'Test answer' in reason, response
        print('PASS: clicked answer reached the waiting hook connection.', flush=True)
        break
    else:
        raise AssertionError('Connection closed without an answer')
finally:
    held.close()
    ordinary('SessionEnd')
