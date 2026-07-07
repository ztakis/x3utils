namespace X3Utils.WinGui;

internal sealed class OpenOcdPaths
{
    private OpenOcdPaths(string repoRoot, string openOcdExe, string scriptsDir)
    {
        RepoRoot = repoRoot;
        OpenOcdExe = openOcdExe;
        ScriptsDir = scriptsDir;
    }

    public string RepoRoot { get; }

    public string OpenOcdExe { get; }

    public string ScriptsDir { get; }

    public static OpenOcdPaths Find()
    {
        var startPoints = new[]
        {
            AppContext.BaseDirectory,
            Environment.CurrentDirectory,
        };

        foreach (var startPoint in startPoints)
        {
            var directory = new DirectoryInfo(startPoint);
            while (directory is not null)
            {
                var candidate = TryFromRepoRoot(directory.FullName);
                if (candidate is not null)
                {
                    return candidate;
                }

                directory = directory.Parent;
            }
        }

        throw new FileNotFoundException(
            "Could not find bundled OpenOCD. Expected oocd\\bin\\openocd.exe beside the GUI or under x3utils_win_gui.");
    }

    private static OpenOcdPaths? TryFromRepoRoot(string repoRoot)
    {
        var candidates = new[]
        {
            Path.Combine(repoRoot, "oocd"),
            Path.Combine(repoRoot, "x3utils_win_gui", "oocd"),
            Path.Combine(repoRoot, "x3utils_win", "oocd"),
        };

        foreach (var oocdRoot in candidates)
        {
            var openOcdExe = Path.Combine(oocdRoot, "bin", "openocd.exe");
            var scriptsDir = Path.Combine(oocdRoot, "scripts");

            if (File.Exists(openOcdExe) && Directory.Exists(scriptsDir))
            {
                return new OpenOcdPaths(repoRoot, openOcdExe, scriptsDir);
            }
        }

        return null;
    }
}
