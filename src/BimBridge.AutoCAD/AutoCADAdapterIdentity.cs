using System;
using System.Linq;
using System.Reflection;

namespace BimBridge.AutoCAD;

internal static class AutoCADAdapterIdentity
{
    public static string ExpectedVersion { get; } = ReadMetadata("AutoCADVersion");
    public static string RuntimeFamily { get; } = ReadMetadata("AutoCADRuntimeFamily");

    public static void EnsureCompatible(string actualVersion)
    {
        if (!string.Equals(ExpectedVersion, actualVersion, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "BIM Bridge AutoCAD " + ExpectedVersion +
                " adapter cannot load in AutoCAD " + actualVersion + ".");
        }
    }

    private static string ReadMetadata(string key)
    {
        var attribute = typeof(AutoCADAdapterIdentity).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(candidate => string.Equals(candidate.Key, key, StringComparison.Ordinal));
        if (string.IsNullOrWhiteSpace(attribute?.Value))
            throw new InvalidOperationException("BIM Bridge adapter metadata is missing: " + key);
        return attribute!.Value!;
    }
}
