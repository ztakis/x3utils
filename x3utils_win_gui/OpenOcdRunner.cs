using System.Diagnostics;
using System.Text;

namespace X3Utils.WinGui;

internal sealed class OpenOcdRunner
{
    private readonly OpenOcdPaths _paths;

    public OpenOcdRunner(OpenOcdPaths paths)
    {
        _paths = paths;
    }

    public Task<OpenOcdResult> CheckAdapterAsync(Action<string> onOutput, CancellationToken cancellationToken)
    {
        var arguments = new[]
        {
            "-s", Quote(_paths.ScriptsDir),
            "-d0",
            "-f", "interface/stlink.cfg",
            "-f", "target/at32f415xx.cfg",
            "-c", Quote("adapter speed 1000"),
            "-c", Quote("init"),
            "-c", Quote("reset halt"),
            "-c", Quote("flash probe 0"),
            "-c", Quote("exit"),
        };

        return RunAsync(arguments, onOutput, cancellationToken);
    }

    public Task<OpenOcdResult> FlashAsync(string firmwarePath, Action<string> onOutput, CancellationToken cancellationToken)
    {
        var normalizedPath = FirmwareValidator.ToOpenOcdPath(firmwarePath);
        var arguments = new[]
        {
            "-s", Quote(_paths.ScriptsDir),
            "-d0",
            "-f", "interface/stlink.cfg",
            "-f", "target/at32f415xx.cfg",
            "-c", Quote("init"),
            "-c", Quote("reset halt"),
            "-c", Quote("flash erase_address 0x08000000 0x20000"),
            "-c", Quote($"flash write_bank 0 {{{normalizedPath}}}"),
            "-c", Quote($"verify_image {{{normalizedPath}}} 0x08000000"),
            "-c", Quote("exit"),
        };

        return RunAsync(arguments, onOutput, cancellationToken);
    }

    private async Task<OpenOcdResult> RunAsync(
        IReadOnlyCollection<string> arguments,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        var log = new StringBuilder();
        var startInfo = new ProcessStartInfo
        {
            FileName = _paths.OpenOcdExe,
            Arguments = string.Join(" ", arguments),
            WorkingDirectory = Path.GetDirectoryName(_paths.OpenOcdExe) ?? _paths.RepoRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        AppendLine(log, onOutput, "> " + startInfo.FileName + " " + startInfo.Arguments);

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, args) => AppendLine(log, onOutput, args.Data);
        process.ErrorDataReceived += (_, args) => AppendLine(log, onOutput, args.Data);

        if (!process.Start())
        {
            throw new InvalidOperationException("Could not start OpenOCD.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }

            throw;
        }

        return new OpenOcdResult(process.ExitCode, log.ToString());
    }

    private static void AppendLine(StringBuilder log, Action<string> onOutput, string? line)
    {
        if (line is null)
        {
            return;
        }

        lock (log)
        {
            log.AppendLine(line);
        }

        onOutput(line + Environment.NewLine);
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}

internal sealed record OpenOcdResult(int ExitCode, string Log)
{
    public bool IsSuccess => ExitCode == 0;
}
