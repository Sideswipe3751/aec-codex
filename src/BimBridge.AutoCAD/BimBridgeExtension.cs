using System;
using BimBridge.Host;
using Autodesk.AutoCAD.ApplicationServices.Core;
using Autodesk.AutoCAD.Runtime;

namespace BimBridge.AutoCAD;

public sealed class BimBridgeExtension : IExtensionApplication
{
    private static AutoCADConnectorExecutor? _executor;
    private static ConnectorServer? _server;

    public void Initialize()
    {
        try
        {
            var actualVersion = AutoCADApiCompatibility.GetRelease(Application.Version);
            AutoCADAdapterIdentity.EnsureCompatible(actualVersion);
            _executor = new AutoCADConnectorExecutor(actualVersion);
            _server = new ConnectorServer(_executor);
            _executor.Attach(_server);
            _server.Start();
            Application.Idle += OnIdle;
        }
        catch (System.Exception exception)
        {
            ConnectorDiagnostics.TryWriteStartupFailure("AutoCAD", exception);
            _server?.Dispose();
            _server = null;
            _executor = null;
            throw;
        }
    }

    public void Terminate()
    {
        Application.Idle -= OnIdle;
        _server?.Dispose();
        _server = null;
        _executor = null;
    }

    private static void OnIdle(object? sender, EventArgs args)
    {
        _executor?.ProcessPending();
    }
}
