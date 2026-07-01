import json
import os
import sys
import socket
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

def load_env_file():
    """Manually parse .env in project root to support dotenv formats with/without export."""
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
    env_path = os.path.join(root_dir, ".env")
    if os.path.exists(env_path):
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].strip()
                if "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip()
                    val = val.strip().strip("'\"")
                    if key:
                        os.environ[key] = val

def run_live(session_data: Dict[str, Any]) -> ElicitorResponse:
    """
    Runs the live elicitation using InferenceBroker over the mounted UDS socket.
    """
    load_env_file()

    run_token = os.environ.get("RUN_TOKEN")
    socket_path = os.environ.get("INFERENCE_SOCKET")

    if not run_token or not socket_path:
        print("Error: RUN_TOKEN and INFERENCE_SOCKET environment variables are required", file=sys.stderr)
        sys.exit(1)

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

    # Append JSON Schema details to ensure output format compliance
    schema_desc = json.dumps(ElicitorResponse.model_json_schema(), indent=2)
    system_instruction_with_schema = (
        system_instruction
        + f"\n\nYou MUST return a JSON object that strictly conforms to this JSON Schema:\n{schema_desc}"
    )

    messages = [
        {"role": "system", "content": system_instruction_with_schema},
        {"role": "user", "content": prompt}
    ]

    model = os.environ.get("OPENROUTER_MODEL", "google/gemini-2.5-flash")

    # Construct request body for InferenceBroker
    payload = {
        "run_token": run_token,
        "model": model,
        "messages": messages
    }
    body = json.dumps(payload)

    try:
        # Connect to UDS socket
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(socket_path)

        # Format HTTP POST request
        request = (
            f"POST /v1/inference HTTP/1.1\r\n"
            f"Host: localhost\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"Connection: close\r\n\r\n"
            f"{body}"
        )

        s.sendall(request.encode("utf-8"))

        # Receive response
        response_data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            response_data += chunk
        s.close()

        # Parse response
        response_str = response_data.decode("utf-8")
        parts = response_str.split("\r\n\r\n", 1)
        if len(parts) < 2:
            raise RuntimeError(f"Invalid response from inference broker (no headers split). Raw response: {response_str!r}")
        
        headers_str, response_body = parts
        
        # Check status code in headers
        first_line = headers_str.split("\r\n")[0]
        status_code = int(first_line.split(" ")[1])
        
        try:
            response_json = json.loads(response_body)
        except Exception as e:
            raise RuntimeError(f"JSON decode of response_body failed: {e}. response_body={response_body!r}")
            
        if status_code != 200:
            error_msg = response_json.get("error", "unknown_error")
            raise RuntimeError(f"Inference broker error: {error_msg} (status {status_code})")
            
        content = response_json["completion"]
        content_str = content.strip()
        if content_str.startswith("```"):
            first_newline = content_str.find("\n")
            if first_newline != -1:
                content_str = content_str[first_newline:].strip()
            if content_str.endswith("```"):
                content_str = content_str[:-3].strip()

        try:
            parsed_content = json.loads(content_str)
        except Exception as e:
            raise RuntimeError(f"JSON decode of completion content failed: {e}. content={content!r}, content_str={content_str!r}")
            
        return ElicitorResponse.model_validate(parsed_content)
        
    except Exception as e:
        print(f"Error calling InferenceBroker: {e}", file=sys.stderr)
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
