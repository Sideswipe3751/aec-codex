using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Geometry;
using Autodesk.AutoCAD.Colors;
using Microsoft.CSharp;

namespace BimBridge.AutoCAD;

internal sealed class RuntimeCodeCompiler : IAutoCADCodeCompiler
{
    public Assembly Compile(string source)
    {
        using (var provider = new CSharpCodeProvider(
            new Dictionary<string, string> { ["CompilerVersion"] = "v4.0" }))
        {
            var parameters = new CompilerParameters
            {
                GenerateExecutable = false,
                GenerateInMemory = true,
                IncludeDebugInformation = false,
                TreatWarningsAsErrors = false,
                CompilerOptions = "/optimize /langversion:5"
            };
            AddReference(parameters, typeof(object).Assembly);
            AddReference(parameters, typeof(Enumerable).Assembly);
            AddReference(parameters, typeof(System.Diagnostics.Process).Assembly);
            AddReference(parameters, typeof(Document).Assembly);
            AddReference(parameters, typeof(DocumentExtension).Assembly);
            AddReference(parameters, typeof(Transaction).Assembly);
            AddReference(parameters, typeof(Point3d).Assembly);
            AddReference(parameters, typeof(Color).Assembly);

            var result = provider.CompileAssemblyFromSource(parameters, source);
            if (result.Errors.HasErrors)
            {
                var errors = result.Errors.Cast<CompilerError>()
                    .Where(error => !error.IsWarning)
                    .Select(error => error.ToString());
                throw new InvalidOperationException(
                    "AutoCAD code compilation failed: " + string.Join("; ", errors));
            }
            return result.CompiledAssembly;
        }
    }

    private static void AddReference(CompilerParameters parameters, Assembly assembly)
    {
        if (!string.IsNullOrEmpty(assembly.Location) &&
            !parameters.ReferencedAssemblies.Contains(assembly.Location))
        {
            parameters.ReferencedAssemblies.Add(assembly.Location);
        }
    }
}
