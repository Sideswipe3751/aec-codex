using System;
using System.Linq;
using System.Reflection;

namespace BimBridge.Revit;

internal static class RevitAdapterIdentity
{
    public static string ExpectedVersion { get; } = ReadMetadata("RevitVersion");
    public static string RuntimeFamily { get; } = ReadMetadata("RevitRuntimeFamily");

    public static void EnsureCompatible(string actualVersion)
    {
        if (!string.Equals(ExpectedVersion, actualVersion, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "BIM Bridge Revit " + ExpectedVersion +
                " adapter cannot load in Revit " + actualVersion + ".");
        }
    }

    private static string ReadMetadata(string key)
    {
        var attribute = typeof(RevitAdapterIdentity).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(candidate => string.Equals(candidate.Key, key, StringComparison.Ordinal));
        if (string.IsNullOrWhiteSpace(attribute?.Value))
            throw new InvalidOperationException("BIM Bridge adapter metadata is missing: " + key);
        return attribute!.Value!;
    }
}
