using System;
using System.IO;
using System.Text.Json;

namespace Aec.Codex.Bridge;

internal sealed class InstanceRegistry : IDisposable
{
    private readonly string _path;

    public InstanceRegistry(string directory, string instanceId)
    {
        if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("Instance directory is required", nameof(directory));
        if (string.IsNullOrWhiteSpace(instanceId)) throw new ArgumentException("Instance ID is required", nameof(instanceId));
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, instanceId + ".json");
    }

    public void Write(ConnectorInstanceDescriptor descriptor)
    {
        var temp = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var json = JsonSerializer.Serialize(descriptor, JsonOptions.Default);
        File.WriteAllText(temp, json);
        try
        {
            if (File.Exists(_path)) File.Replace(temp, _path, null);
            else File.Move(temp, _path);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }

    public void Dispose()
    {
        try { if (File.Exists(_path)) File.Delete(_path); }
        catch { }
    }
}

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
}
