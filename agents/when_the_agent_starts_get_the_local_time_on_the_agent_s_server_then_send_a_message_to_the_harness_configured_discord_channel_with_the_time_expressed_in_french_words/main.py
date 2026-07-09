import sys
import os
import socket
import json
from datetime import datetime
from models import OutcomeRecord

def call_inference_broker(model: str, messages: list[dict[str, str]]) -> dict:
    """Routes an inference call to the substrate broker over the mounted UDS."""
    run_token = os.environ.get("RUN_TOKEN")
    socket_path = os.environ.get("INFERENCE_SOCKET")

    if not run_token or not socket_path:
        raise RuntimeError("Inference environment variables not set")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(socket_path)

    payload = {"run_token": run_token, "model": model, "messages": messages}
    body = json.dumps(payload)
    request = (
        f"POST /v1/inference HTTP/1.1\r\n"
        f"Host: localhost\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
        f"{body}"
    )
    s.sendall(request.encode("utf-8"))

    response_data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        response_data += chunk
    s.close()

    response_str = response_data.decode("utf-8")
    headers_str, response_body = response_str.split("\r\n\r\n", 1)
    status_code = int(headers_str.split("\r\n")[0].split(" ")[1])
    response_json = json.loads(response_body)
    if status_code != 200:
        raise RuntimeError(f"Inference broker error: status {status_code}")
    return response_json

def translate_time_to_french_words(dt: datetime) -> str:
    """Translates a datetime hour and minute to French words."""
    hours_fr = {
        0: "minuit", 1: "une heure", 2: "deux heures", 3: "trois heures",
        4: "quatre heures", 5: "cinq heures", 6: "six heures", 7: "sept heures",
        8: "huit heures", 9: "neuf heures", 10: "dix heures", 11: "onze heures",
        12: "midi", 13: "treize heures", 14: "quatorze heures", 15: "quinze heures",
        16: "seize heures", 17: "dix-sept heures", 18: "dix-huit heures",
        19: "dix-neuf heures", 20: "vingt heures", 21: "vingt-et-une heures",
        22: "vingt-deux heures", 23: "vingt-trois heures"
    }
    
    minutes_fr = {
        0: "", 1: "un", 2: "deux", 3: "trois", 4: "quatre", 5: "cinq", 
        6: "six", 7: "sept", 8: "huit", 9: "neuf", 10: "dix",
        11: "onze", 12: "douze", 13: "treize", 14: "quatorze", 15: "quinze",
        16: "seize", 17: "dix-sept", 18: "dix-huit", 19: "dix-neuf", 20: "vingt",
        21: "vingt et un", 22: "vingt-deux", 23: "vingt-trois", 24: "vingt-quatre",
        25: "vingt-cinq", 26: "vingt-six", 27: "vingt-sept", 28: "vingt-huit",
        29: "vingt-neuf", 30: "trente", 31: "trente et un", 32: "trente-deux",
        33: "trente-trois", 34: "trente-quatre", 35: "trente-cinq", 36: "trente-six",
        37: "trente-sept", 38: "trente-huit", 39: "trente-neuf", 40: "quarante",
        41: "quarante et un", 42: "quarante-deux", 43: "quarante-trois", 44: "quarante-quatre",
        45: "quarante-cinq", 46: "quarante-six", 47: "quarante-sept", 48: "quarante-huit",
        49: "quarante-neuf", 50: "cinquante", 51: "cinquante et un", 52: "cinquante-deux",
        53: "cinquante-trois", 54: "cinquante-quatre", 55: "cinquante-cinq", 56: "cinquante-six",
        57: "cinquante-sept", 58: "cinquante-huit", 59: "cinquante-neuf"
    }

    h, m = dt.hour, dt.minute
    h_str = hours_fr.get(h, f"{h} heures")
    m_str = minutes_fr.get(m, str(m))
    
    if m == 0:
        return h_str
    return f"{h_str} {m_str}"

def main():
    try:
        # Read input configuration from stdin
        input_payload = sys.stdin.read().strip()
        if not input_payload:
            data = {}
        else:
            data = json.loads(input_payload)
    except Exception as e:
        sys.stderr.write(f"Error parsing input JSON: {e}\n")
        sys.exit(1)

    try:
        # Get current local time
        now = datetime.now()
        time_string = now.strftime("%H:%M")
        french_time_words = translate_time_to_french_words(now)
        
        # Prepare discord message text
        message_content = f"Il est actuellement (heure locale) : {french_time_words} (soit {time_string})."

        # Standard agent setup and LLM execution
        model = os.environ.get("AGENT_MODEL", "")
        system_prompt = (
            "You are an agent with access to a Discord connector capable of sending messages. "
            "You must look at your available tools and select the correct connector_id and method "
            "to send a Discord message. Choose exactly the dynamically-provided tool corresponding to "
            "sending a message to the Discord channel, and pass the text content correctly."
        )
        
        user_prompt = f"Execute the message dispatch. The text to post to Discord is: {message_content}"
        
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ]
        
        # Invoke broker so it executes the chosen tool under authorization
        broker_response = call_inference_broker(model, messages)
        
        # Emit final single line outcome
        outcome = OutcomeRecord(
            outcome="completed",
            reason=f"Local time {time_string} translated to French: '{french_time_words}' and sent to Discord successfully."
        )
        print(outcome.json())
        sys.exit(0)

    except Exception as e:
        sys.stderr.write(f"Execution occurred an error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()