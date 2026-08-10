using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Aec.Codex.Bridge;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace Aec.Codex.Revit;

internal sealed class RevitConnectorExecutor : IConnectorExecutor, IExternalEventHandler
{
    private readonly object _infoLock = new object();
    private readonly ConcurrentQueue<ConnectorRequest> _queue = new ConcurrentQueue<ConnectorRequest>();
    private readonly string _instanceId;
    private ConnectorInfo _cachedInfo;
    private ExternalEvent? _externalEvent;
    private ConnectorServer? _server;

    public RevitConnectorExecutor(string versionNumber)
    {
        var processId = Process.GetCurrentProcess().Id;
        _instanceId = "revit-" + versionNumber + "-" + processId;
        _cachedInfo = CreateInfo(versionNumber, processId, null);
    }

    public void Attach(ExternalEvent externalEvent) =>
        _externalEvent = externalEvent ?? throw new ArgumentNullException(nameof(externalEvent));

    public void Attach(ConnectorServer server) =>
        _server = server ?? throw new ArgumentNullException(nameof(server));

    public ConnectorInfo GetCachedInfo()
    {
        lock (_infoLock)
        {
            return CloneInfo(_cachedInfo);
        }
    }

    public void Submit(ConnectorRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        if (_externalEvent == null)
        {
            request.Complete(Failed("Revit ExternalEvent is unavailable", "external_event"));
            return;
        }
        request.SetStatus(ConnectorRequestStatus.WaitingForApplication);
        _queue.Enqueue(request);
        var result = _externalEvent.Raise();
        if (result != ExternalEventRequest.Accepted && result != ExternalEventRequest.Pending)
            request.Complete(Failed("Revit rejected the ExternalEvent request", "external_event"));
    }

    public void Execute(UIApplication application)
    {
        RefreshCachedInfo(application);
        while (_queue.TryDequeue(out var request))
        {
            if (request.IsTerminal) continue;
            if (DateTime.UtcNow > request.DeadlineUtc)
            {
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Expired,
                    Message = "Request expired before Revit execution",
                    ErrorType = "timeout"
                });
                continue;
            }
            request.SetStatus(ConnectorRequestStatus.Running);
            try
            {
                if (request.Kind == ConnectorRequestKind.Selection)
                    ExecuteSelection(application, request);
                else
                    request.Complete(new ConnectorCompletion
                    {
                        Status = ConnectorRequestStatus.Rejected,
                        Message = "Dynamic Revit code execution is not enabled in this development build",
                        ErrorType = "capability_unavailable"
                    });
            }
            catch (Exception ex)
            {
                request.Complete(Failed(ex.Message, ex.GetType().Name));
            }
        }
        RefreshCachedInfo(application);
        _server?.RefreshDescriptor();
    }

    public string GetName() => "AEC Codex Revit Connector";

    public void RefreshCachedInfo(UIApplication application)
    {
        var uiDocument = application.ActiveUIDocument;
        DocumentDescriptor? document = null;
        if (uiDocument?.Document != null)
        {
            var doc = uiDocument.Document;
            document = new DocumentDescriptor
            {
                Id = BuildDocumentId(doc),
                Title = doc.Title ?? "",
                Path = string.IsNullOrEmpty(doc.PathName) ? null : doc.PathName
            };
        }
        lock (_infoLock)
        {
            _cachedInfo = CreateInfo(application.Application.VersionNumber, Process.GetCurrentProcess().Id, document);
        }
    }

    private static void ExecuteSelection(UIApplication application, ConnectorRequest request)
    {
        var uiDocument = application.ActiveUIDocument;
        if (uiDocument == null)
        {
            request.Complete(Failed("No active Revit document", "no_active_document"));
            return;
        }
        var document = uiDocument.Document;
        var elements = uiDocument.Selection.GetElementIds().Select(id =>
        {
            var element = document.GetElement(id);
            return new
            {
                id = id.Value,
                uniqueId = element?.UniqueId,
                name = element?.Name,
                category = element?.Category?.Name,
                type = element?.GetType().FullName
            };
        }).ToList();
        request.Complete(new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Succeeded,
            Result = new { count = elements.Count, elements }
        });
    }

    private ConnectorInfo CreateInfo(string version, int processId, DocumentDescriptor? document) =>
        new ConnectorInfo
        {
            InstanceId = _instanceId,
            Application = "revit",
            ApplicationVersion = version,
            ProcessId = processId,
            ConnectorVersion = "0.1.0",
            Document = document,
            Capabilities = new List<string> { "document.info", "selection.read" }
        };

    private static ConnectorInfo CloneInfo(ConnectorInfo source) => new ConnectorInfo
    {
        ProtocolVersion = source.ProtocolVersion,
        InstanceId = source.InstanceId,
        Application = source.Application,
        ApplicationVersion = source.ApplicationVersion,
        ProcessId = source.ProcessId,
        ConnectorVersion = source.ConnectorVersion,
        Document = source.Document == null ? null : new DocumentDescriptor
        {
            Id = source.Document.Id,
            Title = source.Document.Title,
            Path = source.Document.Path
        },
        Capabilities = new List<string>(source.Capabilities)
    };

    private static string BuildDocumentId(Document document) =>
        string.IsNullOrEmpty(document.PathName)
            ? "unsaved:" + document.GetHashCode()
            : "path:" + document.PathName.ToLowerInvariant();

    private static ConnectorCompletion Failed(string message, string errorType) =>
        new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Failed,
            Message = message,
            ErrorType = errorType
        };
}
