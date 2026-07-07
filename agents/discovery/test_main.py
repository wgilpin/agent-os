import json
import subprocess
import sys

import pytest
from pydantic import ValidationError

from agents.discovery.main import build_messages, normalize_input
from agents.discovery.models import BookmarkItem, DiscoveryInput


def test_normalize_input_roster_to_items():
    normalized = normalize_input({"roster": [{"signal": "high", "text": "valid news"}]})
    assert normalized["items"][0]["text"] == "valid news"
    assert normalized["state"] == {"records": []}


def test_build_messages_carries_items():
    input_data = DiscoveryInput.model_validate(
        {"state": {"records": []}, "items": [{"id": "1", "author": "a", "text": "alice"}]}
    )
    messages = build_messages(input_data)

    assert messages[0]["role"] == "system"
    assert messages[1]["role"] == "user"
    user_payload = json.loads(messages[1]["content"])
    assert user_payload["items"] == [{"id": "1", "text": "alice"}]


def test_subprocess_prints_outcome_record_and_refuses_without_broker():
    # With no RUN_TOKEN/INFERENCE_SOCKET in the environment, discovery cannot reach the
    # broker; it must still exit 0 and print a terminal outcome record (never actions).
    proc = subprocess.run(
        [sys.executable, "agents/discovery/main.py"],
        input=b'{"roster": ["alice"]}\n',
        capture_output=True,
        check=True,
    )
    assert proc.returncode == 0
    output = json.loads(proc.stdout)
    assert "actions" not in output
    assert output["outcome"] == "refused"
    assert "reason" in output


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
        "items": [{"id": "1", "author": "a", "text": "hello"}],
    }
    DiscoveryInput.model_validate(payload)

    # Missing state
    with pytest.raises(ValidationError):
        DiscoveryInput.model_validate({"items": []})
