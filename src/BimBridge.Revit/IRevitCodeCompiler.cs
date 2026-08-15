using System.Reflection;

namespace BimBridge.Revit;

internal interface IRevitCodeCompiler
{
    Assembly Compile(string source);
}
