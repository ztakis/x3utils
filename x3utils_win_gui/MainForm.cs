using System.Drawing;

namespace X3Utils.WinGui;

internal sealed class MainForm : Form
{
    private readonly TextBox _firmwarePathTextBox = new();
    private readonly Button _browseButton = new();
    private readonly Button _checkAdapterButton = new();
    private readonly Button _flashButton = new();
    private readonly CheckBox _showLogCheckBox = new();
    private readonly Button _copyLogButton = new();
    private readonly TextBox _logTextBox = new();
    private readonly Label _statusLabel = new();

    private OpenOcdPaths? _paths;
    private OpenOcdRunner? _runner;
    private string _lastLog = string.Empty;

    public MainForm()
    {
        Text = "x3utils Windows GUI v0.1";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(760, 460);
        Size = new Size(860, 560);

        BuildLayout();
        Load += OnLoad;
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(12),
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var titleLabel = new Label
        {
            AutoSize = true,
            Font = new Font(Font, FontStyle.Bold),
            Text = "x3utils Windows GUI v0.1",
        };
        root.Controls.Add(titleLabel, 0, 0);

        var firmwarePanel = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            ColumnCount = 3,
            AutoSize = true,
            Padding = new Padding(0, 12, 0, 0),
        };
        firmwarePanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        firmwarePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        firmwarePanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var firmwareLabel = new Label
        {
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Text = "Firmware .bin:",
        };

        _firmwarePathTextBox.Dock = DockStyle.Fill;
        _firmwarePathTextBox.ReadOnly = true;

        _browseButton.AutoSize = true;
        _browseButton.Text = "Browse...";
        _browseButton.Click += OnBrowseClick;

        firmwarePanel.Controls.Add(firmwareLabel, 0, 0);
        firmwarePanel.Controls.Add(_firmwarePathTextBox, 1, 0);
        firmwarePanel.Controls.Add(_browseButton, 2, 0);
        root.Controls.Add(firmwarePanel, 0, 1);

