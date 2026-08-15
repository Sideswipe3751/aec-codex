using System;
using BimBridge.Host;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace BimBridge.Revit;

public sealed class BimBridgeApplication : IExternalApplication
{
    private static ConnectorServer? _server;
    private static RevitConnectorExecutor? _executor;
    private static ExternalEvent? _externalEvent;

    public Result OnStartup(UIControlledApplication application)
    {
        try
        {
            var actualVersion = application.ControlledApplication.VersionNumber;
            RevitAdapterIdentity.EnsureCompatible(actualVersion);
            _executor = new RevitConnectorExecutor(actualVersion);
            _externalEvent = ExternalEvent.Create(_executor);
            _executor.Attach(_externalEvent);
            _server = new ConnectorServer(_executor);
            _executor.Attach(_server);
            _server.Start();
            application.Idling += OnIdling;
            return Result.Succeeded;
        }
        catch (Exception exception)
        {
            ConnectorDiagnostics.TryWriteStartupFailure("Revit", exception);
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
