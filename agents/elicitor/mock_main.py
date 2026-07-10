import json
import os
import re
import sys
from typing import Dict, Any

# Ensure project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from agents.elicitor.models import ElicitorResponse, ElicitedSpecModel, BoundaryModel, SpendLimitsModel, TriggerModel

def triggers_from_purpose(purpose: str) -> list:
    """Deterministic keyword scan mirroring prompt rule 8 of the live elicitor."""
    lowered = (purpose or "").lower()
    if re.search(r"\b(upon loading|on load|when the agent starts|at startup)\b", lowered):
        return [TriggerModel(type="startup")]
    return []

def run_mock(session_data: Dict[str, Any]) -> ElicitorResponse:
    """
    Simulates the elicitation loop deterministically for testing without contacting Gemini.
    """
    transcript = session_data.get("transcript", [])
    triggers = triggers_from_purpose(session_data.get("original_purpose", ""))
    last_user_message = ""
    for msg in reversed(transcript):
        if msg.get("role") == "user":
            last_user_message = msg.get("content", "")
            break

    # Mock conversation tree based on user inputs
    if "delete recruiter emails" in last_user_message:
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails and save drafts",
                capabilities=["gmail_read", "gmail_draft"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.05, token_limit=100000),
                triggers=triggers,
                confirmed=False
            ),
            next_question="Do you confirm this minimised specification?",
            scope_creep_detected=True,
            pushback_message="Warning: Deleting emails was requested, but is not needed to reply. We have excluded delete capability to keep permissions minimal."
        )
    elif "confirm" in last_user_message.lower():
        # Confirmation WITH closing prose — mirrors observed live behavior: models
        # often set confirmed=True but answer "Spec confirmed. No further
        # questions." The structured flag, not an empty next_question, must be the
        # confirmation signal.
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails and save drafts",
                capabilities=["gmail_read", "gmail_draft"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.05, token_limit=100000),
                confirmed=True
            ),
            next_question="Spec confirmed. No further questions.",
            scope_creep_detected=False,
            pushback_message=""
        )
    elif "yes" in last_user_message.lower():
        # User confirmed the spec
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails and save drafts",
                capabilities=["gmail_read", "gmail_draft"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.05, token_limit=100000),
                triggers=triggers,
                confirmed=True
            ),
            next_question="",
            scope_creep_detected=False,
            pushback_message=""
        )
    elif "save drafts" in last_user_message.lower():
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails and save drafts",
                capabilities=["gmail_read", "gmail_draft"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.05, token_limit=100000),
                triggers=triggers,
                confirmed=False
            ),
            next_question="Do you confirm this minimised specification?",
            scope_creep_detected=False,
            pushback_message=""
        )
    elif "gmail" in last_user_message.lower():
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails",
                capabilities=["gmail_read"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.01, token_limit=20000),
                triggers=triggers,
                confirmed=False
            ),
            next_question="Should the agent send emails directly or just save drafts?",
            scope_creep_detected=False,
            pushback_message=""
        )
    else:
        # Default starting response for "reply to recruiter emails" or anything else
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails",
                capabilities=[],
                boundaries=BoundaryModel(egress_domains=[], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.0, token_limit=0),
                triggers=triggers,
                confirmed=False
            ),
            next_question="Which email service do you use? (e.g. Gmail)",
            scope_creep_detected=False,
            pushback_message=""
        )

def main():
    try:
        input_data = sys.stdin.read()
        if not input_data:
            print("Error: Empty input received on stdin", file=sys.stderr)
            sys.exit(1)
        session_data = json.loads(input_data)
    except Exception as e:
        print(f"Error parsing input JSON: {e}", file=sys.stderr)
        sys.exit(1)

    response = run_mock(session_data)
    print(response.model_dump_json())

if __name__ == "__main__":
    main()
