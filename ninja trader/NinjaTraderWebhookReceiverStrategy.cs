using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using NinjaTrader.Cbi;
using NinjaTrader.NinjaScript;

namespace NinjaTrader.NinjaScript.Strategies
{
    public class NinjaTraderWebhookReceiverStrategy : Strategy
    {
        private sealed class TradeSignal
        {
            public string Id { get; set; } = string.Empty;
            public string Ticker { get; set; } = string.Empty;
            public string Action { get; set; } = string.Empty;
            public int Quantity { get; set; } = 1;
        }

        private readonly ConcurrentQueue<TradeSignal> signalQueue = new ConcurrentQueue<TradeSignal>();
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private HttpListener listener;
        private Thread listenerThread;
        private volatile bool stopRequested;
        private Order entryOrder;

        [NinjaScriptProperty]
        public string ListenPrefix { get; set; } = "http://127.0.0.1:8000/api/v1/signal/";

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "NinjaTraderWebhookReceiverStrategy";
                Calculate = Calculate.OnEachTick;
                EntriesPerDirection = 1;
                EntryHandling = EntryHandling.AllEntries;
                RealtimeErrorHandling = RealtimeErrorHandling.StopCancelClose;
                IsExitOnSessionCloseStrategy = true;
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
            while (signalQueue.TryDequeue(out TradeSignal signal))
            {
                SubmitSignal(signal);
            }
        }

        protected override void OnOrderUpdate(Order order, double limitPrice, double stopPrice, int quantity, int filled, double averageFillPrice, OrderState orderState, DateTime time, ErrorCode error, string comment)
        {
            if (entryOrder != null && order != null && order.Name == entryOrder.Name)
            {
                Print($"Order update: {order.Name} {orderState} qty={quantity} filled={filled} error={error} comment={comment}");
            }
        }

        protected override void OnExecutionUpdate(Execution execution, string executionId, double price, int quantity, MarketPosition marketPosition, string orderId, DateTime time)
        {
            Print($"Execution: {executionId} price={price} qty={quantity} position={marketPosition}");
        }

        private void SubmitSignal(TradeSignal signal)
        {
            if (string.Equals(signal.Action, "buy", StringComparison.OrdinalIgnoreCase))
            {
                entryOrder = EnterLong(signal.Quantity, signal.Id);
            }
            else if (string.Equals(signal.Action, "sell", StringComparison.OrdinalIgnoreCase))
            {
                entryOrder = EnterShort(signal.Quantity, signal.Id);
            }
            else
            {
                Print($"Ignored signal with unsupported action: {signal.Action}");
            }
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