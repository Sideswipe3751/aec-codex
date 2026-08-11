using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Aec.Codex.Bridge;

public sealed class ConnectorServer : IDisposable
{
    private readonly IConnectorExecutor _executor;
    private readonly ConnectorOptions _options;
    private readonly ConcurrentDictionary<string, ConnectorRequest> _requests =
        new ConcurrentDictionary<string, ConnectorRequest>(StringComparer.Ordinal);
    private readonly CancellationTokenSource _stop = new CancellationTokenSource();
    private HttpListener? _listener;
    private Thread? _listenerThread;
    private InstanceRegistry? _registry;
    private string _token = "";
    private int _disposed;

    public ConnectorServer(IConnectorExecutor executor, ConnectorOptions? options = null)
    {
        _executor = executor ?? throw new ArgumentNullException(nameof(executor));
        _options = options ?? new ConnectorOptions();
    }

    public int Port { get; private set; }
    public bool IsRunning => _listener?.IsListening == true;

    public void Start()
    {
        if (IsRunning) return;
        if (!string.Equals(_options.BindHost, "127.0.0.1", StringComparison.Ordinal))
            throw new InvalidOperationException("AEC Codex connectors may bind only to 127.0.0.1");

        var info = _executor.GetCachedInfo() ?? throw new InvalidOperationException("Connector info is unavailable");
        ValidateInfo(info);
        _token = CreateToken();
        Exception? lastError = null;
        for (var offset = 0; offset < _options.PortFallbackCount; offset++)
        {
            var port = _options.Port + offset;
            var listener = new HttpListener();
            listener.Prefixes.Add($"http://127.0.0.1:{port}/");
            try
            {
                listener.Start();
                _listener = listener;
                Port = port;
                break;
            }
            catch (Exception ex)
            {
                lastError = ex;
                listener.Close();
            }
        }
        if (_listener == null)
            throw new InvalidOperationException("Unable to bind an AEC Codex loopback port", lastError);

        _registry = new InstanceRegistry(_options.InstanceDirectory, info.InstanceId);
        WriteDescriptor(info);
        _listenerThread = new Thread(ListenLoop)
        {
            IsBackground = true,
            Name = "AEC Codex Connector HTTP"
        };
        _listenerThread.Start();
    }

    public void RefreshDescriptor()
    {
        if (!IsRunning || _registry == null) return;
        WriteDescriptor(_executor.GetCachedInfo());
    }

    private void WriteDescriptor(ConnectorInfo info)
    {
        _registry!.Write(new ConnectorInstanceDescriptor
        {
            ProtocolVersion = 1,
            InstanceId = info.InstanceId,
            Application = info.Application,
            ApplicationVersion = info.ApplicationVersion,
            ProcessId = info.ProcessId,
            Url = $"http://127.0.0.1:{Port}",
            Token = _token,
            StartedAtUtc = DateTime.UtcNow.ToString("o"),
            Document = info.Document,
            Capabilities = info.Capabilities
        });
    }

    private void ListenLoop()
    {
        while (!_stop.IsCancellationRequested && _listener?.IsListening == true)
        {
            try
            {
                var context = _listener.GetContext();
                ThreadPool.QueueUserWorkItem(_ => Handle(context));
            }
            catch (HttpListenerException) when (_stop.IsCancellationRequested) { break; }
            catch (ObjectDisposedException) { break; }
            catch { if (_stop.IsCancellationRequested) break; }
        }
    }

    private void Handle(HttpListenerContext context)
    {
        try
        {
            context.Response.Headers["Cache-Control"] = "no-store";
            if (!IsAuthorized(context.Request))
            {
                WriteJson(context, 401, new { error = "unauthorized" });
                return;
            }
            var method = context.Request.HttpMethod.ToUpperInvariant();
            var path = context.Request.Url?.AbsolutePath.TrimEnd('/') ?? "";
            if (method == "GET" && path == "/v1/info")
            {
                WriteJson(context, 200, _executor.GetCachedInfo());
                return;
            }
            if (method == "GET" && path == "/v1/selection")
            {
                HandleSelection(context);
                return;
            }
            if (method == "POST" && path == "/v1/execute")
            {
                HandleExecute(context);
                return;
            }
            if (path.StartsWith("/v1/requests/", StringComparison.Ordinal))
            {
                HandleRequestRoute(context, method, path);
                return;
            }
            WriteJson(context, 404, new { error = "not_found" });
        }
        catch (RequestBodyTooLargeException)
        {
            WriteJson(context, 413, new { error = "request_too_large" });
        }
        catch (JsonCodecException ex)
        {
            WriteJson(context, 400, new { error = "invalid_json", message = ex.Message });
        }
        catch (Exception ex)
        {
            WriteJson(context, 500, new { error = "internal_error", message = ex.Message });
        }
        finally
        {
            try { context.Response.Close(); } catch { }
        }
    }

    private void HandleSelection(HttpListenerContext context)
    {
        var request = new ConnectorRequest(
            ConnectorRequestKind.Selection,
            "read",
            "Read current selection",
            "",
            Math.Min(10, _options.DefaultTimeoutSeconds));
        if (!TryQueue(request, out var error))
        {
            request.Dispose();
            WriteJson(context, 429, new { error = "queue_full", message = error });
            return;
        }
        _executor.Submit(request);
        if (!request.Wait((request.TimeoutSeconds + 1) * 1000))
        {
            request.TryCancel("Selection request timed out");
            WriteJson(context, 504, request.Snapshot());
            return;
        }
        var snapshot = request.Snapshot();
        WriteJson(context, snapshot.Status == "succeeded" ? 200 : 409, snapshot.Result ?? snapshot);
    }

