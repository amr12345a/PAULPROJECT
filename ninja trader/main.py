import os
import time
import json
import threading
import shutil
import logging
import socket
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse
from urllib import error as urllib_error
from urllib import request as urllib_request

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field


def ensure_env_file() -> None:
    env_path = Path(".env")
    example_path = Path(".env.example")
    if env_path.exists() or not example_path.exists():
        return
    shutil.copyfile(example_path, env_path)


ensure_env_file()
load_dotenv()

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class NinjaTraderConnectionConfig:
    strategy_url: str
    api_key: str = ""
    account: str = ""
    instrument_prefix: str = ""  # e.g., 'ES' for ES Z2, 'NQ' for NQ Z2


@dataclass
class Settings:
    nt_strategy_url: str = os.getenv("NT_STRATEGY_URL", "http://YOUR_NINJATRADER_HOST_IP:8000/api/v1/signal")
    nt_api_key: str = os.getenv("NT_API_KEY", "")
    nt_account: str = os.getenv("NT_ACCOUNT", "")
    nt_instrument_prefix: str = os.getenv("NT_INSTRUMENT_PREFIX", "")

    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "8080"))

    default_order_type: str = os.getenv("DEFAULT_ORDER_TYPE", "Market")
    default_quantity: int = int(os.getenv("DEFAULT_QUANTITY", "1"))
    nt_order_signal_mode: str = os.getenv("NT_ORDER_SIGNAL_MODE", "market").lower()
    order_status_wait_seconds: float = float(os.getenv("ORDER_STATUS_WAIT_SECONDS", "1.0"))
    nt_signal_timeout_seconds: float = float(os.getenv("NT_SIGNAL_TIMEOUT_SECONDS", "8.0"))
    nt_signal_retry_attempts: int = int(os.getenv("NT_SIGNAL_RETRY_ATTEMPTS", "2"))
    nt_signal_retry_delay_seconds: float = float(os.getenv("NT_SIGNAL_RETRY_DELAY_SECONDS", "0.4"))
    nt_heartbeat_enabled: bool = os.getenv("NT_HEARTBEAT_ENABLED", "true").strip().lower() in {"1", "true", "yes", "on"}

    def __post_init__(self) -> None:
        parsed = urlparse(self.nt_strategy_url)
        if "YOUR_NINJATRADER_HOST_IP" in self.nt_strategy_url:
            raise ValueError(
                "NT_STRATEGY_URL is still set to placeholder value. "
                "Set it to your real NinjaTrader receiver URL in .env."
            )
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError(
                "NT_STRATEGY_URL must be a valid http(s) URL with host, "
                "for example http://127.0.0.1:8000/api/v1/signal"
            )
        if self.default_quantity <= 0:
            raise ValueError("DEFAULT_QUANTITY must be a positive integer")


settings = Settings()


