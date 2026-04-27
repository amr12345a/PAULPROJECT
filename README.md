# IBKR Trade Executor (FastAPI, Windows)

Simple HTTP service that receives JSON trade signals and sends orders to Interactive Brokers (TWS or IB Gateway).

## Request format

`POST /trade`

```json
{"id":"my-bot2","ticker":"AAPL","action":"buy"}
```

```json
{"id":"my-bot2","ticker":"AAPL","action":"sell"}
```

Headers:

- `content-type: application/json`

## What this service does

- Accepts `id`, `ticker`, `action`.
- Optionally restricts allowed bot IDs.
- Routes each `id` to its own IB Gateway/API connection (optional, via config).
- Can mirror one incoming bot `id` to additional route IDs (fan-out), so one webhook executes on multiple gateways/accounts.
- Sends a market order (`BUY` / `SELL`) with configured quantity.

## Local run on Windows

1. Create and activate environment:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

2. Create env file:

```powershell
Copy-Item .env.example .env
```

3. Set values in `.env`:

- `IB_HOST`, `IB_PORT`, `IB_CLIENT_ID` (single-route fallback)
- `IB_BOT_CONFIGS_JSON` (recommended for one gateway/account per `id`)
- `IB_MIRROR_MAP_JSON` (optional fan-out/mirroring map)
- `ALLOWED_BOT_IDS` (comma separated)
- `DEFAULT_QUANTITY`

Example for one gateway/account per bot ID:

```dotenv
IB_BOT_CONFIGS_JSON={"mybot1":{"host":"127.0.0.1","port":4001,"client_id":101,"account":"DU111111"},"mybot2":{"host":"127.0.0.1","port":4001,"client_id":102,"account":"DU111111"},"mybot3":{"host":"127.0.0.1","port":4002,"client_id":201,"account":"DU222222"},"mybot4":{"host":"127.0.0.1","port":4002,"client_id":202,"account":"DU222222"}}
IB_MIRROR_MAP_JSON={"mybot1":["mybot3"],"mybot2":["mybot4"]}
ALLOWED_BOT_IDS=mybot1,mybot2,mybot3,mybot4
```

4. Start service:

```powershell
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8080
```

## Windows deployment (recommended)

Use the provided deployment script from this folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy_windows.ps1 -CreateScheduledTask -OpenFirewall -Port 8080
```

What it does:

- Copies the app to `C:\ProgramData\IBKRTradeExecutor`
- Creates `.venv` and installs dependencies
- Creates `.env` from `.env.example` (if missing)
- Optionally opens Windows Firewall inbound TCP rule
- Optionally creates a startup scheduled task (`IBKRTradeExecutor`)

For a one-step bootstrap that also installs Python and can install IB Gateway from a provided installer path or URL, run:

```bat
install_ibkr_windows.bat
```

If you need IB Gateway to be downloaded automatically, set `IB_GATEWAY_INSTALLER_URL` before running the batch file. If you already have the installer locally, set `IB_GATEWAY_INSTALLER_PATH` instead.

Manual start command:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\IBKRTradeExecutor\start_windows.ps1"
```

Health check:

```powershell
curl http://localhost:8080/health
```

## IB setup on Windows (TWS or IB Gateway)

1. Install TWS or IB Gateway on Windows.
2. Log in once manually and keep the platform updated.
3. In API settings, enable:
- `Enable ActiveX and Socket Clients`
- `Socket Port`: usually `7497` for paper TWS, or set your IB Gateway port like `4001`
- `Read-Only API`: disabled (must be off to place orders)
- Trusted hosts/IPs should include where this FastAPI app runs (often `127.0.0.1`)
4. Set matching values in `.env` (`IB_HOST`, `IB_PORT`, `IB_CLIENT_ID`, optional `IB_ACCOUNT`).
5. Restart the executor if you change IB settings.

For multiple IB Gateways/accounts, use:

- `IB_BOT_CONFIGS_JSON` with one object per bot `id`
- Different `port` and `client_id` per configured route
- Optional `IB_MIRROR_MAP_JSON` for fan-out/mirroring behavior

## Test webhook

```powershell
python .\test_webhook.py --url http://127.0.0.1:8080/trade --bot-id mybot2 --ticker AAPL --action buy
```

## Important IBKR notes

- Use paper trading first.
- `IB_CLIENT_ID` must be unique per active API session.
- If `/health` reports disconnected IB, verify login/session status and API socket settings in IB app.

## Security recommendations

- Restrict firewall rule source IPs to known webhook senders.
- Prefer HTTPS via reverse proxy if exposing public internet endpoints.
- Keep credentials and account IDs only in `.env` and never commit secrets.
