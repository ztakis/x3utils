namespace X3Utils.WinGui;

internal static class FirmwareValidator
{
    public const long ExpectedSize = 131072;

    public static ValidationResult Validate(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return ValidationResult.Fail("No firmware file selected.");
        }

        if (!File.Exists(path))
        {
            return ValidationResult.Fail("Firmware file does not exist.");
        }

        if (path.Contains('{') || path.Contains('}'))
        {
            return ValidationResult.Fail("Path contains unsupported character: { or }.");
        }

        if (path.Any(c => c > 127))
        {
            return ValidationResult.Fail("Path contains non-ASCII characters. Please use only English letters.");
        }

        if (!string.Equals(Path.GetExtension(path), ".bin", StringComparison.OrdinalIgnoreCase))
        {
            return ValidationResult.Fail("Invalid file type. Only .bin is allowed.");
        }

        var info = new FileInfo(path);
        if (info.Length != ExpectedSize)
        {
            return ValidationResult.Fail($"Invalid file size. Expected {ExpectedSize} bytes, got {info.Length} bytes.");
        }

        if (ContainsOnlyOneRepeatedByte(path))
        {
            return ValidationResult.Fail("Bin file contains only zeros or a single repeated byte.");
        }

        return ValidationResult.Ok();
    }

    public static string ToOpenOcdPath(string path)
    {
        return Path.GetFullPath(path).Replace('\\', '/');
    }

    private static bool ContainsOnlyOneRepeatedByte(string path)
    {
        using var stream = File.OpenRead(path);
        var first = stream.ReadByte();
        if (first < 0)
        {
            return true;
        }

        int current;
        while ((current = stream.ReadByte()) >= 0)
        {
            if (current != first)
            {
                return false;
            }
        }

        return true;
    }
}

internal readonly record struct ValidationResult(bool IsValid, string Message)
{
    public static ValidationResult Ok()
    {
        return new ValidationResult(true, string.Empty);
    }

    public static ValidationResult Fail(string message)
    {
        return new ValidationResult(false, message);
    }
}
