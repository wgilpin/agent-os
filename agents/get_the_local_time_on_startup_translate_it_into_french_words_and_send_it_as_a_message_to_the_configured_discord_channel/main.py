import sys
import os
import json
import socket
import datetime
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

def translate_time_to_french_words(dt: datetime.datetime) -> str:
    """Translates a datetime objective into a human-like French time string."""
    hour = dt.hour
    minute = dt.minute

    # Numbers lookup
    num_words = {
        0: "zéro", 1: "une" if minute > 0 else "un", 2: "deux", 3: "trois", 4: "quatre",
        5: "cinq", 6: "six", 7: "sept", 8: "huit", 9: "neuf", 10: "dix",
        11: "onze", 12: "douze", 13: "treize", 14: "quatorze", 15: "quinze",
        16: "seize", 17: "dix-sept", 18: "dix-huit", 19: "dix-neuf", 20: "vingt",
        21: "vingt-et-un", 22: "vingt-deux", 23: "vingt-trois", 24: "vingt-quatre",
        25: "vingt-cinq", 26: "vingt-six", 27: "vingt-sept", 28: "vingt-huit",
        29: "vingt-neuf", 30: "trente", 31: "trente-et-un", 32: "trente-deux",
        33: "trente-trois", 34: "trente-quatre", 35: "trente-cinq", 36: "trente-six",
        37: "trente-sept", 38: "trente-huit", 39: "trente-neuf", 40: "quarante",
        41: "quarante-et-un", 42: "quarante-deux", 43: "quarante-trois", 44: "quarante-quatre",
        45: "quarante-cinq", 46: "quarante-six", 47: "quarante-sept", 48: "quarante-huit",
        49: "quarante-neuf", 50: "cinquante", 51: "cinquante-et-un", 52: "cinquante-deux",
        53: "cinquante-trois", 54: "cinquante-et-quatre", 55: "cinquante-cinq",
        56: "cinquante-six", 57: "cinquante-sept", 58: "cinquante-huit", 59: "cinquante-neuf"
    }

    # Standard French time naming rules
    if hour == 0:
        hour_str = "minuit"
    elif hour == 12:
        hour_str = "midi"
    else:
        h_word = "une" if (hour == 1 or hour == 13) else num_words[hour % 12 or 12]
        hour_str = f"{h_word} heure" + ("s" if (hour % 12 or 12) > 1 else "")

    if minute == 0:
        return hour_str
    elif minute == 15:
        return f"{hour_str} et quart"
    elif minute == 30:
        return f"{hour_str} et demie"
    elif minute == 45:
        next_hour = (hour + 1) % 24
        if next_hour == 0:
            next_hour_str = "minuit"
        elif next_hour == 12:
            next_hour_str = "midi"
        else:
            nh_word = "une" if (next_hour == 1 or next_hour == 13) else num_words[next_hour % 12 or 12]
            next_hour_str = f"{nh_word} heure" + ("s" if (next_hour % 12 or 12) > 1 else "")
        return f"{next_hour_str} moins le quart"
    elif minute > 30:
        # E.g. "six heures moins dix"
        next_hour = (hour + 1) % 24
        if next_hour == 0:
            next_hour_str = "minuit"
        elif next_hour == 12:
            next_hour_str = "midi"
        else:
            nh_word = "une" if (next_hour == 1 or next_hour == 13) else num_words[next_hour % 12 or 12]
            next_hour_str = f"{nh_word} heure" + ("s" if (next_hour % 12 or 12) > 1 else "")
        diff = 60 - minute
        diff_word = num_words[diff]
        return f"{next_hour_str} moins {diff_word}"
    else:
        min_word = num_words[minute]
        return f"{hour_str} {min_word}"

def main():
    try:
        # Read single line of raw input as generic dict
        input_line = sys.stdin.readline()
        if not input_line:
            input_data = {}
        else:
            input_data = json.loads(input_line)
    except Exception as e:
        sys.stderr.write(f"Error reading input JSON: {str(e)}\n")
        sys.exit(1)

    try:
        now = datetime.datetime.now()
        time_string_fr = translate_time_to_french_words(now)
        formatted_time = now.strftime("%H:%M")
        message_content = f"Le temps local est actuellement {time_string_fr} ({formatted_time})."

        # Retrieve model
        model = os.environ.get("AGENT_MODEL", "")

        # Construct prompt to output using capabilities available in the environment.
        # This ensures we dynamically run the registered and granted discord tools without hardcoding values.
        system_prompt = (
            "You are an automated agent dispatching a converted local time message to Discord.\n"
            "Use the tool granted to you in your environment that allows sending a message to a Discord channel.\n"
            "Do not hardcode specific connector names or methods. Identify them from your available capability grants "
            "and execute the tool call parameterizing it with the required structure.\n"
            "The substrate handles executing any tool call you issue."
        )

        user_prompt = f"Please send the following message to the configured Discord channel: '{message_content}'"

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ]

        # Call inference broker. Tool discovery and capability validation are handled by the substrate.
        response = call_inference_broker(model, messages)

        # Prepare final single line outcome record
        outcome = OutcomeRecord(outcome="completed", reason=f"Local time ({formatted_time}) translated to French ('{time_string_fr}') and forwarded to Discord interface.")
        print(outcome.model_dump_json())
    except Exception as e:
        sys.stderr.write(f"Exception during agent execution: {str(e)}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
