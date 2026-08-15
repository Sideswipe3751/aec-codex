# Drawing and model quality

Use the checks relevant to every drawing, modeling, creation, layout,
annotation, and post-write verification task.

## Establish success criteria

- Confirm the exact application, process, document, view, units, coordinates,
  levels, phases, and placement context before writing.
- Convert the request into measurable geometry, quantity, placement,
  properties, relationships, and visual requirements.
- Inspect nearby objects and preserve project conventions for categories,
  types, materials, worksets, phases, design options, layers, and styles.
- Do not silently choose an important dimension, location, material, type, or
  aesthetic rule that neither the request nor the source determines.

## Structured verification

- Read every created or modified object back after execution.
- Match identifiers and expected counts; detect duplicates and missing items.
- Verify units, coordinates, dimensions, elevations, extents, orientation,
  hosting, constraints, joins, connectivity, containment, and clearances.
- For Revit, inspect relevant categories, families, types, levels, hosts,
  offsets, phases, materials, parameters, and document warnings.
- For AutoCAD, inspect relevant layers, spaces, blocks, polyline closure,
  styles, colors, lineweights, annotation scales, and extents.

## Focused visual verification

- Use a discovered read-only view capture after structured verification when
  appearance or spatial coordination matters.
- Frame the affected objects with enough context to judge placement.
- Check missing objects, duplicates, overlaps, gaps, alignment, clipping,
  scale, visibility, legibility, and obvious visual imbalance.
- Use structured Autodesk data for exact values; never infer dimensions from
  pixels when the model can be queried.

## Correction and completion

- Correct only the objects or properties responsible for a failed check.
- Re-read corrected objects and repeat affected visual checks.
- Stop after two unsuccessful correction passes and report the remaining
  mismatch with evidence.
- Do not claim completion until the required checks pass.
