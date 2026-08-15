using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.Revit.DB;

namespace BimBridge.Revit;

internal sealed class RevitFailurePreprocessor : IFailuresPreprocessor
{
    private const int MaximumDiagnostics = 50;
    private const int MaximumElementIds = 50;
    private const int MaximumDescriptionLength = 1024;
    private readonly HashSet<string> _seen = new HashSet<string>(StringComparer.Ordinal);
    private readonly List<string> _warnings = new List<string>();
    private readonly List<string> _errors = new List<string>();

    public IReadOnlyList<string> Warnings => _warnings;
    public IReadOnlyList<string> Errors => _errors;

    public FailureProcessingResult PreprocessFailures(FailuresAccessor failuresAccessor)
    {
        if (failuresAccessor == null) throw new ArgumentNullException(nameof(failuresAccessor));

        var mustRollBack = false;
        foreach (var failure in failuresAccessor.GetFailureMessages())
        {
            var severity = failure.GetSeverity();
            var diagnostic = FormatDiagnostic(failure, severity);
            if (severity == FailureSeverity.Warning)
            {
                AddBounded(_warnings, diagnostic);
                failuresAccessor.DeleteWarning(failure);
                continue;
            }

            AddBounded(_errors, diagnostic);
            mustRollBack = true;
        }

        return mustRollBack
            ? FailureProcessingResult.ProceedWithRollBack
            : FailureProcessingResult.Continue;
    }

    public string BuildErrorMessage() =>
        _errors.Count == 0
            ? "Revit did not commit the transaction"
            : "Revit rejected the transaction: " + string.Join(" | ", _errors);

    private void AddBounded(List<string> target, string diagnostic)
    {
        if (!_seen.Add(diagnostic) || target.Count >= MaximumDiagnostics) return;
        target.Add(diagnostic);
    }

    private static string FormatDiagnostic(FailureMessageAccessor failure, FailureSeverity severity)
    {
        var description = failure.GetDescriptionText() ?? "Revit reported an unspecified failure.";
        if (description.Length > MaximumDescriptionLength)
            description = description.Substring(0, MaximumDescriptionLength) + "...";

        var failureId = failure.GetFailureDefinitionId()?.Guid.ToString("D") ?? "unknown";
        var failing = FormatElementIds(failure.GetFailingElementIds());
        var additional = FormatElementIds(failure.GetAdditionalElementIds());
        return severity + ": " + description
            + " [failureId=" + failureId
            + "; failingElementIds=" + failing
            + "; additionalElementIds=" + additional + "]";
    }

    private static string FormatElementIds(IEnumerable<ElementId> ids)
    {
        var values = ids.Take(MaximumElementIds)
            .Select(id => RevitApiCompatibility.GetElementIdValue(id).ToString())
            .ToList();
        return "[" + string.Join(",", values) + "]";
    }
}
