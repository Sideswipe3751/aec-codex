using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Microsoft.CSharp;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace Aec.Codex.Revit;

internal static class DynamicRevitCode
{
    public static object? Execute(string code, UIApplication uiApplication, Transaction? transaction)
    {
        if (string.IsNullOrWhiteSpace(code)) throw new ArgumentException("Code is required", nameof(code));
        var source = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
namespace Aec.Codex.Dynamic {
  public static class UserScript {
    public static object Run(UIApplication uiApp, UIDocument uiDoc, Document doc, Transaction transaction) {
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
            AddReference(parameters, typeof(UIApplication).Assembly);
            AddReference(parameters, typeof(Document).Assembly);
            AddReference(parameters, typeof(DynamicRevitCode).Assembly);
            var compiled = provider.CompileAssemblyFromSource(parameters, source);
            if (compiled.Errors.HasErrors)
            {
                var errors = compiled.Errors.Cast<CompilerError>()
                    .Where(error => !error.IsWarning)
                    .Select(error => $"line {Math.Max(1, error.Line - 12)}: {error.ErrorText}");
                throw new InvalidOperationException("Revit code compilation failed: " + string.Join("; ", errors));
            }
            var method = compiled.CompiledAssembly.GetType("Aec.Codex.Dynamic.UserScript", true)
                .GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            try
            {
                var uiDocument = uiApplication.ActiveUIDocument
                    ?? throw new InvalidOperationException("No active Revit document");
                return method!.Invoke(null, new object?[] { uiApplication, uiDocument, uiDocument.Document, transaction });
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
