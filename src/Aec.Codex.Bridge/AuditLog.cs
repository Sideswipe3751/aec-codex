using System;
using System.IO;
using System.Text.Json;

namespace Aec.Codex.Bridge;

public static class AuditLog
{
    private static readonly object Sync = new object();

    public static void TryWrite(ConnectorInfo connector, ConnectorRequestSnapshot request)
    {
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "AEC Codex",
                "audit");
            Directory.CreateDirectory(root);
            var path = Path.Combine(root, DateTime.UtcNow.ToString("yyyy-MM-dd") + ".jsonl");
            var record = new
            {
                timestampUtc = DateTime.UtcNow.ToString("o"),
                connector = new
                {
                    connector.InstanceId,
                    connector.Application,
                    connector.ApplicationVersion,
                    connector.ProcessId,
                    connector.Document
                },
                request
            };
            var line = JsonSerializer.Serialize(record, JsonOptions.Default);
            lock (Sync)
            {
                File.AppendAllText(path, line + Environment.NewLine);
            }
        }
        catch
        {
            // Audit I/O must never corrupt or change an Autodesk transaction result.
        }
    }
}
