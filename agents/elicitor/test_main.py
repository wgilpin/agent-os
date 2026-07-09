import json
import os
import subprocess
import sys
import pytest

# Ensure project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from agents.elicitor.mock_main import run_mock
from agents.elicitor.models import ElicitorResponse

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

def test_startup_trigger_survives_elicitation():
    purpose = "send a Discord message containing the local machine's time upon loading"
    session = {
        "session_id": "test-1",
        "original_purpose": purpose,
        "transcript": [
            {"role": "user", "content": purpose},
            {"role": "assistant", "content": "Which email service do you use? (e.g. Gmail)"},
            {"role": "user", "content": "yes"}
        ]
    }
    res = run_mock(session)
    assert res.spec_draft.confirmed
    assert [t.type for t in res.spec_draft.triggers] == ["startup"]
    # Round-trip through JSON as the port boundary does
    dumped = json.loads(res.model_dump_json())
    assert dumped["spec_draft"]["triggers"][0]["type"] == "startup"

def test_keyword_scan_avoids_substring_false_positive():
    from agents.elicitor.mock_main import triggers_from_purpose
    assert triggers_from_purpose("summarise reports based on loading times") == []
    assert triggers_from_purpose(None) == []
    assert [t.type for t in triggers_from_purpose("ping me on load")] == ["startup"]

def test_no_trigger_invented_without_intent():
    session = {
        "session_id": "test-1",
        "original_purpose": "reply to recruiter emails",
        "transcript": [
            {"role": "user", "content": "reply to recruiter emails"}
        ]
    }
    res = run_mock(session)
    assert res.spec_draft.triggers == []

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
