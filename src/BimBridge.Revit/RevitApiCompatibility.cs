using Autodesk.Revit.DB;

namespace BimBridge.Revit;

// Keep observed Revit API differences in this boundary instead of scattering
// release-year checks throughout the shared execution engine.
internal static class RevitApiCompatibility
{
    public static long GetElementIdValue(ElementId id) => id.Value;
}
