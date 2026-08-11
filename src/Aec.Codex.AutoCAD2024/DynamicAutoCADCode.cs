using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Microsoft.CSharp;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;

namespace Aec.Codex.AutoCAD;

internal static class DynamicAutoCADCode
{
    public static object? Execute(string code, Document document, Transaction transaction)
    {
        if (string.IsNullOrWhiteSpace(code)) throw new ArgumentException("Code is required", nameof(code));
        var source = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Geometry;
using Autodesk.AutoCAD.Colors;
namespace Aec.Codex.Dynamic {
  public static class UserScript {
    public static object Run(Document document, Database database, Editor editor, Transaction transaction) {
" + code + @"
    }
  }
}";

        using (var provider = new CSharpCodeProvider(new Dictionary<string, string> { ["CompilerVersion"] = "v4.0" }))
        {
            var parameters = new CompilerParameters
            {
                GenerateExecutable = false,
                GenerateInMemory = true,
                IncludeDebugInformation = false,
                TreatWarningsAsErrors = false,
                CompilerOptions = "/optimize /langversion:latest"
            };
            AddReference(parameters, typeof(object).Assembly);
            AddReference(parameters, typeof(Enumerable).Assembly);
            AddReference(parameters, typeof(Document).Assembly);
            AddReference(parameters, typeof(Transaction).Assembly);
            AddReference(parameters, typeof(Autodesk.AutoCAD.Geometry.Point3d).Assembly);
            AddReference(parameters, typeof(Autodesk.AutoCAD.Colors.Color).Assembly);
            AddReference(parameters, typeof(DynamicAutoCADCode).Assembly);
            var compiled = provider.CompileAssemblyFromSource(parameters, source);
            if (compiled.Errors.HasErrors)
            {
                var errors = compiled.Errors.Cast<CompilerError>()
                    .Where(error => !error.IsWarning)
                    .Select(error => $"line {Math.Max(1, error.Line - 14)}: {error.ErrorText}");
                throw new InvalidOperationException("AutoCAD code compilation failed: " + string.Join("; ", errors));
            }
            var method = compiled.CompiledAssembly.GetType("Aec.Codex.Dynamic.UserScript", true)
                .GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            try
            {
                return method!.Invoke(null, new object[] { document, document.Database, document.Editor, transaction });
            }
            catch (TargetInvocationException ex) when (ex.InnerException != null)
            {
                throw ex.InnerException;
            }
        }
    }

    private static void AddReference(CompilerParameters parameters, Assembly assembly)
    {
        if (!string.IsNullOrEmpty(assembly.Location) && !parameters.ReferencedAssemblies.Contains(assembly.Location))
            parameters.ReferencedAssemblies.Add(assembly.Location);
    }
}
