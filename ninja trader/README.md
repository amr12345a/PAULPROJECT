# NinjaTrader Signal Bridge (FastAPI)

HTTP service that receives trade signals and forwards them to a NinjaTrader NinjaScript strategy endpoint. This subproject is now Windows-first: install and run it on the same Windows host as NinjaTrader, or on any Windows machine that can reach your NinjaScript HTTP endpoint.

## Request format
1. Install Python 3.11+ on Windows.

2. Create and activate environment:
`POST /trade`
```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```json
{"id":"bot-1","ticker":"NQ","action":"sell"}
3. Create env file:

```powershell

- `content-type: application/json`

4. Set values in `.env`:

- `NT_STRATEGY_URL`: HTTP endpoint of your NinjaScript signal receiver strategy.
- `NT_ACCOUNT`: Your NinjaTrader account name (e.g., `Sim101`, `Live01`).
- `NT_INSTRUMENT_PREFIX`: Optional contract month/year to append (for example `Z2` to convert `ES` to `ES Z2`).
- `NT_API_KEY`: If your strategy endpoint requires authentication, set this Bearer token.
- `DEFAULT_QUANTITY`: Default order quantity per signal.
## Local run

1. Create and activate environment:
```powershell
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
5. Start service:

```powershell
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 80
```bash
cp .env.example .env
```

3. Set values in `.env`:

- `NT_STRATEGY_URL`: HTTP endpoint of your NinjaScript signal receiver strategy.
- `NT_ACCOUNT`: Your NinjaTrader account name (e.g., `Sim101`, `Live01`).
- `NT_INSTRUMENT_PREFIX`: Optional contract month/year to append (e.g., set to `Z2` to convert ticker `ES` → `ES Z2`).
- `NT_API_KEY`: If your strategy endpoint requires authentication, set this Bearer token.
- `DEFAULT_QUANTITY`: Default order quantity per signal.

Example with simulated account:

```bash
NT_STRATEGY_URL=http://127.0.0.1:8000/api/v1/signal
NT_ACCOUNT=Sim101
NT_INSTRUMENT_PREFIX=Z2
```

4. Start service:

```bash
uvicorn main:app --host 0.0.0.0 --port 80
```

## Test with curl

```bash
curl -X POST "http://13.53.172.241/trade" \
  -H "content-type: application/json" \
  -d '{"id":"my-bot2","ticker":"AAPL","action":"buy"}'
```

## Windows deployment

1. Open PowerShell as Administrator if you want the script to create the startup task.

2. Run the deployment script from the `ninja trader` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy_windows.ps1 -CreateScheduledTask
```

3. The deployment script will:

- Create a Python virtual environment.
- Install the Python dependencies.
- Copy `.env.example` to `.env` if needed.
- Create `start_windows.ps1` to launch the bridge with Uvicorn.
- Register a Windows Scheduled Task named `NinjaTraderTradeExecutor` when requested.

4. Windows Firewall:

- Allow inbound `80/tcp` or whatever port you set in `.env`.
- If the bridge only serves your local NinjaTrader instance, keep it bound to `127.0.0.1` and do not open the port publicly.

5. Start or verify the bridge:

```powershell
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 80
```

6. View logs:

```powershell
Get-ScheduledTask -TaskName NinjaTraderTradeExecutor -ErrorAction SilentlyContinue
```

7. Access and configure:

- Set `NT_STRATEGY_URL` to the HTTP endpoint exposed by your NinjaScript strategy.
- Run NinjaTrader on Windows and make sure the strategy endpoint is listening.
- Test the bridge with `POST http://<windows-host>/trade`.

## NinjaScript Signal Strategy Setup

To receive signals from this bridge, create a NinjaScript strategy with an HTTP endpoint listener:

### Minimal NinjaScript Example (C#)

```csharp
protected override void OnBarClose()
{
    // Your trading logic here
}

// Example: OnReceiveSignal endpoint
// Listen on http://127.0.0.1:8000/api/v1/signal
// Expected JSON:
// {
//   "instrument": "ES Z2",
//   "action": "buy" or "sell",
//   "quantity": 1,
//   "account": "Sim101",
//   "order_type": "Market",
//   "signal_mode": "market"
// }
```

### Setup checklist

1. Create or enable HTTP listener in your NinjaScript strategy.
2. Configure strategy to accept POST signals on `NT_STRATEGY_URL`.
3. Map `instrument`, `action`, `quantity` to your order entry logic.
4. Test with simulated account first (`Sim101`).
5. Validate signal payload format and error handling.

### Notes

- Signals route to one fixed NinjaTrader account per deployment.
- Instrument names can be auto-formatted via `NT_INSTRUMENT_PREFIX` (e.g., convert `ES` → `ES Z2`).
- Order type defaults to `Market`; adapt in strategy if needed.
- Response status 200+ is success; 400+ is failure.

## Security recommendations

- Keep direct app access restricted if you deploy a reverse proxy.
- Prefer HTTPS (for example, via IIS, nginx on Windows, or a reverse proxy) for production.