        var actionsPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            Padding = new Padding(0, 12, 0, 8),
        };

        _checkAdapterButton.AutoSize = true;
        _checkAdapterButton.Text = "Check connection";
        _checkAdapterButton.Click += OnCheckAdapterClick;

        _flashButton.AutoSize = true;
        _flashButton.Text = "Flash";
        _flashButton.Enabled = false;
        _flashButton.Click += OnFlashClick;

        _showLogCheckBox.AutoSize = true;
        _showLogCheckBox.Text = "Show raw console log";
        _showLogCheckBox.CheckedChanged += (_, _) => UpdateLogVisibility();

        _copyLogButton.AutoSize = true;
        _copyLogButton.Text = "Copy log";
        _copyLogButton.Enabled = false;
        _copyLogButton.Click += (_, _) => Clipboard.SetText(_lastLog);

        actionsPanel.Controls.Add(_checkAdapterButton);
        actionsPanel.Controls.Add(_flashButton);
        actionsPanel.Controls.Add(_showLogCheckBox);
        actionsPanel.Controls.Add(_copyLogButton);
        root.Controls.Add(actionsPanel, 0, 2);

        var lowerPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
        };
        lowerPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        lowerPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        _statusLabel.AutoSize = true;
        _statusLabel.Text = "Starting...";
        lowerPanel.Controls.Add(_statusLabel, 0, 0);

        _logTextBox.Dock = DockStyle.Fill;
        _logTextBox.Multiline = true;
        _logTextBox.ReadOnly = true;
        _logTextBox.ScrollBars = ScrollBars.Vertical;
        _logTextBox.WordWrap = true;
        _logTextBox.Font = new Font(FontFamily.GenericMonospace, 9);
        lowerPanel.Controls.Add(_logTextBox, 0, 1);

        root.Controls.Add(lowerPanel, 0, 3);
        Controls.Add(root);

        UpdateLogVisibility();
    }

    private void OnLoad(object? sender, EventArgs args)
    {
        try
        {
            _paths = OpenOcdPaths.Find();
            _runner = new OpenOcdRunner(_paths);
            SetStatus("Ready. Found OpenOCD: " + _paths.OpenOcdExe);
        }
        catch (Exception ex)
        {
            SetStatus(ex.Message);
            SetBusyState(enabled: false);
            _browseButton.Enabled = false;
        }
    }

    private void OnBrowseClick(object? sender, EventArgs args)
    {
        using var dialog = new OpenFileDialog
        {
            Filter = "Firmware (*.bin)|*.bin|All files (*.*)|*.*",
            Title = "Select firmware .bin",
            CheckFileExists = true,
        };

        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }

        var result = FirmwareValidator.Validate(dialog.FileName);
        if (!result.IsValid)
        {
            _firmwarePathTextBox.Text = string.Empty;
            _flashButton.Enabled = false;
            SetStatus(result.Message);
            return;
        }

        _firmwarePathTextBox.Text = dialog.FileName;
        _flashButton.Enabled = _runner is not null;
        SetStatus("Firmware loaded: " + Path.GetFileName(dialog.FileName));
    }

    private async void OnCheckAdapterClick(object? sender, EventArgs args)
    {
        if (_runner is null)
        {
            return;
        }

        await RunOpenOcdAsync(
            "Checking connection...",
            runner => runner.CheckAdapterAsync(AppendLog, CancellationToken.None),
            successMessage: "Connection check completed.",
            failMessage: "Connection check failed.");
    }

    private async void OnFlashClick(object? sender, EventArgs args)
    {
        if (_runner is null)
        {
            return;
        }

        var firmwarePath = _firmwarePathTextBox.Text;
        var result = FirmwareValidator.Validate(firmwarePath);
        if (!result.IsValid)
        {
            SetStatus(result.Message);
            return;
        }

        var confirm = MessageBox.Show(
            this,
            "Flash this firmware to the chip?\n\n" + firmwarePath,
            "Confirm flash",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);

        if (confirm != DialogResult.Yes)
        {
            SetStatus("Flash cancelled.");
            return;
        }

        await RunOpenOcdAsync(
            "Flashing firmware...",
            runner => runner.FlashAsync(firmwarePath, AppendLog, CancellationToken.None),
            successMessage: "Flashing completed and verified successfully.",
            failMessage: "OpenOCD failed. Nothing was verified.");
    }

    private async Task RunOpenOcdAsync(
        string runningMessage,
        Func<OpenOcdRunner, Task<OpenOcdResult>> operation,
        string successMessage,
        string failMessage)
    {
        if (_runner is null)
        {
            return;
        }

        ClearLog();
        SetStatus(runningMessage);
        SetBusyState(enabled: false);

        try
        {
            var result = await operation(_runner);
            _lastLog = result.Log;
            _copyLogButton.Enabled = !string.IsNullOrWhiteSpace(_lastLog);
            SetStatus(result.IsSuccess ? successMessage : $"{failMessage} Exit code: {result.ExitCode}.");
        }
        catch (Exception ex)
        {
            AppendLog(ex.ToString() + Environment.NewLine);
            _lastLog = _logTextBox.Text;
            _copyLogButton.Enabled = true;
            SetStatus("Operation failed: " + ex.Message);
        }
        finally
        {
            SetBusyState(enabled: true);
        }
    }

    private void SetBusyState(bool enabled)
    {
        _checkAdapterButton.Enabled = enabled && _runner is not null;
        _browseButton.Enabled = enabled && _runner is not null;
        _flashButton.Enabled = enabled && _runner is not null && !string.IsNullOrWhiteSpace(_firmwarePathTextBox.Text);
    }

    private void SetStatus(string message)
    {
        _statusLabel.Text = message;
    }

    private void ClearLog()
    {
        _logTextBox.Clear();
        _lastLog = string.Empty;
        _copyLogButton.Enabled = false;
    }

    private void AppendLog(string text)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => AppendLog(text));
            return;
        }

        _logTextBox.AppendText(text);
        _lastLog = _logTextBox.Text;
    }

    private void UpdateLogVisibility()
    {
        _logTextBox.Visible = _showLogCheckBox.Checked;
    }
}
