import json
import os
import subprocess
import sys

# Ensure project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from agents.elicitor.mock_main import run_mock

def test_run_mock_initial():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"}
        ]
    }
    res = run_mock(session)
    assert res.spec_draft.purpose == "reply to recruiter emails"
    assert res.next_question == "Which email service do you use? (e.g. Gmail)"
    assert not res.spec_draft.confirmed

def test_run_mock_gmail():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"},
            {"role": "assistant", "content": "Which email service do you use? (e.g. Gmail)"},
            {"role": "user", "content": "Gmail"}
        ]
    }
    res = run_mock(session)
    assert "gmail_read" in res.spec_draft.capabilities
    assert res.next_question == "Should the agent send emails directly or just save drafts?"

def test_run_mock_scope_creep():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"},
            {"role": "assistant", "content": "Which email service do you use? (e.g. Gmail)"},
            {"role": "user", "content": "delete recruiter emails"}
        ]
    }
    res = run_mock(session)
    assert res.scope_creep_detected
    assert "delete" in res.pushback_message

def test_run_mock_confirmation():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"},
            {"role": "assistant", "content": "Which email service do you use? (e.g. Gmail)"},
            {"role": "user", "content": "yes"}
        ]
    }
    res = run_mock(session)
    assert res.spec_draft.confirmed
    assert res.next_question == ""

def test_subprocess_execution_mocked():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"}
        ]
    }
    env = os.environ.copy()
    env["MOCK_ELICITOR"] = "true"

    # The substrate (elicitation_session.ex) selects mock_main.py when
    # MOCK_ELICITOR=true; exercise that entrypoint directly.
    proc = subprocess.run(
        [sys.executable, "agents/elicitor/mock_main.py"],
        input=json.dumps(session).encode("utf-8"),
        capture_output=True,
        env=env,
        check=True
    )
    
    assert proc.returncode == 0
    output = json.loads(proc.stdout)
    assert "spec_draft" in output
    assert output["next_question"] == "Which email service do you use? (e.g. Gmail)"