    private void HandleExecute(HttpListenerContext context)
    {
        var payload = ReadJson<ExecutePayload>(context.Request);
        if (payload == null) throw new JsonCodecException("Request body is required");
        var mode = (payload.Mode ?? "").Trim().ToLowerInvariant();
        if (mode != "read" && mode != "write")
        {
            WriteJson(context, 400, new { error = "invalid_mode", message = "mode must be read or write" });
            return;
        }
        var description = payload.Description;
        var code = payload.Code;
        if (string.IsNullOrWhiteSpace(description) || string.IsNullOrWhiteSpace(code))
        {
            WriteJson(context, 400, new { error = "invalid_request", message = "description and code are required" });
            return;
        }
        var timeout = payload.TimeoutSeconds ?? _options.DefaultTimeoutSeconds;
        if (timeout < 1 || timeout > _options.MaxTimeoutSeconds)
        {
            WriteJson(context, 400, new { error = "invalid_timeout" });
            return;
        }
        var request = new ConnectorRequest(
            ConnectorRequestKind.Execute,
            mode,
            description!.Trim(),
            code!,
            timeout);
        if (!TryQueue(request, out var error))
        {
            request.Dispose();
            WriteJson(context, 429, new { error = "queue_full", message = error });
            return;
        }
        _executor.Submit(request);
        WriteJson(context, 202, new { requestId = request.RequestId, status = "queued" });
    }

    private void HandleRequestRoute(HttpListenerContext context, string method, string path)
    {
        var relative = path.Substring("/v1/requests/".Length);
        var cancel = relative.EndsWith("/cancel", StringComparison.Ordinal);
        var requestId = cancel ? relative.Substring(0, relative.Length - "/cancel".Length) : relative;
        if (requestId.Length == 0 || !_requests.TryGetValue(requestId, out var request))
        {
            WriteJson(context, 404, new { error = "request_not_found" });
            return;
        }
        if (method == "GET" && !cancel)
        {
            WriteJson(context, 200, request.Snapshot());
            return;
        }
        if (method == "POST" && cancel)
        {
            var cancelled = request.TryCancel("Cancelled by MCP client before execution");
            WriteJson(context, cancelled ? 200 : 409, request.Snapshot());
            return;
        }
        WriteJson(context, 405, new { error = "method_not_allowed" });
    }

    private bool TryQueue(ConnectorRequest request, out string? error)
    {
        error = null;
        var active = 0;
        foreach (var pair in _requests)
            if (!pair.Value.IsTerminal) active++;
        if (active >= _options.MaxQueuedRequests)
        {
            error = "The connector request queue is full";
            return false;
        }
        if (!_requests.TryAdd(request.RequestId, request))
        {
            error = "Unable to allocate a request ID";
            return false;
        }
        return true;
    }

    private bool IsAuthorized(HttpListenerRequest request)
    {
        var header = request.Headers["Authorization"];
        const string prefix = "Bearer ";
        if (header == null || !header.StartsWith(prefix, StringComparison.Ordinal)) return false;
        return FixedTimeEquals(header.Substring(prefix.Length), _token);
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        var diff = leftBytes.Length ^ rightBytes.Length;
        var count = Math.Max(leftBytes.Length, rightBytes.Length);
        for (var i = 0; i < count; i++)
        {
            var a = i < leftBytes.Length ? leftBytes[i] : (byte)0;
            var b = i < rightBytes.Length ? rightBytes[i] : (byte)0;
            diff |= a ^ b;
        }
        return diff == 0;
    }

    private T? ReadJson<T>(HttpListenerRequest request)
    {
        if (request.ContentLength64 > _options.MaxBodyBytes) throw new RequestBodyTooLargeException();
        using (var memory = new MemoryStream())
        {
            var buffer = new byte[8192];
            var total = 0;
            int read;
            while ((read = request.InputStream.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += read;
                if (total > _options.MaxBodyBytes) throw new RequestBodyTooLargeException();
                memory.Write(buffer, 0, read);
            }
            if (memory.Length == 0) return default;
            return JsonCodec.Deserialize<T>(memory.ToArray());
        }
    }

    private static void WriteJson(HttpListenerContext context, int statusCode, object value)
    {
        if (context.Response.OutputStream == null) return;
        var bytes = JsonCodec.SerializeToUtf8Bytes(value);
        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.ContentLength64 = bytes.Length;
        context.Response.OutputStream.Write(bytes, 0, bytes.Length);
    }

    private static string CreateToken()
    {
        var bytes = new byte[32];
        using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
        return Convert.ToBase64String(bytes);
    }

    private static void ValidateInfo(ConnectorInfo info)
    {
        if (string.IsNullOrWhiteSpace(info.InstanceId)) throw new InvalidOperationException("InstanceId is required");
        if (info.Application != "revit" && info.Application != "autocad") throw new InvalidOperationException("Application must be revit or autocad");
        if (info.ApplicationVersion.Length != 4) throw new InvalidOperationException("ApplicationVersion must be a four-digit year");
        if (info.ProcessId < 1) throw new InvalidOperationException("ProcessId is required");
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _stop.Cancel();
        try { _listener?.Stop(); } catch { }
        try { _listener?.Close(); } catch { }
        if (_listenerThread != null && _listenerThread.IsAlive) _listenerThread.Join(2000);
        _registry?.Dispose();
        foreach (var pair in _requests)
        {
            if (!pair.Value.IsTerminal) pair.Value.TryCancel("Connector stopped");
            pair.Value.Dispose();
        }
        _requests.Clear();
        _stop.Dispose();
    }

    private sealed class ExecutePayload
    {
        public string? Mode { get; set; }
        public string? Description { get; set; }
        public string? Code { get; set; }
        public int? TimeoutSeconds { get; set; }
    }

    private sealed class RequestBodyTooLargeException : Exception { }
}
