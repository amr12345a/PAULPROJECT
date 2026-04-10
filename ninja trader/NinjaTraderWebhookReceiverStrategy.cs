using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.NinjaScript;

namespace NinjaTrader.NinjaScript.Strategies
{
    public class NinjaTraderWebhookReceiverStrategy : Strategy
    {
        private sealed class TradeSignal
        {
            public string Id { get; set; } = string.Empty;
            public string Ticker { get; set; } = string.Empty;
            public string Instrument { get; set; } = string.Empty;
            public string Action { get; set; } = string.Empty;
            public int Quantity { get; set; } = 1;
            public int RetryCount { get; set; } = 0;
        }

        private readonly ConcurrentQueue<TradeSignal> signalQueue = new ConcurrentQueue<TradeSignal>();
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private readonly Dictionary<string, int> tickerToBarsIndex = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> tickerToInstrumentName = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private HttpListener listener;
        private Thread listenerThread;
        private volatile bool stopRequested;
        private Order entryOrder;
        private long signalSequence;

        private const int MaxSignalRetries = 20;

        [NinjaScriptProperty]
        public string ListenPrefix { get; set; } = "http://127.0.0.1:8000/api/v1/signal/";

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "NinjaTraderWebhookReceiverStrategy";
                Calculate = Calculate.OnEachTick;
                BarsRequiredToTrade = 0;
                TraceOrders = true;
                EntriesPerDirection = 10;
                EntryHandling = EntryHandling.AllEntries;
                RealtimeErrorHandling = RealtimeErrorHandling.StopCancelClose;
                IsExitOnSessionCloseStrategy = true;
            }
            else if (State == State.Configure)
            {
                ConfigureTickerRouting();
            }
            else if (State == State.Realtime)
            {
                StartListener();
            }
            else if (State == State.Terminated)
            {
                StopListener();
            }
        }

        protected override void OnBarUpdate()
        {
            if (BarsInProgress != 0)
            {
                return;
            }

            while (signalQueue.TryDequeue(out TradeSignal signal))
            {
                SubmitSignal(signal);
            }
        }

        private void ConfigureTickerRouting()
        {
            AddTickerSeries("ES");
            AddTickerSeries("MES");
            AddTickerSeries("NQ");
            AddTickerSeries("MNQ");
            AddTickerSeries("CL");
            AddTickerSeries("MCL");
            AddTickerSeries("GC");
            AddTickerSeries("MGC");
            AddTickerSeries("YM");
            AddTickerSeries("MYM");
            AddTickerSeries("RTY");
            AddTickerSeries("M2K");
        }

        private void AddTickerSeries(string ticker)
        {
            string primaryInstrument = Instrument != null && Instrument.MasterInstrument != null
                ? Instrument.MasterInstrument.Name
                : string.Empty;

            string instrumentName = ResolveInstrumentName(ticker);
            tickerToInstrumentName[ticker] = instrumentName;

            if (string.Equals(ticker, primaryInstrument, StringComparison.OrdinalIgnoreCase))
            {
                tickerToBarsIndex[ticker] = 0;
                Print($"Configured {ticker} -> primary series instrument '{Instrument.FullName}' (BarsInProgress 0)");
                return;
            }

            AddDataSeries(instrumentName, BarsPeriodType.Minute, 1);
            tickerToBarsIndex[ticker] = BarsArray.Length - 1;
            Print($"Configured {ticker} -> '{instrumentName}' (BarsInProgress {tickerToBarsIndex[ticker]})");
        }

        private string ResolveInstrumentName(string ticker)
        {
            string t = (ticker ?? string.Empty).Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(t))
            {
                return ticker;
            }

            string primaryFullName = Instrument != null ? Instrument.FullName : string.Empty;
            string[] parts = string.IsNullOrWhiteSpace(primaryFullName)
                ? Array.Empty<string>()
                : primaryFullName.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);

            if (parts.Length >= 2)
            {
                // If the strategy chart is on a specific contract (e.g. ES 06-26),
                // use the same expiry for all configured roots (e.g. MNQ 06-26).
                string expiry = parts[parts.Length - 1];
                return $"{t} {expiry}";
            }

            // Fallback to continuous contract notation for futures roots.
            return $"{t} ##-##";
        }

        protected override void OnOrderUpdate(Order order, double limitPrice, double stopPrice, int quantity, int filled, double averageFillPrice, OrderState orderState, DateTime time, ErrorCode error, string comment)
        {
            if (order != null)
            {
                string instrumentName = order.Instrument != null ? order.Instrument.FullName : "(unknown)";
                Print($"Order update: {order.Name} {orderState} instrument={instrumentName} qty={quantity} filled={filled} error={error} comment={comment}");
            }
        }

        protected override void OnExecutionUpdate(Execution execution, string executionId, double price, int quantity, MarketPosition marketPosition, string orderId, DateTime time)
        {
            Print($"Execution: {executionId} price={price} qty={quantity} position={marketPosition}");
        }

        private void SubmitSignal(TradeSignal signal)
        {
            string rawTicker = string.IsNullOrWhiteSpace(signal.Ticker) ? signal.Instrument : signal.Ticker;
            string ticker = NormalizeTicker(rawTicker);
            if (string.IsNullOrEmpty(ticker))
            {
                Print($"Ignored signal {signal.Id}: missing ticker/instrument");
                return;
            }

            if (!tickerToBarsIndex.TryGetValue(ticker, out int barsIndex))
            {
                Print($"Ignored signal {signal.Id}: ticker '{ticker}' is not preconfigured in the strategy");
                return;
            }

            if (barsIndex < 0 || barsIndex >= BarsArray.Length)
            {
                Print($"Ignored signal {signal.Id}: bars index {barsIndex} is out of range for ticker '{ticker}'");
                return;
            }

            if (CurrentBars == null || barsIndex >= CurrentBars.Length || CurrentBars[barsIndex] < 0)
            {
                signal.RetryCount += 1;
                if (signal.RetryCount <= MaxSignalRetries)
                {
                    signalQueue.Enqueue(signal);
                    Print($"Deferred signal {signal.Id}: no bars loaded yet for ticker '{ticker}' (retry {signal.RetryCount}/{MaxSignalRetries})");
                }
                else
                {
                    string configured = tickerToInstrumentName.ContainsKey(ticker) ? tickerToInstrumentName[ticker] : "(unknown)";
                    Print($"Ignored signal {signal.Id}: bars never loaded for ticker '{ticker}' mapped to '{configured}' after {MaxSignalRetries} retries");
                }
                return;
            }

            int quantity = signal.Quantity > 0 ? signal.Quantity : 1;

            string signalName = $"{ticker}-{signal.Id}";

            if (string.Equals(signal.Action, "buy", StringComparison.OrdinalIgnoreCase))
            {
                entryOrder = EnterLong(barsIndex, quantity, signalName);
            }
            else if (string.Equals(signal.Action, "sell", StringComparison.OrdinalIgnoreCase))
            {
                entryOrder = EnterShort(barsIndex, quantity, signalName);
            }
            else
            {
                Print($"Ignored signal with unsupported action: {signal.Action}");
            }
        }

        private string NormalizeTicker(string value)
        {
            string raw = (value ?? string.Empty).Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(raw))
            {
                return string.Empty;
            }

            // Some providers send exchange-prefixed symbols like CME_MINI:MNQ1!
            int colonIndex = raw.LastIndexOf(':');
            if (colonIndex >= 0 && colonIndex < raw.Length - 1)
            {
                raw = raw.Substring(colonIndex + 1);
            }

            // Bridge may send full futures contract names like "NQ 06-26".
            string[] parts = raw.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            string token = parts.Length > 0 ? parts[0] : raw;

            // Remove TradingView/continuous-contract marker.
            token = token.Replace("!", string.Empty);

            // Remove trailing digits used by some feeds for continuous contracts (e.g. ES1, MNQ1).
            while (token.Length > 0 && char.IsDigit(token[token.Length - 1]))
            {
                token = token.Substring(0, token.Length - 1);
            }

            return token;
        }

        private void StartListener()
        {
            if (listenerThread != null)
            {
                return;
            }

            stopRequested = false;
            listener = new HttpListener();
            listener.Prefixes.Add(ListenPrefix);
            listener.Start();

            listenerThread = new Thread(ListenLoop)
            {
                IsBackground = true,
                Name = "NinjaTraderWebhookReceiverStrategy.HttpListener"
            };
            listenerThread.Start();
        }

        private void StopListener()
        {
            stopRequested = true;

            try
            {
                listener?.Stop();
            }
            catch
            {
            }

            try
            {
                listener?.Close();
            }
            catch
            {
            }

            listener = null;
            listenerThread = null;
        }

        private void ListenLoop()
        {
            while (!stopRequested && listener != null)
            {
                HttpListenerContext context = null;

                try
                {
                    context = listener.GetContext();
                }
                catch (HttpListenerException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }

                if (context == null)
                {
                    continue;
                }

                try
                {
                    using (var reader = new StreamReader(context.Request.InputStream, context.Request.ContentEncoding ?? Encoding.UTF8))
                    {
                        string body = reader.ReadToEnd();
                        var signal = serializer.Deserialize<TradeSignal>(body) ?? new TradeSignal();
                        if (string.IsNullOrWhiteSpace(signal.Id))
                        {
                            signal.Id = $"auto-{Interlocked.Increment(ref signalSequence)}-{DateTime.Now.Ticks}";
                        }

                        if (signal.Quantity <= 0)
                        {
                            signal.Quantity = 1;
                        }

                        signalQueue.Enqueue(signal);
                    }

                    context.Response.StatusCode = 202;
                    byte[] responseBytes = Encoding.UTF8.GetBytes("accepted");
                    context.Response.ContentType = "text/plain";
                    context.Response.OutputStream.Write(responseBytes, 0, responseBytes.Length);
                }
                catch (Exception ex)
                {
                    try
                    {
                        context.Response.StatusCode = 500;
                        byte[] responseBytes = Encoding.UTF8.GetBytes(ex.Message);
                        context.Response.ContentType = "text/plain";
                        context.Response.OutputStream.Write(responseBytes, 0, responseBytes.Length);
                    }
                    catch
                    {
                    }
                }
                finally
                {
                    try
                    {
                        context.Response.OutputStream.Close();
                    }
                    catch
                    {
                    }
                }
            }
        }
    }
}