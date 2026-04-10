import os
import time
import asyncio
import threading
import shutil
import json
import logging
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, status
from ib_insync import IB, MarketOrder, Stock
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


@dataclass
class Settings:
    ib_host: str = os.getenv("IB_HOST", "127.0.0.1")
    ib_port: int = int(os.getenv("IB_PORT", "7497"))
    ib_client_id: int = int(os.getenv("IB_CLIENT_ID", "101"))
    ib_account: str = os.getenv("IB_ACCOUNT", "")

    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "80"))

    default_exchange: str = os.getenv("DEFAULT_EXCHANGE", "SMART")
    default_currency: str = os.getenv("DEFAULT_CURRENCY", "USD")
    default_order_type: str = os.getenv("DEFAULT_ORDER_TYPE", "MKT")
    default_quantity: int = int(os.getenv("DEFAULT_QUANTITY", "1"))
    default_tif: str = os.getenv("DEFAULT_TIF", "DAY").upper()
    default_outside_rth: bool = os.getenv("DEFAULT_OUTSIDE_RTH", "true").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    order_status_wait_seconds: float = float(os.getenv("ORDER_STATUS_WAIT_SECONDS", "2.0"))
    ib_bot_configs_json: str = os.getenv("IB_BOT_CONFIGS_JSON", "").strip()
    ib_mirror_map_json: str = os.getenv("IB_MIRROR_MAP_JSON", "").strip()
    allowed_bot_ids: set[str] = None  # type: ignore[assignment]
    bot_routes: dict[str, "IBConnectionConfig"] = None  # type: ignore[assignment]
    mirror_map: dict[str, list[str]] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        allowed = os.getenv("ALLOWED_BOT_IDS", "").strip()
        if allowed:
            self.allowed_bot_ids = {x.strip() for x in allowed.split(",") if x.strip()}
        else:
            self.allowed_bot_ids = set()

        self.bot_routes = self._load_bot_routes()
        self.mirror_map = self._load_mirror_map()

        if self.bot_routes:
            if self.allowed_bot_ids:
                missing = sorted(self.allowed_bot_ids - set(self.bot_routes.keys()))
                if missing:
                    raise ValueError(
                        f"ALLOWED_BOT_IDS contains IDs missing from IB_BOT_CONFIGS_JSON: {', '.join(missing)}"
                    )
            else:
                # If route configs exist, default allowed IDs to route keys.
                self.allowed_bot_ids = set(self.bot_routes.keys())

        if self.mirror_map and self.bot_routes:
            configured_ids = set(self.bot_routes.keys())
            for source_id, target_ids in self.mirror_map.items():
                if source_id not in configured_ids:
                    raise ValueError(
                        f"IB_MIRROR_MAP_JSON source id '{source_id}' is missing from IB_BOT_CONFIGS_JSON"
                    )
                for target_id in target_ids:
                    if target_id not in configured_ids:
                        raise ValueError(
                            f"IB_MIRROR_MAP_JSON target id '{target_id}' is missing from IB_BOT_CONFIGS_JSON"
                        )

    def _load_bot_routes(self) -> dict[str, "IBConnectionConfig"]:
        if not self.ib_bot_configs_json:
            return {}

        try:
            raw = json.loads(self.ib_bot_configs_json)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid IB_BOT_CONFIGS_JSON: {exc}") from exc

        if not isinstance(raw, dict):
            raise ValueError("IB_BOT_CONFIGS_JSON must be a JSON object keyed by bot id")

        routes: dict[str, IBConnectionConfig] = {}
        for bot_id, cfg in raw.items():
            if not isinstance(bot_id, str) or not bot_id.strip():
                raise ValueError("IB_BOT_CONFIGS_JSON keys must be non-empty bot ID strings")
            if not isinstance(cfg, dict):
                raise ValueError(f"Route config for bot id '{bot_id}' must be a JSON object")

            host = str(cfg.get("host", self.ib_host))
            port = int(cfg.get("port", self.ib_port))
            client_id = int(cfg.get("client_id", cfg.get("clientId", self.ib_client_id)))
            account = str(cfg.get("account", "")).strip()

            routes[bot_id] = IBConnectionConfig(
                host=host,
                port=port,
                client_id=client_id,
                account=account,
            )

        return routes

    def _load_mirror_map(self) -> dict[str, list[str]]:
        if not self.ib_mirror_map_json:
            return {}

        try:
            raw = json.loads(self.ib_mirror_map_json)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid IB_MIRROR_MAP_JSON: {exc}") from exc

        if not isinstance(raw, dict):
            raise ValueError("IB_MIRROR_MAP_JSON must be a JSON object keyed by source bot id")

        mirrors: dict[str, list[str]] = {}
        for source_id, target_ids in raw.items():
            if not isinstance(source_id, str) or not source_id.strip():
                raise ValueError("IB_MIRROR_MAP_JSON keys must be non-empty source bot id strings")

            normalized_targets: list[str]
            if isinstance(target_ids, str):
                normalized_targets = [target_ids.strip()] if target_ids.strip() else []
            elif isinstance(target_ids, list):
                normalized_targets = []
                for target_id in target_ids:
                    if not isinstance(target_id, str) or not target_id.strip():
                        raise ValueError(
                            f"IB_MIRROR_MAP_JSON targets for '{source_id}' must be non-empty strings"
                        )
                    normalized_targets.append(target_id.strip())
            else:
                raise ValueError(
                    f"IB_MIRROR_MAP_JSON value for '{source_id}' must be a string or array of strings"
                )

            deduped_targets: list[str] = []
            seen_targets: set[str] = set()
            for target_id in normalized_targets:
                if target_id == source_id:
                    raise ValueError(
                        f"IB_MIRROR_MAP_JSON source id '{source_id}' cannot mirror to itself"
                    )
                if target_id in seen_targets:
                    continue
                seen_targets.add(target_id)
                deduped_targets.append(target_id)

            if deduped_targets:
                mirrors[source_id] = deduped_targets

        return mirrors


