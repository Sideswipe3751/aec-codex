using System;
using System.Diagnostics;
using System.IO;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace BimBridge.Revit.LiveTest;

public sealed class LiveTestBootstrapApplication : IExternalApplication
{
    private const string RequestEnvironmentVariable = "BIM_BRIDGE_REVIT_LIVE_TEST_REQUEST";
    private static UIControlledApplication? _controlledApplication;
    private static LiveTestRequest? _request;
    private static bool _ready;
    private static bool _exitRequested;

    public Result OnStartup(UIControlledApplication application)
    {
        var requestPath = Environment.GetEnvironmentVariable(RequestEnvironmentVariable);
        if (string.IsNullOrWhiteSpace(requestPath)) return Result.Succeeded;

        try
        {
            _request = LiveTestJson.Read<LiveTestRequest>(requestPath);
            ValidateRequest(_request, application.ControlledApplication.VersionNumber, requestPath);
            _controlledApplication = application;
            application.Idling += OnIdling;
            return Result.Succeeded;
        }
        catch (Exception exception)
        {
            TryWriteFailure(requestPath, "startup", exception);
            return Result.Failed;
        }
    }

    public Result OnShutdown(UIControlledApplication application)
    {
        application.Idling -= OnIdling;
        if (_request != null)
        {
            TryWriteEvent("stopped.json", new BootstrapEvent
            {
                RunId = _request.RunId,
                Token = _request.Token,
                Stage = "stopped",
                TimestampUtc = DateTime.UtcNow.ToString("o"),
                Version = _request.Version,
                ProcessId = Process.GetCurrentProcess().Id
            });
        }
        _controlledApplication = null;
        _request = null;
        _ready = false;
        _exitRequested = false;
        return Result.Succeeded;
    }

    private static void OnIdling(object? sender, IdlingEventArgs args)
    {
        if (_request == null || _exitRequested || !(sender is UIApplication uiApplication)) return;
        try
        {
            if (!_ready)
            {
                InitializeDisposableDocument(uiApplication);
                _ready = true;
            }
            if (File.Exists(Path.Combine(_request.RunDirectory, "finish.json")))
                Finish(uiApplication);
        }
        catch (Exception exception)
        {
            TryWriteEvent("failed.json", CreateEvent("failed", uiApplication, exception));
            RequestExit(uiApplication);
        }
    }

    private static void InitializeDisposableDocument(UIApplication uiApplication)
    {
        if (_request == null) throw new InvalidOperationException("Live test request is unavailable.");
        if (uiApplication.ActiveUIDocument != null)
            throw new InvalidOperationException("Safety gate refused to replace an already active Revit document.");

        var document = uiApplication.Application.NewProjectDocument(_request.TemplatePath);
        try
        {
            var saveOptions = new SaveAsOptions { OverwriteExistingFile = false, MaximumBackups = 1 };
            document.SaveAs(_request.DocumentPath, saveOptions);
        }
        finally
        {
            if (document.IsValidObject) document.Close(false);
        }

        var uiDocument = uiApplication.OpenAndActivateDocument(_request.DocumentPath);
        if (!PathsEqual(uiDocument.Document.PathName, _request.DocumentPath))
            throw new InvalidOperationException("Revit activated an unexpected document.");

        TryWriteEvent("ready.json", new BootstrapEvent
        {
            RunId = _request.RunId,
            Token = _request.Token,
            Stage = "ready",
            TimestampUtc = DateTime.UtcNow.ToString("o"),
            Version = uiApplication.Application.VersionNumber,
            VersionBuild = uiApplication.Application.VersionBuild,
            ProcessId = Process.GetCurrentProcess().Id,
            DocumentTitle = uiDocument.Document.Title,
            DocumentPath = uiDocument.Document.PathName
        });
    }

    private static void Finish(UIApplication uiApplication)
    {
        if (_request == null) return;
        var finish = LiveTestJson.Read<FinishRequest>(Path.Combine(_request.RunDirectory, "finish.json"));
        if (!string.Equals(finish.Token, _request.Token, StringComparison.Ordinal))
            throw new InvalidOperationException("Finish marker token does not match this live test run.");

        var document = uiApplication.ActiveUIDocument?.Document;
        if (document != null)
        {
            if (!PathsEqual(document.PathName, _request.DocumentPath))
                throw new InvalidOperationException("Safety gate refused to save an unexpected active document.");
            if (document.IsModified) document.Save();
        }
        TryWriteEvent("stopping.json", CreateEvent("stopping", uiApplication, null));
        RequestExit(uiApplication);
    }

