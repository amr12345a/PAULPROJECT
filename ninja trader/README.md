# NinjaTrader Signal Bridge (FastAPI)

This service receives webhook trade signals and forwards them to a NinjaTrader NinjaScript strategy endpoint. It does not place orders by itself. Your NinjaScript strategy must receive the signal and submit the actual trade in NinjaTrader.

## Network setup

- Bind address: `0.0.0.0`
- Default app port: `8080`
- Public access: open `8080/tcp` on Windows Firewall (and cloud firewall/security group if this host is in the cloud).

## What the bridge sends to NinjaTrader

The bridge converts a webhook like this:

```json
{"id":"bot-1","ticker":"NQ","action":"sell"}
```

into a NinjaTrader strategy request with fields like:

```json
{
  "instrument": "NQ",
  "action": "sell",
  "quantity": 1,
  "account": "Sim101",
  "order_type": "Market",
  "signal_mode": "market"
}
```

Your NinjaScript strategy must map those fields to the order entry logic you want.

## Local run

1. Install Python 3.12 or 3.13.

2. Create and activate the virtual environment:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

3. Create the environment file:

```powershell
Copy-Item .env.example .env
```

4. Set values in `.env`:

- `NT_STRATEGY_URL`: HTTP endpoint exposed by your NinjaScript signal receiver strategy.
- `NT_ACCOUNT`: NinjaTrader account name, for example `Sim101` or `Live01`.
- `NT_INSTRUMENT_PREFIX`: Optional contract suffix to append, for example `Z2` to convert `ES` into `ES Z2`.
- `NT_API_KEY`: Optional Bearer token if your strategy endpoint requires auth.
- `DEFAULT_QUANTITY`: Order size sent for each signal.
- `PORT`: Keep `8080` for public deployment, or change it if you know the new port is open and matched everywhere.

5. Start the bridge:

```powershell
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8080
```

## Windows deployment

1. Run the deployment script from the `ninja trader` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy_windows.ps1 -CreateScheduledTask -OpenFirewall
```

2. Allow inbound `8080/tcp` in Windows Firewall if you want to reach the bridge from another machine.

3. Start or verify the bridge:

```powershell
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8080
```

## NinjaTrader setup

1. Create or enable a NinjaScript strategy that listens on the URL in `NT_STRATEGY_URL`.

2. Make sure the strategy can receive POST requests and translate the payload into order placement.

3. Use `Sim101` first. Do not switch to a live account until the full signal path is verified.

4. Confirm the strategy is attached, enabled, and allowed to trade on the chosen account.

## How to make it trade correctly

1. Start NinjaTrader and make sure the strategy endpoint is running.

2. Set `NT_STRATEGY_URL` to the exact NinjaTrader listener URL, for example `http://127.0.0.1:8000/api/v1/signal` on the same machine.

3. Set `NT_ACCOUNT` to the account you actually want to trade, for example `Sim101` for testing.

4. Set `NT_INSTRUMENT_PREFIX` only if your strategy expects a contract suffix such as `Z2`.

5. Start the bridge and verify `GET /health` returns `ok: true`.

6. Send a test webhook to `POST /trade` and confirm NinjaTrader receives the signal.

7. Check NinjaTrader logs, the strategy output, and the account/order tab to verify the order was created.

## Test with curl

```powershell
curl -Method POST "http://YOUR_PUBLIC_IP:8080/trade" `
  -Headers @{"content-type"="application/json"} `
  -Body '{"id":"my-bot2","ticker":"AAPL","action":"buy"}'
```

## Security notes

- Keep the bridge behind a reverse proxy if you can.
- Restrict firewall access to only the IPs that need to send trade webhooks.
- Use HTTPS for production.
- Test with simulated trading before going live.