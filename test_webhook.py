#!/usr/bin/env python3
import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def send_webhook(url: str, payload: dict, timeout: float) -> tuple[int, str]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=timeout) as resp:
        status = resp.status
        response_text = resp.read().decode("utf-8", errors="replace")
        return status, response_text


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send test trade webhook requests to the IBKR trade executor."
    )
    parser.add_argument(
        "--url",
        default="http://13.53.172.241:8080/trade",
        help="Webhook URL (default: http://13.53.172.241:8080/trade)",
    )
    parser.add_argument("--bot-id", default="my-bot2", help="Value for payload id")
    parser.add_argument("--ticker", default="AAPL", help="Ticker symbol")
    parser.add_argument(
        "--action",
        default="buy",
        choices=["buy", "sell"],
        help="Trade action",
    )
    parser.add_argument(
        "--attempts",
        type=int,
        default=1,
        help="How many attempts to send (default: 1)",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=1.0,
        help="Delay between attempts in seconds (default: 1.0)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="Request timeout in seconds (default: 10.0)",
    )

    args = parser.parse_args()

    if args.attempts <= 0:
        print("--attempts must be greater than 0")
        return 2

    payload = {
        "id": args.bot_id,
        "ticker": args.ticker,
        "action": args.action,
    }

    failures = 0
    for i in range(1, args.attempts + 1):
        print(f"[{i}/{args.attempts}] POST {args.url}")
        print(f"payload={json.dumps(payload)}")
        try:
            status, response_text = send_webhook(args.url, payload, args.timeout)
            print(f"status={status}")
            print(f"response={response_text}")
        except urllib.error.HTTPError as exc:
            failures += 1
            body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            print(f"status={exc.code}")
            print(f"response={body}")
        except Exception as exc:
            failures += 1
            print(f"request failed: {exc}")

        if i < args.attempts:
            time.sleep(args.delay)

        print("-" * 60)

    if failures:
        print(f"completed with {failures} failed attempt(s)")
        return 1

    print("all attempts succeeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
