using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Aec.Codex.Bridge;
using Autodesk.AutoCAD.ApplicationServices.Core;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;

namespace Aec.Codex.AutoCAD;

internal sealed class AutoCADConnectorExecutor : IConnectorExecutor
{
    private readonly object _infoLock = new object();
    private readonly ConcurrentQueue<ConnectorRequest> _queue = new ConcurrentQueue<ConnectorRequest>();
    private readonly string _instanceId;
    private ConnectorInfo _cachedInfo;
    private ConnectorServer? _server;

    public AutoCADConnectorExecutor()
    {
        var processId = Process.GetCurrentProcess().Id;
        var version = Application.Version.Major >= 25 ? "2025" : "2024";
        _instanceId = "autocad-" + version + "-" + processId;
        _cachedInfo = CreateInfo(version, processId, null);
    }

    public void Attach(ConnectorServer server) =>
        _server = server ?? throw new ArgumentNullException(nameof(server));

    public ConnectorInfo GetCachedInfo()
    {
        lock (_infoLock) return CloneInfo(_cachedInfo);
    }

    public void Submit(ConnectorRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        request.SetStatus(ConnectorRequestStatus.WaitingForApplication);
        _queue.Enqueue(request);
    }

    public void ProcessPending()
    {
        RefreshCachedInfo();
        while (_queue.TryDequeue(out var request))
        {
            if (request.IsTerminal) continue;
            if (DateTime.UtcNow > request.DeadlineUtc)
            {
                request.Complete(new ConnectorCompletion
                {
                    Status = ConnectorRequestStatus.Expired,
                    Message = "Request expired before AutoCAD execution",
                    ErrorType = "timeout"
                });
                continue;
            }
            request.SetStatus(ConnectorRequestStatus.Running);
            try
            {
                if (request.Kind == ConnectorRequestKind.Selection)
                    ExecuteSelection(request);
                else
                    request.Complete(new ConnectorCompletion
                    {
                        Status = ConnectorRequestStatus.Rejected,
                        Message = "Dynamic AutoCAD code execution is not enabled in this development build",
                        ErrorType = "capability_unavailable"
                    });
            }
            catch (Exception ex)
            {
                request.Complete(Failed(ex.Message, ex.GetType().Name));
            }
        }
        RefreshCachedInfo();
        _server?.RefreshDescriptor();
    }

    private static void ExecuteSelection(ConnectorRequest request)
    {
        var document = Application.DocumentManager.MdiActiveDocument;
        if (document == null)
        {
            request.Complete(Failed("No active AutoCAD document", "no_active_document"));
            return;
        }
        var selected = document.Editor.SelectImplied();
        if (selected.Status != PromptStatus.OK || selected.Value == null)
        {
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = new { count = 0, entities = Array.Empty<object>() }
            });
            return;
        }
        using (var transaction = document.Database.TransactionManager.StartOpenCloseTransaction())
        {
            var entities = selected.Value.GetObjectIds().Select(id =>
            {
                var dbObject = transaction.GetObject(id, OpenMode.ForRead, false);
                var entity = dbObject as Entity;
                return new
                {
                    objectId = id.ToString(),
                    handle = id.Handle.ToString(),
                    type = dbObject.GetRXClass().Name,
                    layer = entity?.Layer
                };
            }).ToList();
            transaction.Commit();
            request.Complete(new ConnectorCompletion
            {
                Status = ConnectorRequestStatus.Succeeded,
                Result = new { count = entities.Count, entities }
            });
        }
    }

    private void RefreshCachedInfo()
    {
        var document = Application.DocumentManager.MdiActiveDocument;
        DocumentDescriptor? descriptor = null;
        if (document != null)
        {
            var filename = document.Database.Filename;
            descriptor = new DocumentDescriptor
            {
                Id = string.IsNullOrEmpty(filename)
                    ? "unsaved:" + document.Name
                    : "path:" + filename.ToLowerInvariant(),
                Title = document.Name ?? "",
                Path = string.IsNullOrEmpty(filename) ? null : filename
            };
        }
        lock (_infoLock)
        {
            _cachedInfo = CreateInfo(_cachedInfo.ApplicationVersion, Process.GetCurrentProcess().Id, descriptor);
        }
    }

    private ConnectorInfo CreateInfo(string version, int processId, DocumentDescriptor? document) =>
        new ConnectorInfo
        {
            InstanceId = _instanceId,
            Application = "autocad",
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

    private static ConnectorCompletion Failed(string message, string errorType) =>
        new ConnectorCompletion
        {
            Status = ConnectorRequestStatus.Failed,
            Message = message,
            ErrorType = errorType
        };
}
