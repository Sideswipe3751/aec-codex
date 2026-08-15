# Drawing-to-model reconstruction

Use this workflow when creating or updating a Revit or AutoCAD model from PDF,
image, scan, CAD, or other reference drawings. Treat a request for a complete
model as a fidelity task, not as permission to produce schematic massing.

## Source ledger

Before the first model write, create a concise ledger of the relevant source
sheets and their authority:

- plans define level footprints, rooms, grids, openings, and horizontal
  placement;
- elevations define setbacks, cantilevers, façade composition, height, and
  visible openings;
- sections define vertical relationships, assemblies, stairs, parapets, and
  slab or roof offsets;
- schedules and legends define types, identifiers, materials, and quantities;
- details resolve local conditions but do not silently override coordinated
  plans, elevations, or sections.

Record conflicts and assumptions. An agent may choose a reversible minor
assumption when the source is genuinely silent, but it must not relabel a
clearly drawn architectural feature as an optional simplification.

## Mandatory staged workflow

1. Read the active document, existing elements, units, levels, views, types,
   warnings, and available structured providers.
2. Extract levels, grids or reference axes, per-level footprints, major voids,
   and vertical datum before creating walls.
3. Build and read back the primary form one level at a time. Compare each
   level's outline with both its plan and corresponding elevations.
4. Add roofs, parapets, floor edges, setbacks, cantilevers, shafts, stairs,
   balconies, guards, canopies, and other form-defining elements before façade
   decoration.
5. Place doors, windows, skylights, and openings from source identifiers and
   coordinates. Do not use repeated representative positions unless the user
   explicitly requested a schematic model.
6. Apply the source material and type distinctions that materially affect the
   building appearance or documentation.
7. Query all affected categories, relationships, dimensions, and warnings.
8. Capture focused 3D, plan, and elevation views and compare them against the
   source. Apply up to two bounded correction passes.

## Core-form rule

Never treat these as harmless simplifications in a complete reconstruction:

- a stepped or L-shaped footprint replaced by one rectangle;
- different upper-level extents replaced by identical floor plates;
- a roof or parapet replaced only by an undifferentiated floor slab;
- missing cantilevers, balconies, guardrails, shafts, stairs, or skylights;
- source openings replaced by approximate counts at invented locations;
- several documented exterior materials replaced by one generic type.

If a required family or structured tool is unavailable, use an authorized
bounded fallback when safe. Otherwise report a concrete blocker; do not claim
the model is complete.

## Completion gate

Do not report completion until all applicable checks pass:

- every relevant source sheet is accounted for;
- every level has a measured footprint and expected elevation;
- element counts and source identifiers reconcile by category and level;
- form-defining roofs, openings, stairs, balconies, guards, and parapets are
  either modeled or explicitly identified as blockers;
- required materials and types are distinguishable;
- no new unresolved Autodesk warning affects the modeled work;
- focused plan, elevation, and 3D comparisons show no obvious missing mass,
  setback, cantilever, opening group, or façade system;
- the final report separates completed work, assumptions, verified evidence,
  and unresolved blockers.

For multi-sheet reconstruction, prefer WorkBuddy's high-accuracy reasoning and
vision mode. A fast mode is suitable for a preliminary massing pass only and
must not label that pass as a completed reconstruction.
