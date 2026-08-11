using System;
using System.IO;

namespace Aec.Codex.Bridge;

public static class ConnectorDiagnostics
{
    private static readonly object Sync = new object();

    public static void TryWriteStartupFailure(string application, Exception exception)
    {
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "AEC Codex");
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, "connector-errors.log");
            var record = $"[{DateTime.UtcNow:o}] {application} startup failed{Environment.NewLine}{exception}{Environment.NewLine}";
            lock (Sync) File.AppendAllText(path, record);
        }
        catch
        {
            // Diagnostic I/O must never change connector startup behavior.
        }
    }
}
