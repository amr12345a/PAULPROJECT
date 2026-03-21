# IBKR Trade Executor (FastAPI)

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
- Sends a market order (`BUY` / `SELL`) with configured quantity.

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

- `IB_HOST`, `IB_PORT`, `IB_CLIENT_ID`
- `ALLOWED_BOT_IDS` (comma separated)
- `DEFAULT_QUANTITY`

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
sudo apt install -y python3 python3-venv python3-pip nginx
```

2. Copy project to server:

```bash
sudo mkdir -p /opt/ib-trade-executor
sudo chown -R $USER:$USER /opt/ib-trade-executor
# copy files into /opt/ib-trade-executor
```

3. Install dependencies:

```bash
cd /opt/ib-trade-executor
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
cp .env.example .env
# edit .env with your values
```

4. Install systemd service:

```bash
sudo cp ib-trade-executor.service /etc/systemd/system/ib-trade-executor.service
sudo systemctl daemon-reload
sudo systemctl enable ib-trade-executor
sudo systemctl start ib-trade-executor
sudo systemctl status ib-trade-executor
```

5. Configure Nginx for port 80:

```bash
sudo cp ib-trade-executor.nginx /etc/nginx/sites-available/ib-trade-executor
sudo ln -sf /etc/nginx/sites-available/ib-trade-executor /etc/nginx/sites-enabled/ib-trade-executor
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
```

6. AWS Security Group:

- Allow inbound `80/tcp` from your signal source IP(s).
- If running behind Nginx, keep the app bound to loopback and keep internal app ports closed to the internet.
- Keep SSH `22/tcp` restricted to your admin IP.

7. View logs:

```bash
journalctl -u ib-trade-executor -f
sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log
```

8. Validate through Nginx (port 80):

```bash
curl http://13.53.172.241/health

curl -X POST "http://13.53.172.241/trade" \
  -H "content-type: application/json" \
  -d '{"id":"my-bot2","ticker":"AAPL","action":"buy"}'
```

## IB setup on Ubuntu AWS (TWS or IB Gateway)

You can run either TWS or IB Gateway. For servers, IB Gateway is usually preferred.

1. Prepare GUI dependencies (for first-time setup):

```bash
sudo apt update
sudo apt install -y default-jre xvfb libxtst6 libxrender1 libxi6
```

2. Install IB Gateway or TWS:

- Download installer from Interactive Brokers Client Portal.
- Install under a path like `/opt/ibgateway` (or `/opt/ib-tws`).

3. Start IB Gateway/TWS on the server (example with virtual display):

```bash
xvfb-run -a /opt/ibgateway/ibgateway
```

4. In IB Gateway/TWS API settings, enable:

- `Enable ActiveX and Socket Clients`
- `Socket Port`: use `7497` for paper (or `7496` for live)
- `Read-Only API`: disabled (must be off to place orders)
- `Trusted IPs`: include `127.0.0.1` (and any private IP if needed)

5. Set matching values in `.env`:

- `IB_HOST=127.0.0.1`
- `IB_PORT=7497` (paper) or `7496` (live)
- `IB_CLIENT_ID=101` (any unused integer)
- Optional: `IB_ACCOUNT=<your account id>`

6. Restart executor after IB settings changes:

```bash
sudo systemctl restart ib-trade-executor
```

7. Connectivity checks:

- `curl http://127.0.0.1/health` should show `"ib_connected": true`.
- If `false`, check IB app is logged in and API socket settings are enabled.

## Important IBKR notes

- Use `IB_PORT=7497` for paper TWS by default (often `7496` for live).
- In TWS/IB Gateway API settings, enable socket clients and allow your server IP.
- `IB_CLIENT_ID` must be unique per connection.
- Start with paper trading before live trading.

## Security recommendations

- Keep direct app access restricted if you deploy a reverse proxy.
- Prefer HTTPS (Let's Encrypt) for production.

