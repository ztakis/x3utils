using System.Diagnostics;
using System.Text;

namespace X3Utils.WinGui;

internal sealed class OpenOcdRunner
{
    private readonly object _processLock = new();
    private readonly OpenOcdPaths _paths;
    private Process? _activeProcess;

    public OpenOcdRunner(OpenOcdPaths paths)
    {
        _paths = paths;
    }

    public bool SendContinue()
    {
        lock (_processLock)
        {
            if (_activeProcess is null || _activeProcess.HasExited)
            {
                return false;
            }

            try
            {
                _activeProcess.StandardInput.WriteLine();
                _activeProcess.StandardInput.Flush();
                return true;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            catch (IOException)
            {
                return false;
            }
        }
    }

    public Task<OpenOcdResult> CheckAdapterAsync(
        ConnectionMode connectionMode,
        int cloneC45ConnectTimeoutSeconds,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        var commands = connectionMode == ConnectionMode.CloneC45
            ? new[]
            {
                $"guided_connect {{{cloneC45ConnectTimeoutSeconds}}}",
                "flash probe 0",
                "exit",
            }
            : new[]
            {
                "adapter speed 1000",
                "init",
                "reset halt",
                "flash probe 0",
                "exit",
            };

        return RunAsync(BuildArguments(connectionMode, commands), onOutput, cancellationToken);
    }

    public Task<OpenOcdResult> FlashAsync(
        ConnectionMode connectionMode,
        int cloneC45ConnectTimeoutSeconds,
        string firmwarePath,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        var normalizedPath = FirmwareValidator.ToOpenOcdPath(firmwarePath);
        var commands = connectionMode == ConnectionMode.CloneC45
            ? new[]
            {
                $"guided_flash_connect {{{cloneC45ConnectTimeoutSeconds}}}",
                $"do_flash_and_verify {{{normalizedPath}}}",
                "exit",
            }
            : new[]
            {
                "init",
                "reset halt",
                "flash erase_address 0x08000000 0x20000",
                $"flash write_bank 0 {{{normalizedPath}}}",
                $"verify_image {{{normalizedPath}}} 0x08000000",
                "exit",
            };

        return RunAsync(BuildArguments(connectionMode, commands), onOutput, cancellationToken);
    }

    public Task<OpenOcdResult> DumpAsync(
        ConnectionMode connectionMode,
        int cloneC45ConnectTimeoutSeconds,
        string dumpPath,
        Action<string> onOutput,
        CancellationToken cancellationToken)
    {
        var normalizedPath = FirmwareValidator.ToOpenOcdPath(dumpPath);
        var commands = connectionMode == ConnectionMode.CloneC45
            ? new[]
            {
                $"guided_connect {{{cloneC45ConnectTimeoutSeconds}}}",
                $"dump_image {{{normalizedPath}}} 0x08000000 0x20000",
                "exit",
            }
            : new[]
            {
                "init",
                "reset halt",
                "flash probe 0",
                $"dump_image {{{normalizedPath}}} 0x08000000 0x20000",
                "exit",
            };

        return RunAsync(BuildArguments(connectionMode, commands), onOutput, cancellationToken);
    }

    private IReadOnlyCollection<string> BuildArguments(ConnectionMode connectionMode, IReadOnlyList<string> commands)
    {
        var arguments = new List<string>
        {
            "-s", Quote(_paths.ScriptsDir),
            "-d0",
        };

        if (connectionMode == ConnectionMode.CloneC45)
        {
            arguments.AddRange(new[] { "-f", "target/at32f415xx_c45.cfg" });
        }
        else
        {
            arguments.AddRange(new[] { "-f", "interface/stlink.cfg", "-f", GetTargetConfig(connectionMode) });
        }

        foreach (var command in commands)
        {
            arguments.AddRange(new[] { "-c", Quote(command) });
        }

        return arguments;
    }

    private static string GetTargetConfig(ConnectionMode connectionMode)
    {
        return connectionMode switch
        {
            ConnectionMode.GenuineC45 => "target/at32f415xx_nrst.cfg",
            _ => "target/at32f415xx.cfg",
        };
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
            RedirectStandardInput = true,
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

        try
        {
            lock (_processLock)
            {
                _activeProcess = process;
            }

            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
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
        finally
        {
            lock (_processLock)
            {
                if (ReferenceEquals(_activeProcess, process))
                {
                    _activeProcess = null;
                }
            }
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
