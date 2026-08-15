# Drawing and model quality

Use this checklist for drawing, modeling, creation, layout, annotation, and
post-write verification tasks. Apply only the checks relevant to the request.

## Establish success criteria

- Confirm the target application, document, view or space, units, coordinate
  system, level, and other placement context before writing.
- Convert the request into measurable geometry, quantity, placement,
  properties, and visual requirements.
- Inspect nearby or related objects and preserve project conventions for
  layers, categories, types, styles, worksets, phases, and design options.
- Ask before choosing a material dimension, location, type, or aesthetic rule
  that the request and document context do not determine.
- Keep the edit bounded to the requested objects. Preserve unrelated content.

## Structured verification

Always query the created or modified objects after execution.

- Match returned identifiers to the objects that were actually created or
  changed. Confirm the expected count and reject unexpected duplicates.
- Verify units, coordinates, dimensions, angles, elevations, extents, and
  orientation against the success criteria.
- Detect zero-length, degenerate, disconnected, self-intersecting, or otherwise
  invalid geometry when those conditions are relevant.
- Verify required containment, intersection, alignment, clearance,
  connectivity, closure, hosting, and relationships with neighboring objects.
- Confirm user-visible properties such as names, layers, categories, types,
  styles, materials, text, and parameters.

For AutoCAD, additionally check relevant layer, color, linetype, lineweight,
space, block, polyline closure, area, text style, dimension style, annotation
scale, and object extents. Do not leave duplicate or unintended construction
geometry unless the user requested it.

For Revit, additionally check relevant category, family, type, level, host,
workset, phase, design option, constraints, offsets, parameters, joins,
connectors, and warnings. Do not assume that a successfully created element is
correctly hosted, constrained, or visible in the intended view.

## Focused visual verification

Use a visual check when appearance or spatial presentation matters, including
layout, annotation, text, dimensions, alignment, overlap, clipping, scale,
visibility, and legibility.

- Prefer a read-only provider or connector tool that exports or captures the
  relevant Autodesk view. Use only a tool discovered at runtime.
- If no structured capture tool exists, use an available Codex screenshot
  capability only when the user requested or authorized visual verification.
- Frame the affected objects closely while retaining enough surrounding
  context to judge placement. Avoid the full desktop and unrelated content.
- Check for missing objects, unexpected duplicates, overlaps, gaps,
  misalignment, clipping, unreadable annotation, incorrect scale, and obvious
  visual imbalance.
- Do not infer exact dimensions or properties from pixels. Resolve conflicts in
  favor of structured Autodesk data and investigate why the view appears
  inconsistent.
- If visual capture is unavailable or not authorized, complete the structured
  checks and disclose that visual verification was not performed.

## Correction and completion

- Correct only the objects or properties responsible for a failed check.
- Re-read every corrected object and repeat any visual check affected by the
  correction.
- Stop after two unsuccessful correction passes and explain the remaining
  mismatch, evidence, and safest next action.
- Report success criteria, affected identifiers, data checks, visual checks,
  corrections, and unresolved limitations in the final result.
