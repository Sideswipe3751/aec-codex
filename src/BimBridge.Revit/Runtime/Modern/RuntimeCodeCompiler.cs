using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace BimBridge.Revit;

internal sealed class RuntimeCodeCompiler : IRevitCodeCompiler
{
    public Assembly Compile(string source)
    {
        var syntaxTree = CSharpSyntaxTree.ParseText(
            source,
            new CSharpParseOptions(LanguageVersion.Latest));
        var compilation = CSharpCompilation.Create(
            "BimBridge.Dynamic." + Guid.NewGuid().ToString("N"),
            new[] { syntaxTree },
            CreateReferences(),
            new CSharpCompilationOptions(
                OutputKind.DynamicallyLinkedLibrary,
                optimizationLevel: OptimizationLevel.Release));

        using var assemblyBytes = new MemoryStream();
        var emit = compilation.Emit(assemblyBytes);
        if (!emit.Success)
        {
            var errors = emit.Diagnostics
                .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error)
                .Select(diagnostic => diagnostic.ToString());
            throw new InvalidOperationException(
                "Revit code compilation failed: " + string.Join("; ", errors));
        }

        assemblyBytes.Position = 0;
        return AssemblyLoadContext.Default.LoadFromStream(assemblyBytes);
    }

    private static IEnumerable<MetadataReference> CreateReferences()
    {
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") is string platformAssemblies)
        {
            foreach (var path in platformAssemblies.Split(Path.PathSeparator))
                paths.Add(path);
        }
        AddAssembly(paths, typeof(UIApplication).Assembly);
        AddAssembly(paths, typeof(Document).Assembly);
        return paths.Select(path => MetadataReference.CreateFromFile(path));
    }

    private static void AddAssembly(ISet<string> paths, Assembly assembly)
    {
        if (!string.IsNullOrWhiteSpace(assembly.Location)) paths.Add(assembly.Location);
    }
}
