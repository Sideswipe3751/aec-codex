using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text;

#if NET48
using System.Web.Script.Serialization;
#else
using System.Text.Json;
#endif

namespace Aec.Codex.Bridge;

internal sealed class JsonCodecException : Exception
{
    public JsonCodecException(string message) : base(message) { }
    public JsonCodecException(string message, Exception innerException) : base(message, innerException) { }
}

internal static class JsonCodec
{
#if NET48
    private static JavaScriptSerializer CreateSerializer() => new JavaScriptSerializer
    {
        MaxJsonLength = int.MaxValue,
        RecursionLimit = 100
    };

    public static string Serialize(object value) => CreateSerializer().Serialize(Prepare(value));

    public static byte[] SerializeToUtf8Bytes(object value) => Encoding.UTF8.GetBytes(Serialize(value));

    public static T? Deserialize<T>(byte[] bytes)
    {
        try
        {
            return CreateSerializer().Deserialize<T>(Encoding.UTF8.GetString(bytes));
        }
        catch (Exception exception)
        {
            throw new JsonCodecException("Invalid JSON request body", exception);
        }
    }

    public static object? Normalize(object? value) => value;

    private static object? Prepare(object? value)
    {
        if (value == null || value is string || value is bool || value is char ||
            value is byte || value is sbyte || value is short || value is ushort ||
            value is int || value is uint || value is long || value is ulong ||
            value is float || value is double || value is decimal)
        {
            return value;
        }

        if (value is Enum enumValue) return Convert.ToInt32(enumValue);
        if (value is byte[] bytes) return Convert.ToBase64String(bytes);

        if (value is IDictionary dictionary)
        {
            var result = new Dictionary<string, object?>();
            foreach (DictionaryEntry entry in dictionary)
            {
                result[Convert.ToString(entry.Key) ?? string.Empty] = Prepare(entry.Value);
            }
            return result;
        }

        if (value is IEnumerable enumerable)
        {
            var result = new List<object?>();
            foreach (var item in enumerable) result.Add(Prepare(item));
            return result;
        }

        return value.GetType()
            .GetProperties(BindingFlags.Instance | BindingFlags.Public)
            .Where(property => property.CanRead && property.GetIndexParameters().Length == 0)
            .ToDictionary(
                property => CamelCase(property.Name),
                property => Prepare(property.GetValue(value, null)));
    }

    private static string CamelCase(string value) =>
        string.IsNullOrEmpty(value) || char.IsLower(value[0])
            ? value
            : char.ToLowerInvariant(value[0]) + value.Substring(1);
#else
    private static readonly JsonSerializerOptions Options = new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public static string Serialize(object value) => JsonSerializer.Serialize(value, Options);

    public static byte[] SerializeToUtf8Bytes(object value) =>
        JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T? Deserialize<T>(byte[] bytes)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(bytes, Options);
        }
        catch (JsonException exception)
        {
            throw new JsonCodecException("Invalid JSON request body", exception);
        }
    }

    public static object? Normalize(object? value)
    {
        if (!(value is JsonElement element)) return value;
        return JsonSerializer.Deserialize<object>(element.GetRawText());
    }
#endif
}
