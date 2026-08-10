using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;

namespace Aec.Codex.Bridge;

public enum ConnectorRequestKind
{
    Selection = 0,
    Execute = 1
}

public enum ConnectorRequestStatus
{
    Queued = 0,
    WaitingForApplication = 1,
    Running = 2,
    Succeeded = 3,
    Failed = 4,
    Rejected = 5,
    Expired = 6,
    Cancelled = 7
}

public sealed class DocumentDescriptor
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Path { get; set; }
}

public sealed class ConnectorInfo
{
    public int ProtocolVersion { get; set; } = 1;
    public string InstanceId { get; set; } = "";
    public string Application { get; set; } = "";
    public string ApplicationVersion { get; set; } = "";
    public int ProcessId { get; set; }
    public string ConnectorVersion { get; set; } = "0.1.0";
    public DocumentDescriptor? Document { get; set; }
    public List<string> Capabilities { get; set; } = new List<string>();
}

public sealed class ConnectorInstanceDescriptor
{
    public int ProtocolVersion { get; set; } = 1;
    public string InstanceId { get; set; } = "";
    public string Application { get; set; } = "";
    public string ApplicationVersion { get; set; } = "";
    public int ProcessId { get; set; }
    public string Url { get; set; } = "";
    public string Token { get; set; } = "";
    public string StartedAtUtc { get; set; } = "";
    public DocumentDescriptor? Document { get; set; }
    public List<string> Capabilities { get; set; } = new List<string>();
}

public sealed class ConnectorCompletion
{
    public ConnectorRequestStatus Status { get; set; }
    public object? Result { get; set; }
    public string? Message { get; set; }
    public string? ErrorType { get; set; }
    public bool RolledBack { get; set; }
    public List<string> Warnings { get; set; } = new List<string>();
}

public sealed class ConnectorRequestSnapshot
{
    public string RequestId { get; set; } = "";
    public string Status { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Mode { get; set; } = "";
    public string Description { get; set; } = "";
    public object? Result { get; set; }
    public string? Message { get; set; }
    public string? ErrorType { get; set; }
    public bool RolledBack { get; set; }
    public List<string> Warnings { get; set; } = new List<string>();
    public long ElapsedMilliseconds { get; set; }
    public string CreatedAtUtc { get; set; } = "";
    public string DeadlineUtc { get; set; } = "";
}

public sealed class ConnectorRequest : IDisposable
{
    private readonly object _sync = new object();
    private readonly ManualResetEvent _completed = new ManualResetEvent(false);
    private ConnectorRequestStatus _status = ConnectorRequestStatus.Queued;
    private DateTime? _startedAtUtc;
    private DateTime? _completedAtUtc;
    private ConnectorCompletion? _completion;

    public ConnectorRequest(
        ConnectorRequestKind kind,
        string mode,
        string description,
        string code,
        int timeoutSeconds)
    {
        RequestId = Guid.NewGuid().ToString("N");
        Kind = kind;
        Mode = mode;
        Description = description ?? "";
        Code = code ?? "";
        TimeoutSeconds = timeoutSeconds;
        CreatedAtUtc = DateTime.UtcNow;
        DeadlineUtc = CreatedAtUtc.AddSeconds(timeoutSeconds);
    }

    public string RequestId { get; }
    public ConnectorRequestKind Kind { get; }
    public string Mode { get; }
    public string Description { get; }
    public string Code { get; }
    public int TimeoutSeconds { get; }
    public DateTime CreatedAtUtc { get; }
    public DateTime DeadlineUtc { get; }

    public bool IsTerminal
    {
        get { lock (_sync) return IsTerminalStatus(_status); }
    }

    public void SetStatus(ConnectorRequestStatus status, string? message = null)
    {
        lock (_sync)
        {
            if (IsTerminalStatus(_status)) return;
            _status = status;
            if (status == ConnectorRequestStatus.Running && !_startedAtUtc.HasValue)
                _startedAtUtc = DateTime.UtcNow;
            if (message != null)
            {
                _completion ??= new ConnectorCompletion();
                _completion.Message = message;
            }
        }
    }

    public void Complete(ConnectorCompletion completion)
    {
        if (completion == null) throw new ArgumentNullException(nameof(completion));
        lock (_sync)
        {
            if (IsTerminalStatus(_status)) return;
            _completion = completion;
            _status = completion.Status;
            _completedAtUtc = DateTime.UtcNow;
            _completed.Set();
        }
    }

    public bool TryCancel(string message)
    {
        lock (_sync)
        {
            if (IsTerminalStatus(_status) || _status == ConnectorRequestStatus.Running)
                return false;
            _completion = new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Cancelled,
                Message = message
            };
            _status = ConnectorRequestStatus.Cancelled;
            _completedAtUtc = DateTime.UtcNow;
            _completed.Set();
            return true;
        }
    }

    public bool Wait(int millisecondsTimeout) => _completed.WaitOne(millisecondsTimeout);

    public ConnectorRequestSnapshot Snapshot()
    {
        lock (_sync)
        {
            var completed = _completedAtUtc ?? DateTime.UtcNow;
            var started = _startedAtUtc ?? CreatedAtUtc;
            return new ConnectorRequestSnapshot
            {
                RequestId = RequestId,
                Status = StatusName(_status),
                Kind = Kind == ConnectorRequestKind.Selection ? "selection" : "execute",
                Mode = Mode,
                Description = Description,
                Result = NormalizeJson(_completion?.Result),
                Message = _completion?.Message,
                ErrorType = _completion?.ErrorType,
                RolledBack = _completion?.RolledBack ?? false,
                Warnings = new List<string>(_completion?.Warnings ?? new List<string>()),
                ElapsedMilliseconds = (long)(completed - started).TotalMilliseconds,
                CreatedAtUtc = CreatedAtUtc.ToString("o"),
                DeadlineUtc = DeadlineUtc.ToString("o")
            };
        }
    }

    public static string StatusName(ConnectorRequestStatus status)
    {
        switch (status)
        {
            case ConnectorRequestStatus.Queued: return "queued";
            case ConnectorRequestStatus.WaitingForApplication: return "waiting_for_application";
            case ConnectorRequestStatus.Running: return "running";
            case ConnectorRequestStatus.Succeeded: return "succeeded";
            case ConnectorRequestStatus.Failed: return "failed";
            case ConnectorRequestStatus.Rejected: return "rejected";
            case ConnectorRequestStatus.Expired: return "expired";
            case ConnectorRequestStatus.Cancelled: return "cancelled";
            default: return "unknown";
        }
    }

    private static bool IsTerminalStatus(ConnectorRequestStatus status) =>
        status == ConnectorRequestStatus.Succeeded ||
        status == ConnectorRequestStatus.Failed ||
        status == ConnectorRequestStatus.Rejected ||
        status == ConnectorRequestStatus.Expired ||
        status == ConnectorRequestStatus.Cancelled;

    private static object? NormalizeJson(object? value)
    {
        if (!(value is JsonElement element)) return value;
        return JsonSerializer.Deserialize<object>(element.GetRawText());
    }

    public void Dispose() => _completed.Dispose();
}

public interface IConnectorExecutor
{
    ConnectorInfo GetCachedInfo();
    void Submit(ConnectorRequest request);
}
