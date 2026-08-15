using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace BimBridge.Revit.LiveTest;

[DataContract]
internal sealed class LiveTestRequest
{
    [DataMember(Name = "schemaVersion", IsRequired = true)] public int SchemaVersion { get; set; }
    [DataMember(Name = "runId", IsRequired = true)] public string RunId { get; set; } = "";
    [DataMember(Name = "token", IsRequired = true)] public string Token { get; set; } = "";
    [DataMember(Name = "version", IsRequired = true)] public string Version { get; set; } = "";
    [DataMember(Name = "certificationRoot", IsRequired = true)] public string CertificationRoot { get; set; } = "";
    [DataMember(Name = "runDirectory", IsRequired = true)] public string RunDirectory { get; set; } = "";
    [DataMember(Name = "templatePath", IsRequired = true)] public string TemplatePath { get; set; } = "";
    [DataMember(Name = "documentPath", IsRequired = true)] public string DocumentPath { get; set; } = "";
}

[DataContract]
internal sealed class FinishRequest
{
    [DataMember(Name = "token", IsRequired = true)] public string Token { get; set; } = "";
}

[DataContract]
internal sealed class BootstrapEvent
{
    [DataMember(Name = "schemaVersion")] public int SchemaVersion { get; set; } = 1;
    [DataMember(Name = "runId")] public string RunId { get; set; } = "";
    [DataMember(Name = "token")] public string Token { get; set; } = "";
    [DataMember(Name = "stage")] public string Stage { get; set; } = "";
    [DataMember(Name = "timestampUtc")] public string TimestampUtc { get; set; } = "";
    [DataMember(Name = "version")] public string? Version { get; set; }
    [DataMember(Name = "versionBuild")] public string? VersionBuild { get; set; }
    [DataMember(Name = "processId")] public int ProcessId { get; set; }
    [DataMember(Name = "documentTitle")] public string? DocumentTitle { get; set; }
    [DataMember(Name = "documentPath")] public string? DocumentPath { get; set; }
    [DataMember(Name = "errorType")] public string? ErrorType { get; set; }
    [DataMember(Name = "message")] public string? Message { get; set; }
}

internal static class LiveTestJson
{
    public static T Read<T>(string path)
    {
        using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            var serializer = new DataContractJsonSerializer(typeof(T));
            var value = serializer.ReadObject(stream);
            if (value is T typed) return typed;
            throw new SerializationException("JSON payload has the wrong type.");
        }
    }

    public static void WriteAtomic<T>(string path, T value)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("Output path has no parent directory.");
        Directory.CreateDirectory(directory);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = File.Create(temp))
            {
                var serializer = new DataContractJsonSerializer(typeof(T));
                serializer.WriteObject(stream, value);
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(temp, path);
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
        }
    }
}
