import json
import os
import sys
from typing import List, Dict, Any

# Ensure project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from agents.elicitor.models import ElicitorResponse, ElicitedSpecModel, BoundaryModel, SpendLimitsModel

def run_mock(session_data: Dict[str, Any]) -> ElicitorResponse:
    """
    Simulates the elicitation loop deterministically for testing without contacting Gemini.
    """
    transcript = session_data.get("transcript", [])
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
                confirmed=False
            ),
            next_question="Do you confirm this minimised specification?",
            scope_creep_detected=True,
            pushback_message="Warning: Deleting emails was requested, but is not needed to reply. We have excluded delete capability to keep permissions minimal."
        )
    elif "yes" in last_user_message.lower():
        # User confirmed the spec
        return ElicitorResponse(
            spec_draft=ElicitedSpecModel(
                purpose="reply to recruiter emails and save drafts",
                capabilities=["gmail_read", "gmail_draft"],
                boundaries=BoundaryModel(egress_domains=["gmail.googleapis.com"], target_locations=[]),
                spend_limits=SpendLimitsModel(dollar_cap=0.05, token_limit=100000),
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
                confirmed=False
            ),
            next_question="Which email service do you use? (e.g. Gmail)",
            scope_creep_detected=False,
            pushback_message=""
        )

def run_live(session_data: Dict[str, Any]) -> ElicitorResponse:
    """
    Runs the live elicitation using Gemini SDK with structured JSON output.
    """
    from google import genai
    from google.genai import types

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Error: GEMINI_API_KEY environment variable is required", file=sys.stderr)
        sys.exit(1)

    client = genai.Client(api_key=api_key)

    transcript = session_data.get("transcript", [])
    original_purpose = session_data.get("original_purpose", "")

    # Construct the instruction and prompt history
    system_instruction = """
    You are the Agent OS Specification Elicitor. Your job is to drive a conversation with a user to elicit a clear, minimised, KISS specification for a new autonomous agent.
    
    CRITICAL RULES:
    1. Minimise everything (Principle I Simplicity First, II Explicit Scope Control). Surface the smallest set of capabilities, triggers, and spend limits the purpose actually needs.
    2. Suggest read-only or draft-only permissions rather than direct send or delete access.
    3. Push back on scope creep. If the user asks for actions that aren't strictly necessary to satisfy the purpose, set scope_creep_detected to true and explain why in pushback_message.
    4. Fill in the ElicitedSpecModel structure representing the spec draft.
    5. Formulate a single, concise next clarifying question to ask the user. When the spec is KISS-clear and all boundaries/spends are decided, ask the user to confirm the spec.
    6. When the user confirms the spec (e.g., says "yes", "confirm", "looks good"), set confirmed to true.
    """

    # Format transcript messages for the prompt
    formatted_transcript = []
    for msg in transcript:
        role = msg.get("role")
        content = msg.get("content")
        formatted_transcript.append(f"{role.upper()}: {content}")

    prompt = f"Original Purpose declared: {original_purpose}\n\nConversation Transcript:\n" + "\n".join(formatted_transcript)

    try:
        response = client.models.generate_content(
            model='gemini-3-flash-preview',
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=system_instruction,
                response_mime_type="application/json",
                response_schema=ElicitorResponse,
            )
        )
        # Parse the JSON response
        data = json.loads(response.text)
        return ElicitorResponse.model_validate(data)
    except Exception as e:
        print(f"Error calling Gemini: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    # Read session from stdin
    try:
        input_data = sys.stdin.read()
        if not input_data:
            print("Error: Empty input received on stdin", file=sys.stderr)
            sys.exit(1)
        session_data = json.loads(input_data)
    except Exception as e:
        print(f"Error parsing input JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Determine execution mode
    if os.environ.get("MOCK_ELICITOR") == "true":
        response = run_mock(session_data)
    else:
        response = run_live(session_data)

    # Output structured response on stdout
    print(response.model_dump_json())

if __name__ == "__main__":
    main()
