using System;
using System.Reflection;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace BimBridge.Revit;

internal static class DynamicRevitCode
{
    private static readonly IRevitCodeCompiler Compiler = new RuntimeCodeCompiler();

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
namespace BimBridge.Dynamic {
  public static class UserScript {
    public static object Run(UIApplication uiApp, UIDocument uiDoc, Document doc, Transaction transaction) {
#line 1 ""user-code""
" + code + @"
#line default
    }
  }
}";

        var assembly = Compiler.Compile(source);
        var method = assembly.GetType("BimBridge.Dynamic.UserScript", throwOnError: true)!
            .GetMethod("Run", BindingFlags.Public | BindingFlags.Static)!;
        try
        {
            var uiDocument = uiApplication.ActiveUIDocument
                ?? throw new InvalidOperationException("No active Revit document");
            return method.Invoke(
                null,
                new object?[] { uiApplication, uiDocument, uiDocument.Document, transaction });
        }
        catch (TargetInvocationException exception) when (exception.InnerException != null)
        {
            throw exception.InnerException;
        }
    }
}
