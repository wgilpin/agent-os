import json
import subprocess
import sys
from agents.discovery.main import build_actions


def test_build_actions_empty_input():
    actions = build_actions({})
    assert len(actions) == 1
    assert actions[0].type == "append_digest"
    assert actions[0].payload == {"text": "no input"}


def test_build_actions_with_roster():
    input_data = {
        "roster": [
            {"high_signal": True, "text": "AI breakthrough"},
            {"high_signal": False, "text": "spam news"},
            "plain string input",
        ]
    }
    actions = build_actions(input_data)
    # The high_signal item and plain string input should trigger actions.
    # The high_signal=False item should not.
    assert len(actions) == 2

    assert actions[0].type == "append_digest"
    assert "AI breakthrough" in actions[0].payload["text"]
    assert "text" in actions[0].payload

    assert actions[1].type == "append_digest"
    assert "plain string input" in actions[1].payload["text"]
    assert "text" in actions[1].payload


def test_subprocess_execution_happy_path():
    # Run main.py as a subprocess feeding stdin
    proc = subprocess.run(
        [sys.executable, "agents/discovery/main.py"],
        input=b'{"roster": ["alice"]}\n',
        capture_output=True,
        check=True,
    )
    assert proc.returncode == 0
    output = json.loads(proc.stdout)
    assert "actions" in output
    assert isinstance(output["actions"], list)
    assert len(output["actions"]) == 1
    assert output["actions"][0]["type"] == "append_digest"
    assert "alice" in output["actions"][0]["payload"]["text"]


from pydantic import ValidationError
import pytest
from agents.discovery.models import BookmarkItem, DiscoveryInput

def test_bookmark_item_validation():
    # Valid item
    item = BookmarkItem(id="1", author="a", text="hello")
    assert item.id == "1"

    # Too long id
    with pytest.raises(ValidationError):
        BookmarkItem(id="a" * 257, author="a", text="hello")

    # Too long author
    with pytest.raises(ValidationError):
        BookmarkItem(id="1", author="a" * 257, text="hello")

    # Too long text
    with pytest.raises(ValidationError):
        BookmarkItem(id="1", author="a", text="a" * 10001)

def test_discovery_input_validation():
    # Valid input
    payload = {
        "state": {"records": []},
        "items": [{"id": "1", "author": "a", "text": "hello"}]
    }
    DiscoveryInput.model_validate(payload)

    # Missing state
    with pytest.raises(ValidationError):
        DiscoveryInput.model_validate({"items": []})

