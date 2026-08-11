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
