using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Geometry;
using Autodesk.AutoCAD.Colors;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace BimBridge.AutoCAD;

internal sealed class RuntimeCodeCompiler : IAutoCADCodeCompiler
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
                "AutoCAD code compilation failed: " + string.Join("; ", errors));
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
                TryAddManagedAssembly(paths, path);
        }
        AddAssembly(paths, typeof(Document).Assembly);
        AddAssembly(paths, typeof(DocumentExtension).Assembly);
        AddAssembly(paths, typeof(Transaction).Assembly);
        AddAssembly(paths, typeof(Point3d).Assembly);
        AddAssembly(paths, typeof(Color).Assembly);
        return paths.Select(path => MetadataReference.CreateFromFile(path));
    }

    private static void AddAssembly(ISet<string> paths, Assembly assembly)
    {
        if (!string.IsNullOrWhiteSpace(assembly.Location)) paths.Add(assembly.Location);
    }

    private static void TryAddManagedAssembly(ISet<string> paths, string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
        try
        {
            AssemblyName.GetAssemblyName(path);
            paths.Add(path);
        }
        catch (BadImageFormatException)
        {
            // AutoCAD includes native binaries in TRUSTED_PLATFORM_ASSEMBLIES.
        }
        catch (FileLoadException)
        {
            // Ignore entries that are not valid managed metadata references.
        }
    }
}
