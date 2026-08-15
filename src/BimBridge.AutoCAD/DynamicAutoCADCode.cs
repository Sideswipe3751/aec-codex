using System;
using System.Reflection;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;

namespace BimBridge.AutoCAD;

internal static class DynamicAutoCADCode
{
    private static readonly IAutoCADCodeCompiler Compiler = new RuntimeCodeCompiler();

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
namespace BimBridge.Dynamic {
  public static class UserScript {
    public static object Run(Document document, Database database, Editor editor, Transaction transaction) {
" + code + @"
    }
  }
}";

        var method = Compiler.Compile(source)
            .GetType("BimBridge.Dynamic.UserScript", true)
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
