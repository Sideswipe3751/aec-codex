using System.Reflection;

namespace BimBridge.AutoCAD;

internal interface IAutoCADCodeCompiler
{
    Assembly Compile(string source);
}
