using System;
using System.IO;
using System.Threading;

namespace Aec.Codex.Bridge;

internal sealed class InstanceRegistry : IDisposable
{
    private readonly object _gate = new object();
    private readonly string _path;
    private string? _lastJson;

    public InstanceRegistry(string directory, string instanceId)
    {
        if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("Instance directory is required", nameof(directory));
        if (string.IsNullOrWhiteSpace(instanceId)) throw new ArgumentException("Instance ID is required", nameof(instanceId));
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, instanceId + ".json");
    }

    public void Write(ConnectorInstanceDescriptor descriptor)
    {
        var json = JsonCodec.Serialize(descriptor);
        lock (_gate)
        {
            if (string.Equals(_lastJson, json, StringComparison.Ordinal) && File.Exists(_path)) return;

            for (var attempt = 0; ; attempt++)
            {
                var temp = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllText(temp, json);
                try
                {
                    if (File.Exists(_path)) File.Replace(temp, _path, null);
                    else File.Move(temp, _path);
                    _lastJson = json;
                    return;
                }
                catch (IOException) when (attempt < 4)
                {
                    // Windows readers may briefly deny the delete-sharing mode
                    // required by File.Replace. Retry a bounded number of times;
                    // RefreshDescriptor will retry on the next application idle
                    // if the target stays locked longer than this window.
                    Thread.Sleep(25 * (attempt + 1));
                }
                finally
                {
                    try { if (File.Exists(temp)) File.Delete(temp); }
                    catch { }
                }
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            try { if (File.Exists(_path)) File.Delete(_path); }
            catch { }
        }
    }
}
