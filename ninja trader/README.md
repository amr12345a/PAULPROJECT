# NinjaTrader Signal Bridge (FastAPI)

HTTP service that receives trade signals and forwards them to a NinjaTrader NinjaScript strategy endpoint. Bridges external signal sources (bots, indicators, webhooks) to your NinjaTrader account.

## Request format

`POST /trade`

```json
{"id":"bot-1","ticker":"ES","action":"buy"}
```

```json
{"id":"bot-1","ticker":"NQ","action":"sell"}
```

Headers:

- `content-type: application/json`

## What this service does

- Accepts signal `id`, instrument ticker/symbol, and `action` (buy/sell).
- Routes signals to a single NinjaTrader account.
- Transforms ticker symbols into NinjaTrader instrument names (with optional prefix/contract).
- Forwards signal as JSON POST to your NinjaScript signal receiver strategy HTTP endpoint.

## Local run

1. Create and activate environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

2. Create env file:

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

## Ubuntu AWS deployment

1. Install system packages:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx wine wine64 winetricks
```

2. Copy project to server:

```bash
sudo mkdir -p /opt/ninja-trader-executor
sudo chown -R $USER:$USER /opt/ninja-trader-executor
# copy files into /opt/ninja-trader-executor
```

3. Install dependencies and setup VNC + NinjaTrader:

```bash
cd /opt/ninja-trader-executor
# Edit .env and set:
# - NT_INSTALLER_URL (download link to NinjaTrader installer)
# - NT_STRATEGY_URL (your strategy HTTP endpoint)
# - VNC_PASSWORD (change from default)
cp .env.example .env
nano .env  # or your favorite editor

bash deploy_ubuntu.sh
```

4. The deployment script will:
   - Create Python venv and install requirements
   - Set up TigerVNC on port 5901 (DISPLAY :1)
   - Download and install NinjaTrader (if NT_INSTALLER_URL provided)
   - Start NinjaTrader in VNC (visible via remote desktop)
   - Install systemd services for both ninja-trader-executor and ninjatrader
   - Configure nginx if PORT != 80

5. AWS Security Group rules:

5. AWS Security Group rules:

- Allow inbound `80/tcp` from your signal source IP(s).
- Allow inbound `5901/tcp` (VNC) only from your client/admin IPs.
- Keep internal app/API ports closed to the internet.
- Keep SSH `22/tcp` restricted to your admin IP.

6. View logs:

```bash
# Signal bridge service
journalctl -u ninja-trader-executor -f

# NinjaTrader service
journalctl -u ninjatrader -f

# System/VNC logs
tail -f /var/log/syslog
```

7. Access and configure:

- **VNC Desktop (port 5901):** Connect with VNC client to `<server-ip>:5901` → password set in `.env`
- **NinjaTrader Window:** Should be visible in VNC display after systemd starts it
- **Signal Bridge Health:** `curl http://<server-ip>/health`
- **Place trades:** `POST http://<server-ip>/trade` with signal payload

8. First-time setup via VNC:

- Connect to VNC (port 5901)
- Open NinjaTrader window in desktop
- Log into your NinjaTrader account (Sim or Live)
- Configure your signal-receiving strategy in NinjaScript
- Verify strategy HTTP endpoint is running and listening on `NT_STRATEGY_URL`
- Test webhook from signal bridge: `curl -X POST http://localhost/trade -H "Content-Type: application/json" -d '{"id":"test","ticker":"ES","action":"buy"}'`

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

## VNC access for client credential input

- The deploy script installs XFCE + TigerVNC and starts `tigervnc` on display `:1`.
- Default VNC port is `5901`.
- Set `VNC_PASSWORD` in `.env` before deployment (or update it on server and rerun deploy).
- Connect with any VNC client to `<server-ip>:5901`.

## Security recommendations

- Keep direct app access restricted if you deploy a reverse proxy.
- Prefer HTTPS (Let's Encrypt) for production.
