import os
import time
import asyncio
import threading
from dataclasses import dataclass

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, status
from ib_insync import IB, MarketOrder, Stock
from pydantic import BaseModel, Field

load_dotenv()


@dataclass
class Settings:
    ib_host: str = os.getenv("IB_HOST", "127.0.0.1")
    ib_port: int = int(os.getenv("IB_PORT", "7497"))
    ib_client_id: int = int(os.getenv("IB_CLIENT_ID", "101"))
    ib_account: str = os.getenv("IB_ACCOUNT", "")

    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "8080"))

    default_exchange: str = os.getenv("DEFAULT_EXCHANGE", "SMART")
    default_currency: str = os.getenv("DEFAULT_CURRENCY", "USD")
    default_order_type: str = os.getenv("DEFAULT_ORDER_TYPE", "MKT")
    default_quantity: int = int(os.getenv("DEFAULT_QUANTITY", "1"))
    allowed_bot_ids: set[str] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        allowed = os.getenv("ALLOWED_BOT_IDS", "").strip()
        if allowed:
            self.allowed_bot_ids = {x.strip() for x in allowed.split(",") if x.strip()}
        else:
            self.allowed_bot_ids = set()


settings = Settings()


class TradeRequest(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    ticker: str = Field(min_length=1, max_length=32)
    action: str = Field(pattern="^(buy|sell)$")


class IBExecutor:
    def __init__(self, cfg: Settings) -> None:
        self.cfg = cfg
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
            host=self.cfg.ib_host,
            port=self.cfg.ib_port,
            clientId=self.cfg.ib_client_id,
            timeout=5,
            readonly=False,
            account=self.cfg.ib_account or "",
        )

    def place_market_order(self, ticker: str, action: str, quantity: int) -> dict:
        with self._lock:
            self.ensure_connected()

            contract = Stock(
                symbol=ticker.upper(),
                exchange=self.cfg.default_exchange,
                currency=self.cfg.default_currency,
            )
            qualified = self.ib.qualifyContracts(contract)
            if not qualified:
                raise RuntimeError(f"Contract qualification failed for ticker '{ticker}'")

            order = MarketOrder(action.upper(), quantity)
            if self.cfg.ib_account:
                order.account = self.cfg.ib_account

            trade = self.ib.placeOrder(contract, order)
            self.ib.sleep(0.5)

            status_text = trade.orderStatus.status if trade.orderStatus else "Unknown"
            return {
                "symbol": ticker.upper(),
                "action": action.lower(),
                "quantity": quantity,
                "order_id": trade.order.orderId if trade.order else None,
                "perm_id": trade.order.permId if trade.order else None,
                "status": status_text,
            }


app = FastAPI(title="IBKR Trade Executor", version="1.0.0")
executor = IBExecutor(settings)


@app.get("/health")
def health() -> dict:
    connected = executor.ib.isConnected()
    return {
        "ok": True,
        "ib_connected": connected,
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
        result = executor.place_market_order(
            ticker=payload.ticker,
            action=payload.action,
            quantity=qty,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to place IB order: {exc}",
        ) from exc

    return {
        "accepted": True,
        "request": payload.model_dump(),
        "result": result,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host=settings.host, port=settings.port, reload=False)