@dataclass(frozen=True)
class IBConnectionConfig:
    host: str
    port: int
    client_id: int
    account: str = ""


settings = Settings()


class TradeRequest(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    ticker: str = Field(min_length=1, max_length=32)
    action: str = Field(pattern="^(buy|sell)$")


class IBExecutor:
    def __init__(self, settings: Settings, connection: IBConnectionConfig) -> None:
        self.settings = settings
        self.connection = connection
        self.ib = IB()
        self.last_connect_attempt = 0.0
        self._lock = threading.Lock()

    @staticmethod
    def _ensure_thread_event_loop() -> None:
        try:
            asyncio.get_event_loop()
        except RuntimeError:
            asyncio.set_event_loop(asyncio.new_event_loop())

    def ensure_connected(self) -> None:
        self._ensure_thread_event_loop()

        if self.ib.isConnected():
            return

        now = time.time()
        if now - self.last_connect_attempt < 1:
            time.sleep(1)

        self.last_connect_attempt = time.time()
        self.ib.connect(
            host=self.connection.host,
            port=self.connection.port,
            clientId=self.connection.client_id,
            timeout=5,
            readonly=False,
            account=self.connection.account or "",
        )

    def place_market_order(self, ticker: str, action: str, quantity: int) -> dict:
        with self._lock:
            self.ensure_connected()

            contract = Stock(
                symbol=ticker.upper(),
                exchange=self.settings.default_exchange,
                currency=self.settings.default_currency,
            )
            qualified = self.ib.qualifyContracts(contract)
            if not qualified:
                raise RuntimeError(f"Contract qualification failed for ticker '{ticker}'")

            order = MarketOrder(action.upper(), quantity)
            order.tif = self.settings.default_tif
            order.outsideRth = self.settings.default_outside_rth
            if self.connection.account:
                order.account = self.connection.account

            qualified_contract = qualified[0]
            trade = self.ib.placeOrder(qualified_contract, order)
            self.ib.sleep(max(self.settings.order_status_wait_seconds, 0.2))

            status_text = trade.orderStatus.status if trade.orderStatus else "Unknown"
            if status_text.lower() in {"cancelled", "inactive", "api cancelled"}:
                broker_reason = ""
                if trade.log:
                    broker_reason = trade.log[-1].message or ""
                if not broker_reason:
                    broker_reason = trade.advancedError or "IB rejected/cancelled order"
                raise RuntimeError(f"IB order was {status_text}: {broker_reason}")

            return {
                "symbol": ticker.upper(),
                "action": action.lower(),
                "quantity": quantity,
                "order_id": trade.order.orderId if trade.order else None,
                "perm_id": trade.order.permId if trade.order else None,
                "status": status_text,
                "tif": order.tif,
                "outside_rth": bool(order.outsideRth),
                "account": order.account if hasattr(order, "account") else "",
                "ib_host": self.connection.host,
                "ib_port": self.connection.port,
                "ib_client_id": self.connection.client_id,
            }


class IBExecutorManager:
    def __init__(self, cfg: Settings) -> None:
        self.cfg = cfg
        self._default_executor = IBExecutor(
            cfg,
            IBConnectionConfig(
                host=cfg.ib_host,
                port=cfg.ib_port,
                client_id=cfg.ib_client_id,
                account=cfg.ib_account,
            ),
        )
        self._route_executors: dict[str, IBExecutor] = {
            bot_id: IBExecutor(cfg, route)
            for bot_id, route in cfg.bot_routes.items()
        }

    def get_executors(self, bot_id: str) -> list[tuple[str, IBExecutor]]:
        if self._route_executors:
            if bot_id not in self._route_executors:
                raise KeyError(f"No IB route configured for bot id '{bot_id}'")

            targets = [bot_id, *self.cfg.mirror_map.get(bot_id, [])]
            selected: list[tuple[str, IBExecutor]] = []
            seen_targets: set[str] = set()
            for target_id in targets:
                if target_id in seen_targets:
                    continue
                if target_id not in self._route_executors:
                    raise KeyError(f"No IB route configured for mirrored bot id '{target_id}'")
                seen_targets.add(target_id)
                selected.append((target_id, self._route_executors[target_id]))

            return selected

        return [(bot_id, self._default_executor)]

    def health(self) -> dict:
        if self._route_executors:
            return {
                bot_id: {
                    "connected": ex.ib.isConnected(),
                    "host": ex.connection.host,
                    "port": ex.connection.port,
                    "client_id": ex.connection.client_id,
                    "account": ex.connection.account,
                }
                for bot_id, ex in self._route_executors.items()
            }

        ex = self._default_executor
        return {
            "default": {
                "connected": ex.ib.isConnected(),
                "host": ex.connection.host,
                "port": ex.connection.port,
                "client_id": ex.connection.client_id,
                "account": ex.connection.account,
            }
        }


app = FastAPI(title="IBKR Trade Executor", version="1.0.0")
executors = IBExecutorManager(settings)


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "ib_connections": executors.health(),
    }


