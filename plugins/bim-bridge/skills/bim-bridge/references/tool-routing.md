# Tool routing

## Prefer structured tools

Choose the narrowest tool that can complete the request. Structured tools make
intent, validation, idempotency, and approval behavior clearer than arbitrary
code. Query before mutation and return stable element/entity identifiers.

## Revit fallback code

Run through the Revit connector's `ExternalEvent` context. Use the provided
variables `uiApp`, `uiDoc`, `doc`, and `transaction`. Do not create another UI
thread or start/commit a top-level transaction: the connector owns one native
transaction group per write request and rolls it back on any exception. Return
only JSON-serializable primitives, arrays, dictionaries, or anonymous objects.

Example read body:

```csharp
return new FilteredElementCollector(doc)
    .OfClass(typeof(Wall)).Take(100)
    .Select(e => new { id = e.Id.Value, name = e.Name }).ToList();
```

Example write body:

```csharp
var curve = Line.CreateBound(new XYZ(0, 0, 0), new XYZ(10, 0, 0));
var level = new FilteredElementCollector(doc).OfClass(typeof(Level)).Cast<Level>().First();
var wall = Wall.Create(doc, curve, level.Id, false);
return new { id = wall.Id.Value, uniqueId = wall.UniqueId };
```

## AutoCAD fallback code

Run through the connector's supported command context. Lock the target document
and transaction are already provided as `document`, `database`, `editor`, and
`transaction`. Do not lock, commit, abort, or dispose them in generated code.
Open objects in the least permissive mode and return JSON-serializable data.

Example read body:

```csharp
var table = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead);
var space = (BlockTableRecord)transaction.GetObject(table[BlockTableRecord.ModelSpace], OpenMode.ForRead);
return space.Cast<ObjectId>().Take(100).Select(id => new { handle = id.Handle.ToString() }).ToList();
```

Example write body:

```csharp
var table = (BlockTable)transaction.GetObject(database.BlockTableId, OpenMode.ForRead);
var space = (BlockTableRecord)transaction.GetObject(table[BlockTableRecord.ModelSpace], OpenMode.ForWrite);
var line = new Line(new Point3d(0, 0, 0), new Point3d(1000, 0, 0));
space.AppendEntity(line);
transaction.AddNewlyCreatedDBObject(line, true);
return new { handle = line.Handle.ToString(), type = "Line" };
```

## Cross-version behavior

Use connector capabilities rather than guessing from a year number. Do not use
a 2027-only API in a 2024 session. If a capability is absent, explain the
version limitation or choose a documented compatibility path.

## Focused Revit view capture

When the user authorizes visual verification, search for the structured Revit
view-capture tool, inspect its schema, and invoke it through
`aec_call_provider_read`. The built-in `revit.view.capture` capability exports
the active view or one exact `viewId`, `viewUniqueId`, or `viewName` to PNG. It
accepts bounded `pixelSize`, `dpi`, and `fitDirection` arguments and returns the
created path plus view identity. Files are written only under BIM Bridge's local
capture directory; callers cannot choose an arbitrary filesystem directory.

Do not change view orientation, visibility, crop, or section-box state in the
capture request. If a verification view must be prepared, create or update it
in the preceding write request and then capture it separately. If provider
discovery proves that the installed connector predates `view.capture`, use the
explicit `revit.code.read` compatibility fallback below until BIM Bridge is
upgraded.

Legacy compatibility method body:

```csharp
var view = new FilteredElementCollector(doc)
    .OfClass(typeof(View3D)).Cast<View3D>()
    .First(v => !v.IsTemplate && v.Name == "BB-Demo Verification");
var root = @"C:\\bounded\\verification-output";
System.IO.Directory.CreateDirectory(root);
var prefix = System.IO.Path.Combine(
    root,
    "revit-" + uiApp.Application.VersionNumber + "-verification");
var options = new ImageExportOptions
{
    ExportRange = ExportRange.SetOfViews,
    FilePath = prefix,
    HLRandWFViewsFileType = ImageFileType.PNG,
    ShadowViewsFileType = ImageFileType.PNG,
    ImageResolution = ImageResolution.DPI_150,
    ZoomType = ZoomFitType.FitToPage,
    PixelSize = 1600,
    FitDirection = FitDirectionType.Horizontal
};
options.SetViewsAndSheets(new List<ElementId> { view.Id });
doc.ExportImage(options);
return System.IO.Directory.GetFiles(
    root,
    System.IO.Path.GetFileName(prefix) + "*.png");
```