class TradeRequest(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    ticker: str = Field(min_length=1, max_length=32)
    action: str = Field(pattern="^(buy|sell)$")


class NinjaTraderExecutor:
    def __init__(self, settings: Settings, connection: NinjaTraderConnectionConfig) -> None:
        self.settings = settings
        self.connection = connection
        self.last_call_attempt = 0.0
        self._lock = threading.Lock()

    def _resolve_instrument(self, ticker: str) -> str:
        """Build NinjaTrader instrument name from ticker."""
        if self.connection.instrument_prefix:
            return f"{ticker.upper()} {self.connection.instrument_prefix}"
        return ticker.upper()

    def _send_signal(self, payload: dict, timeout: float) -> tuple[int, str]:
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.connection.api_key:
            headers["Authorization"] = f"Bearer {self.connection.api_key}"

        req = urllib_request.Request(
            url=self.connection.strategy_url,
            data=data,
            headers=headers,
            method="POST",
        )

        with urllib_request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", errors="replace")

    def _send_with_retries(self, payload: dict, timeout: float) -> tuple[int, str]:
        attempts = max(self.settings.nt_signal_retry_attempts, 1)
        retry_delay = max(self.settings.nt_signal_retry_delay_seconds, 0.0)
        last_error: Exception | None = None

        for attempt in range(1, attempts + 1):
            try:
                return self._send_signal(payload=payload, timeout=timeout)
            except (urllib_error.URLError, TimeoutError, socket.timeout) as exc:
                last_error = exc
                if attempt >= attempts:
                    break
                time.sleep(retry_delay)

        assert last_error is not None
        raise last_error

    def place_market_order(self, ticker: str, action: str, quantity: int) -> dict:
        with self._lock:
            now = time.time()
            if now - self.last_call_attempt < 0.1:
                time.sleep(0.1)
            self.last_call_attempt = time.time()

            instrument = self._resolve_instrument(ticker)
            payload = {
                "instrument": instrument,
                "action": action.lower(),
                "quantity": int(quantity),
                "account": self.connection.account or None,
                "order_type": self.settings.default_order_type,
                "signal_mode": self.settings.nt_order_signal_mode,
            }

            effective_timeout = max(
                self.settings.nt_signal_timeout_seconds,
                self.settings.order_status_wait_seconds,
                0.5,
            )
            attempts = max(self.settings.nt_signal_retry_attempts, 1)
            started_at = time.monotonic()

            try:
                status_code, response_text = self._send_with_retries(
                    payload=payload,
                    timeout=effective_timeout,
                )
            except urllib_error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
                raise RuntimeError(f"NinjaTrader signal rejected ({exc.code}): {body}") from exc
            except (TimeoutError, socket.timeout) as exc:
                elapsed = time.monotonic() - started_at
                raise RuntimeError(
                    "NinjaTrader strategy timed out "
                    f"after {attempts} attempt(s) to {self.connection.strategy_url} "
                    f"with {effective_timeout:.1f}s timeout per attempt "
                    f"(elapsed {elapsed:.1f}s)"
                ) from exc
            except urllib_error.URLError as exc:
                raise RuntimeError(f"NinjaTrader strategy unreachable: {exc}") from exc

            if status_code >= 400:
                raise RuntimeError(f"Signal failed ({status_code}): {response_text}")

            return {
                "instrument": instrument,
                "action": action.lower(),
                "quantity": quantity,
                "status": "signal_sent",
                "account": self.connection.account or "default",
                "nt_strategy_url": self.connection.strategy_url,
                "nt_response_status": status_code,
                "nt_response": response_text[:200],
            }


class NinjaTraderExecutorManager:
    def __init__(self, cfg: Settings) -> None:
        self._executor = NinjaTraderExecutor(
            cfg,
            NinjaTraderConnectionConfig(
                strategy_url=cfg.nt_strategy_url.rstrip("/"),
                api_key=cfg.nt_api_key,
                account=cfg.nt_account,
                instrument_prefix=cfg.nt_instrument_prefix,
            ),
        )

    def get_executor(self) -> NinjaTraderExecutor:
        return self._executor

    def health(self) -> dict:
        ex = self._executor
        return {
            "ninja_trader": {
                "strategy_url": ex.connection.strategy_url,
                "account": ex.connection.account or "default",
                "instrument_prefix": ex.connection.instrument_prefix or "(none)",
            }
        }


def probe_strategy_tcp(strategy_url: str, timeout: float = 2.0) -> dict:
    parsed = urlparse(strategy_url)
    if parsed.scheme not in {"http", "https"}:
        return {
            "ok": False,
            "error": f"Unsupported scheme '{parsed.scheme or '(missing)'}'",
            "strategy_url": strategy_url,
        }

    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if not host:
        return {
            "ok": False,
            "error": "Missing host in NT_STRATEGY_URL",
            "strategy_url": strategy_url,
        }

    started = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            elapsed = time.monotonic() - started
            return {
                "ok": True,
                "host": host,
                "port": port,
                "connect_elapsed_seconds": round(elapsed, 3),
                "strategy_url": strategy_url,
            }
    except OSError as exc:
        elapsed = time.monotonic() - started
        return {
            "ok": False,
            "host": host,
            "port": port,
            "connect_elapsed_seconds": round(elapsed, 3),
            "strategy_url": strategy_url,
            "error": str(exc),
        }


app = FastAPI(title="NinjaTrader Trade Executor", version="1.0.0")
executors = NinjaTraderExecutorManager(settings)


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "service": "NinjaTrader Signal Bridge",
        "ninja_trader": executors.health(),
    }


@app.get("/health/ninja-trader")
def health_ninja_trader() -> dict:
    ex = executors.get_executor()
    return {
        "ok": True,
        "strategy": probe_strategy_tcp(ex.connection.strategy_url),
    }


@app.post("/trade")
def trade(payload: TradeRequest) -> dict:
    qty = settings.default_quantity
    if qty <= 0:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="DEFAULT_QUANTITY must be a positive integer",
        )

    try:
        executor = executors.get_executor()
        result = executor.place_market_order(
            ticker=payload.ticker,
            action=payload.action,
            quantity=qty,
        )
    except Exception as exc:
        logger.exception("Failed to place NinjaTrader order for payload: %s", payload.model_dump())
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to place NinjaTrader order: {exc}",
        ) from exc

    return {
        "accepted": True,
        "request": payload.model_dump(),
        "result": result,
    }
