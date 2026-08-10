using System;
using Aec.Codex.Bridge;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace Aec.Codex.Revit;

public sealed class AecCodexApplication : IExternalApplication
{
    private static ConnectorServer? _server;
    private static RevitConnectorExecutor? _executor;
    private static ExternalEvent? _externalEvent;

    public Result OnStartup(UIControlledApplication application)
    {
        try
        {
            _executor = new RevitConnectorExecutor(application.ControlledApplication.VersionNumber);
            _externalEvent = ExternalEvent.Create(_executor);
            _executor.Attach(_externalEvent);
            _server = new ConnectorServer(_executor);
            _executor.Attach(_server);
            _server.Start();
            application.Idling += OnIdling;
            return Result.Succeeded;
        }
        catch
        {
            _server?.Dispose();
            _externalEvent?.Dispose();
            _server = null;
            _externalEvent = null;
            _executor = null;
            return Result.Failed;
        }
    }

    public Result OnShutdown(UIControlledApplication application)
    {
        application.Idling -= OnIdling;
        _server?.Dispose();
        _externalEvent?.Dispose();
        _server = null;
        _externalEvent = null;
        _executor = null;
        return Result.Succeeded;
    }

    private static void OnIdling(object? sender, IdlingEventArgs args)
    {
        if (sender is UIApplication uiApplication && _executor != null)
        {
            _executor.RefreshCachedInfo(uiApplication);
            _server?.RefreshDescriptor();
        }
    }
}