@app.post("/trade")
def trade(payload: TradeRequest) -> dict:
    if settings.allowed_bot_ids and payload.id not in settings.allowed_bot_ids:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Bot id '{payload.id}' is not allowed",
        )

    qty = settings.default_quantity
    if qty <= 0:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="DEFAULT_QUANTITY must be a positive integer",
        )

    try:
        route_executors = executors.get_executors(payload.id)
    except KeyError as exc:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=str(exc),
        ) from exc

    results: list[dict] = []
    failures: list[dict] = []
    for route_bot_id, executor in route_executors:
        try:
            route_result = executor.place_market_order(
                ticker=payload.ticker,
                action=payload.action,
                quantity=qty,
            )
            results.append(
                {
                    "bot_id": route_bot_id,
                    "result": route_result,
                }
            )
        except Exception as exc:
            failures.append(
                {
                    "bot_id": route_bot_id,
                    "error": str(exc),
                }
            )

    if failures:
        logger.exception(
            "Failed to place one or more IB orders for payload=%s failures=%s",
            payload.model_dump(),
            failures,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "message": "Failed to place one or more IB orders",
                "failures": failures,
                "succeeded": results,
            },
        )

    return {
        "accepted": True,
        "request": payload.model_dump(),
        "results": results,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host=settings.host, port=settings.port, reload=False)
