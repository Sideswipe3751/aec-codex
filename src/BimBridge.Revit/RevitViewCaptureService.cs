using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BimBridge.Host;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace BimBridge.Revit;

internal static class RevitViewCaptureService
{
    private const int MinimumPixelSize = 256;
    private const int MaximumPixelSize = 4096;

    public static object Capture(UIApplication application, ConnectorViewCaptureOptions options)
    {
        if (application == null) throw new ArgumentNullException(nameof(application));
        if (options == null) throw new ArgumentNullException(nameof(options));
        var uiDocument = application.ActiveUIDocument
            ?? throw new InvalidOperationException("No active Revit document");
        var document = uiDocument.Document;
        var view = ResolveView(document, uiDocument, options);
        if (view.IsTemplate) throw new InvalidOperationException("A view template cannot be captured");
        if (!view.CanBePrinted) throw new InvalidOperationException("The selected Revit view cannot be exported");
        if (options.PixelSize < MinimumPixelSize || options.PixelSize > MaximumPixelSize)
            throw new InvalidOperationException("pixelSize must be from 256 through 4096");

        var resolution = ResolveResolution(options.Dpi);
        var fitDirection = ResolveFitDirection(options.FitDirection);
        var captureRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BIM Bridge",
            "captures",
            "revit",
            application.Application.VersionNumber);
        Directory.CreateDirectory(captureRoot);

        var fileStem = SanitizeFileStem(options.FileStem);
        var prefix = fileStem + "-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff")
            + "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        var basePath = Path.Combine(captureRoot, prefix);
        using (var exportOptions = new ImageExportOptions
        {
            ExportRange = ExportRange.SetOfViews,
            FilePath = basePath,
            HLRandWFViewsFileType = ImageFileType.PNG,
            ShadowViewsFileType = ImageFileType.PNG,
            ImageResolution = resolution,
            ZoomType = ZoomFitType.FitToPage,
            PixelSize = options.PixelSize,
            FitDirection = fitDirection
        })
        {
            exportOptions.SetViewsAndSheets(new List<ElementId> { view.Id });
            document.ExportImage(exportOptions);
        }

        var exportedPath = Directory.GetFiles(captureRoot, prefix + "*.png")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
        if (exportedPath == null)
            throw new InvalidOperationException("Revit did not produce the expected PNG capture");
        var file = new FileInfo(exportedPath);
        return new
        {
            path = file.FullName,
            format = "png",
            fileSizeBytes = file.Length,
            viewId = RevitApiCompatibility.GetElementIdValue(view.Id),
            viewUniqueId = view.UniqueId,
            viewName = view.Name,
            pixelSize = options.PixelSize,
            dpi = options.Dpi,
            fitDirection = options.FitDirection,
            capturedAtUtc = DateTime.UtcNow.ToString("o")
        };
    }

    private static View ResolveView(
        Document document,
        UIDocument uiDocument,
        ConnectorViewCaptureOptions options)
    {
        var selectors = 0;
        if (options.ViewId.HasValue) selectors++;
        if (!string.IsNullOrWhiteSpace(options.ViewUniqueId)) selectors++;
        if (!string.IsNullOrWhiteSpace(options.ViewName)) selectors++;
        if (selectors > 1)
            throw new InvalidOperationException("Pass only one of viewId, viewUniqueId, or viewName");
        if (options.ViewId.HasValue)
            return document.GetElement(new ElementId(options.ViewId.Value)) as View
                ?? throw new InvalidOperationException("The requested viewId was not found");
        if (!string.IsNullOrWhiteSpace(options.ViewUniqueId))
            return document.GetElement(options.ViewUniqueId!.Trim()) as View
                ?? throw new InvalidOperationException("The requested viewUniqueId was not found");
        if (!string.IsNullOrWhiteSpace(options.ViewName))
        {
            var matches = new FilteredElementCollector(document)
                .OfClass(typeof(View))
                .Cast<View>()
                .Where(candidate => !candidate.IsTemplate &&
                    string.Equals(candidate.Name, options.ViewName!.Trim(), StringComparison.Ordinal))
                .ToList();
            if (matches.Count == 0) throw new InvalidOperationException("The requested viewName was not found");
            if (matches.Count > 1) throw new InvalidOperationException("The requested viewName is ambiguous");
            return matches[0];
        }
        return uiDocument.ActiveView
            ?? throw new InvalidOperationException("No active Revit view is available");
    }

    private static ImageResolution ResolveResolution(int dpi)
    {
        switch (dpi)
        {
            case 72: return ImageResolution.DPI_72;
            case 150: return ImageResolution.DPI_150;
            case 300: return ImageResolution.DPI_300;
            case 600: return ImageResolution.DPI_600;
            default: throw new InvalidOperationException("dpi must be one of 72, 150, 300, or 600");
        }
    }

    private static FitDirectionType ResolveFitDirection(string? direction)
    {
        if (string.Equals(direction, "vertical", StringComparison.OrdinalIgnoreCase))
            return FitDirectionType.Vertical;
        if (string.IsNullOrWhiteSpace(direction) ||
            string.Equals(direction, "horizontal", StringComparison.OrdinalIgnoreCase))
            return FitDirectionType.Horizontal;
        throw new InvalidOperationException("fitDirection must be horizontal or vertical");
    }

    private static string SanitizeFileStem(string? requested)
    {
        var source = string.IsNullOrWhiteSpace(requested) ? "view" : requested!.Trim();
        var invalid = new HashSet<char>(Path.GetInvalidFileNameChars());
        var safe = new string(source.Take(80)
            .Select(character => invalid.Contains(character) ? '-' : character)
            .ToArray())
            .Trim(' ', '.');
        return string.IsNullOrWhiteSpace(safe) ? "view" : safe;
    }
}