    private static void RequestExit(UIApplication uiApplication)
    {
        if (_exitRequested) return;
        var command = RevitCommandId.LookupPostableCommandId(PostableCommand.ExitRevit);
        if (!uiApplication.CanPostCommand(command))
            throw new InvalidOperationException("Revit cannot post its clean exit command.");
        uiApplication.PostCommand(command);
        _exitRequested = true;
    }

    private static BootstrapEvent CreateEvent(string stage, UIApplication uiApplication, Exception? exception)
    {
        var document = uiApplication.ActiveUIDocument?.Document;
        return new BootstrapEvent
        {
            RunId = _request?.RunId ?? "",
            Token = _request?.Token ?? "",
            Stage = stage,
            TimestampUtc = DateTime.UtcNow.ToString("o"),
            Version = uiApplication.Application.VersionNumber,
            VersionBuild = uiApplication.Application.VersionBuild,
            ProcessId = Process.GetCurrentProcess().Id,
            DocumentTitle = document?.Title,
            DocumentPath = document?.PathName,
            ErrorType = exception?.GetType().FullName,
            Message = exception?.Message
        };
    }

    private static void ValidateRequest(LiveTestRequest request, string actualVersion, string requestPath)
    {
        if (request.SchemaVersion != 1) throw new InvalidOperationException("Unsupported live test request schema.");
        if (string.IsNullOrWhiteSpace(request.RunId) || string.IsNullOrWhiteSpace(request.Token))
            throw new InvalidOperationException("Run ID and token are required.");
        if (!string.Equals(request.Version, actualVersion, StringComparison.Ordinal))
            throw new InvalidOperationException("Test request version does not match the running Revit version.");
        if (!File.Exists(request.TemplatePath)) throw new FileNotFoundException("Revit template was not found.", request.TemplatePath);

        var requestDirectory = Path.GetDirectoryName(Path.GetFullPath(requestPath)) ?? "";
        var certificationRoot = Path.GetFullPath(request.CertificationRoot).TrimEnd(Path.DirectorySeparatorChar);
        var expectedVersionRoot = Path.Combine(certificationRoot, request.Version).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var runDirectory = Path.GetFullPath(request.RunDirectory).TrimEnd(Path.DirectorySeparatorChar);
        var documentPath = Path.GetFullPath(request.DocumentPath);
        if (!runDirectory.StartsWith(expectedVersionRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Run directory must be inside the version-specific certification root.");
        if (!PathsEqual(requestDirectory, runDirectory))
            throw new InvalidOperationException("Request file must be inside its declared run directory.");
        if (!documentPath.StartsWith(runDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Disposable document must be inside the live test run directory.");
        if (!string.Equals(Path.GetExtension(documentPath), ".rvt", StringComparison.OrdinalIgnoreCase) ||
            Path.GetFileName(documentPath).IndexOf(request.RunId, StringComparison.OrdinalIgnoreCase) < 0)
            throw new InvalidOperationException("Disposable document name must contain the run ID and use the RVT extension.");
        if (File.Exists(documentPath)) throw new InvalidOperationException("Disposable document path already exists.");
    }

    private static bool PathsEqual(string? left, string? right) =>
        !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right) &&
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private static void TryWriteEvent(string fileName, BootstrapEvent value)
    {
        try
        {
            if (_request != null) LiveTestJson.WriteAtomic(Path.Combine(_request.RunDirectory, fileName), value);
        }
        catch { }
    }

    private static void TryWriteFailure(string requestPath, string stage, Exception exception)
    {
        try
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(requestPath));
            if (directory == null) return;
            LiveTestJson.WriteAtomic(Path.Combine(directory, "failed.json"), new BootstrapEvent
            {
                Stage = stage,
                TimestampUtc = DateTime.UtcNow.ToString("o"),
                ProcessId = Process.GetCurrentProcess().Id,
                ErrorType = exception.GetType().FullName,
                Message = exception.Message
            });
        }
        catch { }
    }
}
