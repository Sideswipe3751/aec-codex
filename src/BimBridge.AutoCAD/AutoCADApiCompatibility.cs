using System;

namespace BimBridge.AutoCAD;

internal static class AutoCADApiCompatibility
{
    public static string GetRelease(Version apiVersion)
    {
        if (apiVersion == null) throw new ArgumentNullException(nameof(apiVersion));
        if (apiVersion.Major == 24 && apiVersion.Minor == 3) return "2024";
        if (apiVersion.Major == 25 && apiVersion.Minor == 0) return "2025";
        if (apiVersion.Major == 25 && apiVersion.Minor == 1) return "2026";
        if (apiVersion.Major == 26 && apiVersion.Minor == 0) return "2027";
        throw new NotSupportedException("Unsupported AutoCAD API release: " + apiVersion);
    }
}
