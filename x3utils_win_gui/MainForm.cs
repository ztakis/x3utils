using System.Drawing;

namespace X3Utils.WinGui;

internal sealed class MainForm : Form
{
    private const string AppTitle = "x3utils Windows GUI v0.3";
    private static readonly Color WorkflowNeutralBackColor = SystemColors.Control;
    private static readonly Color WorkflowHoldBackColor = Color.FromArgb(224, 244, 255);
    private static readonly Color WorkflowReleaseBackColor = Color.FromArgb(255, 242, 179);
    private static readonly Color WorkflowSuccessBackColor = Color.FromArgb(229, 246, 232);
    private static readonly Color WorkflowFailureBackColor = Color.FromArgb(255, 232, 232);

    private readonly ComboBox _connectionModeComboBox = new();
    private readonly Label _cloneC45CountdownLabel = new();
    private readonly NumericUpDown _cloneC45CountdownNumericUpDown = new();
    private readonly ComboBox _actionComboBox = new();
    private readonly TextBox _firmwarePathTextBox = new();
    private readonly Button _browseFirmwareButton = new();
    private readonly TextBox _dumpFolderTextBox = new();
    private readonly Button _browseDumpFolderButton = new();
    private readonly Button _startButton = new();
    private readonly GroupBox _workflowGroupBox = new();
    private readonly Label _workflowTitleLabel = new();
    private readonly Label _workflowInstructionLabel = new();
    private readonly Label _workflowStagesLabel = new();
    private readonly ProgressBar _workflowProgressBar = new();
    private readonly Button _retryButton = new();
    private readonly Button _cancelButton = new();
    private readonly Button _continueButton = new();
    private readonly Button _dismissButton = new();
    private readonly Button _showConsoleButton = new();
    private readonly StatusStrip _statusStrip = new();
    private readonly ToolStripStatusLabel _stateStatusLabel = new();
    private readonly ToolStripStatusLabel _firmwareStatusLabel = new();
    private readonly ToolStripStatusLabel _dumpFolderStatusLabel = new();
    private readonly ToolStripStatusLabel _connectionStatusLabel = new();
    private readonly ToolStripStatusLabel _modeStatusLabel = new();
    private readonly ToolStripStatusLabel _openOcdStatusLabel = new();

    private readonly ConsoleForm _consoleForm = new();

    private OpenOcdPaths? _paths;
    private OpenOcdRunner? _runner;
    private ConnectionMode _selectedConnectionMode = ConnectionMode.DefaultSwd;
    private GuiAction _selectedAction = GuiAction.CheckConnection;
    private GuiAction? _lastFailedAction;
    private string _lastLog = string.Empty;
    private string _lastConnectionStatus = "not checked";
    private string _openOcdStatus = "unknown";
    private string? _lastOpenOcdDiagnosis;
    private int _lastOpenOcdDiagnosisPriority;
    private CloneC45Phase _cloneC45Phase = CloneC45Phase.None;
    private bool _isRunning;
    private bool _hasCompletedWorkflow;

    public MainForm()
    {
        Text = AppTitle;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(820, 520);
        Size = new Size(920, 620);

        _dumpFolderTextBox.Text = GetDefaultDumpFolder();

        BuildLayout();
        Load += OnLoad;
        FormClosed += (_, _) => _consoleForm.Dispose();
    }

    private void BuildLayout()
    {
        var menuStrip = BuildMenuStrip();
        MainMenuStrip = menuStrip;

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(12, 0, 12, 12),
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(menuStrip, 0, 0);
        root.Controls.Add(BuildSettingsPanel(), 0, 1);
        root.Controls.Add(BuildWorkflowPanel(), 0, 2);

        BuildStatusStrip();
        root.Controls.Add(_statusStrip, 0, 3);

        Controls.Add(root);
    }

    private MenuStrip BuildMenuStrip()
    {
        var menuStrip = new MenuStrip();

        var fileMenu = new ToolStripMenuItem("File");
        fileMenu.DropDownItems.Add("Open firmware...", null, OnOpenFirmwareMenuClick);
        fileMenu.DropDownItems.Add("Set dump folder...", null, OnSetDumpFolderMenuClick);
        fileMenu.DropDownItems.Add(new ToolStripSeparator());
        fileMenu.DropDownItems.Add("Exit", null, (_, _) => Close());

        var helpMenu = new ToolStripMenuItem("Help");
        helpMenu.DropDownItems.Add("About", null, OnAboutMenuClick);

        menuStrip.Items.Add(fileMenu);
        menuStrip.Items.Add(helpMenu);
        return menuStrip;
    }

    private Control BuildSettingsPanel()
    {
        var settingsGroupBox = new GroupBox
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            Text = "Operation",
            Padding = new Padding(10),
        };

        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 3,
            RowCount = 6,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        _connectionModeComboBox.Dock = DockStyle.Fill;
        _connectionModeComboBox.DropDownStyle = ComboBoxStyle.DropDownList;
        _connectionModeComboBox.Items.Add("Default SWD / Blinker buttons");
        _connectionModeComboBox.Items.Add("C45 / Clone ST-LINK");
        _connectionModeComboBox.Items.Add("C45 / Genuine ST-LINK");
        _connectionModeComboBox.SelectedIndex = 0;
        _connectionModeComboBox.SelectedIndexChanged += (_, _) => OnConnectionModeChanged();

        _cloneC45CountdownLabel.AutoSize = true;
        _cloneC45CountdownLabel.Anchor = AnchorStyles.Left;
        _cloneC45CountdownLabel.Text = "Hold countdown:";
        _cloneC45CountdownLabel.Margin = new Padding(0, 4, 8, 4);

        _cloneC45CountdownNumericUpDown.Minimum = 0;
        _cloneC45CountdownNumericUpDown.Maximum = 10;
        _cloneC45CountdownNumericUpDown.Value = 3;
        _cloneC45CountdownNumericUpDown.Width = 64;
        _cloneC45CountdownNumericUpDown.Margin = new Padding(0, 4, 8, 4);

        _actionComboBox.Dock = DockStyle.Fill;
        _actionComboBox.DropDownStyle = ComboBoxStyle.DropDownList;
        _actionComboBox.Items.Add(new ActionItem(GuiAction.CheckConnection, "Check connection"));
        _actionComboBox.Items.Add(new ActionItem(GuiAction.Dump, "Dump 128 KB"));
        _actionComboBox.Items.Add(new ActionItem(GuiAction.Flash, "Flash firmware"));
        _actionComboBox.SelectedIndex = 0;
        _actionComboBox.SelectedIndexChanged += (_, _) => OnActionChanged();

        _firmwarePathTextBox.Dock = DockStyle.Fill;
        _firmwarePathTextBox.ReadOnly = true;

        _browseFirmwareButton.AutoSize = true;
        _browseFirmwareButton.Text = "Browse...";
        _browseFirmwareButton.Click += OnBrowseFirmwareClick;

        _dumpFolderTextBox.Dock = DockStyle.Fill;
        _dumpFolderTextBox.ReadOnly = true;

        _browseDumpFolderButton.AutoSize = true;
        _browseDumpFolderButton.Text = "Browse...";
        _browseDumpFolderButton.Click += OnBrowseDumpFolderClick;

        _startButton.AutoSize = true;
        _startButton.Text = "Start";
        _startButton.Click += OnStartClick;

        AddRow(grid, 0, "Connection mode:", _connectionModeComboBox, new Label());
        grid.Controls.Add(_cloneC45CountdownLabel, 0, 1);
        grid.Controls.Add(_cloneC45CountdownNumericUpDown, 1, 1);
        grid.Controls.Add(new Label(), 2, 1);
        AddRow(grid, 2, "Action:", _actionComboBox, new Label());
        AddRow(grid, 3, "Firmware .bin:", _firmwarePathTextBox, _browseFirmwareButton);
        AddRow(grid, 4, "Dump folder:", _dumpFolderTextBox, _browseDumpFolderButton);
        AddRow(grid, 5, string.Empty, new Label(), _startButton);

        settingsGroupBox.Controls.Add(grid);
        return settingsGroupBox;
    }

    private Control BuildWorkflowPanel()
    {
        _workflowGroupBox.Dock = DockStyle.Fill;
        _workflowGroupBox.Text = "Workflow";
        _workflowGroupBox.Padding = new Padding(12);

        var workflowGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 5,
        };
        workflowGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        workflowGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        workflowGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        workflowGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        workflowGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        _workflowTitleLabel.AutoSize = true;
        _workflowTitleLabel.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);

        _workflowInstructionLabel.AutoSize = false;
        _workflowInstructionLabel.Dock = DockStyle.Top;
        _workflowInstructionLabel.Font = new Font(Font.FontFamily, 11, FontStyle.Regular);
        _workflowInstructionLabel.MinimumSize = new Size(0, 62);

        _workflowProgressBar.Dock = DockStyle.Top;
        _workflowProgressBar.Style = ProgressBarStyle.Marquee;
        _workflowProgressBar.MarqueeAnimationSpeed = 0;
        _workflowProgressBar.Visible = false;

        _workflowStagesLabel.AutoSize = false;
        _workflowStagesLabel.Dock = DockStyle.Fill;
        _workflowStagesLabel.Font = new Font(FontFamily.GenericMonospace, 9);
        _workflowStagesLabel.Visible = false;

        var buttonsPanel = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(0, 8, 0, 0),
        };

        _retryButton.AutoSize = true;
        _retryButton.Text = "Retry";
        _retryButton.Visible = false;
        _retryButton.Click += OnRetryClick;

        _cancelButton.AutoSize = true;
        _cancelButton.Text = "Cancel";
        _cancelButton.Visible = false;
        _cancelButton.Click += OnCancelClick;

        _continueButton.AutoSize = true;
        _continueButton.Text = "Continue";
        _continueButton.Font = new Font(Font.FontFamily, 11, FontStyle.Bold);
        _continueButton.MinimumSize = new Size(120, 36);
        _continueButton.Visible = false;
        _continueButton.Enabled = false;
        _continueButton.Click += OnContinueClick;

        _dismissButton.AutoSize = true;
        _dismissButton.Text = "Dismiss";
        _dismissButton.Visible = false;
        _dismissButton.Click += OnDismissClick;

        _showConsoleButton.AutoSize = true;
        _showConsoleButton.Text = "Show console";
        _showConsoleButton.Click += (_, _) => ShowConsoleWindow();

        buttonsPanel.Controls.Add(_retryButton);
        buttonsPanel.Controls.Add(_cancelButton);
        buttonsPanel.Controls.Add(_continueButton);
        buttonsPanel.Controls.Add(_dismissButton);
        buttonsPanel.Controls.Add(_showConsoleButton);

        workflowGrid.Controls.Add(_workflowTitleLabel, 0, 0);
        workflowGrid.Controls.Add(_workflowInstructionLabel, 0, 1);
        workflowGrid.Controls.Add(_workflowProgressBar, 0, 2);
        workflowGrid.Controls.Add(_workflowStagesLabel, 0, 3);
        workflowGrid.Controls.Add(buttonsPanel, 0, 4);

        _workflowGroupBox.Controls.Add(workflowGrid);
        SetIdleWorkflow();
        return _workflowGroupBox;
    }

    private void BuildStatusStrip()
    {
        _statusStrip.Dock = DockStyle.Bottom;
        _stateStatusLabel.Text = "Ready";
        _firmwareStatusLabel.Text = "Firmware: none";
        _dumpFolderStatusLabel.Text = "Dump folder: " + _dumpFolderTextBox.Text;
        _connectionStatusLabel.Text = "Last connection: not checked";
        _modeStatusLabel.Text = "Mode: Default SWD";
        _openOcdStatusLabel.Text = "OpenOCD: unknown";

        _statusStrip.Items.Add(_stateStatusLabel);
        _statusStrip.Items.Add(new ToolStripStatusLabel { Text = "|" });
        _statusStrip.Items.Add(_firmwareStatusLabel);
        _statusStrip.Items.Add(new ToolStripStatusLabel { Text = "|" });
        _statusStrip.Items.Add(_dumpFolderStatusLabel);
        _statusStrip.Items.Add(new ToolStripStatusLabel { Text = "|" });
        _statusStrip.Items.Add(_connectionStatusLabel);
        _statusStrip.Items.Add(new ToolStripStatusLabel { Text = "|" });
        _statusStrip.Items.Add(_modeStatusLabel);
        _statusStrip.Items.Add(new ToolStripStatusLabel { Text = "|" });
        _statusStrip.Items.Add(_openOcdStatusLabel);
    }

    private void OnLoad(object? sender, EventArgs args)
    {
        try
        {
            _paths = OpenOcdPaths.Find();
            _runner = new OpenOcdRunner(_paths);
            _openOcdStatus = "OK";
            UpdateStatusStrip("Ready");
            AddWorkflowMessage("Ready", "Found bundled OpenOCD. Choose an action and press Start.");
        }
        catch (Exception ex)
        {
            _openOcdStatus = "missing";
            UpdateStatusStrip("Blocked");
            AddWorkflowMessage("OpenOCD not found", ex.Message);
            SetSettingsEnabled(false);
        }

        OnActionChanged();
        OnConnectionModeChanged();
    }

    private void OnConnectionModeChanged()
    {
        _selectedConnectionMode = _connectionModeComboBox.SelectedIndex switch
        {
            2 => ConnectionMode.GenuineC45,
            1 => ConnectionMode.CloneC45,
            _ => ConnectionMode.DefaultSwd,
        };

        UpdateStatusStrip(_isRunning ? "Running" : "Ready");
        UpdateCloneC45CountdownVisibility();
        DismissCompletedWorkflow();
    }

    private void OnActionChanged()
    {
        if (_actionComboBox.SelectedItem is ActionItem item)
        {
            _selectedAction = item.Action;
        }

        UpdateActionControls();
        DismissCompletedWorkflow();
    }

    private void UpdateActionControls()
    {
        _browseFirmwareButton.Enabled = !_isRunning && _selectedAction == GuiAction.Flash;
        _browseDumpFolderButton.Enabled = !_isRunning && _selectedAction == GuiAction.Dump;
        _firmwarePathTextBox.Enabled = _selectedAction == GuiAction.Flash;
        _dumpFolderTextBox.Enabled = _selectedAction == GuiAction.Dump;
        UpdateCloneC45CountdownVisibility();
        _startButton.Text = _selectedAction switch
        {
            GuiAction.CheckConnection => "Check connection",
            GuiAction.Dump => "Start dump",
            GuiAction.Flash => "Start flash",
            _ => "Start",
        };
    }

    private void OnOpenFirmwareMenuClick(object? sender, EventArgs args)
    {
        BrowseFirmware();
    }

    private void OnSetDumpFolderMenuClick(object? sender, EventArgs args)
    {
        BrowseDumpFolder();
    }

    private void OnAboutMenuClick(object? sender, EventArgs args)
    {
        MessageBox.Show(
            this,
            "x3utils Windows GUI\nVersion 0.3.0\n\nExperimental prototype.\nUses bundled OpenOCD.",
            "About",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void OnBrowseFirmwareClick(object? sender, EventArgs args)
    {
        BrowseFirmware();
    }

    private void OnBrowseDumpFolderClick(object? sender, EventArgs args)
    {
        BrowseDumpFolder();
    }

    private async void OnStartClick(object? sender, EventArgs args)
    {
        await RunSelectedActionAsync();
    }

    private async void OnRetryClick(object? sender, EventArgs args)
    {
        if (_lastFailedAction is null)
        {
            return;
        }

        _selectedAction = _lastFailedAction.Value;
        SelectAction(_selectedAction);
        await RunSelectedActionAsync();
    }

    private void OnCancelClick(object? sender, EventArgs args)
    {
        _workflowTitleLabel.Text = "Cancel";
        _workflowInstructionLabel.Text = "Cancellation is not available after OpenOCD has started. Wait for the command to finish, then retry if needed.";

        if (_isRunning && _selectedConnectionMode == ConnectionMode.CloneC45)
        {
            _continueButton.Visible = true;
        }
    }

    private void OnDismissClick(object? sender, EventArgs args)
    {
        DismissCompletedWorkflow();
    }

    private void OnContinueClick(object? sender, EventArgs args)
    {
        if (_runner is null)
        {
            return;
        }

        if (_runner.SendContinue())
        {
            if (_selectedConnectionMode == ConnectionMode.CloneC45)
            {
                _cloneC45Phase = _cloneC45Phase == CloneC45Phase.WaitingForRelease
                    ? CloneC45Phase.AfterRelease
                    : CloneC45Phase.HoldingCountdown;
            }

            _continueButton.Enabled = false;
            _workflowInstructionLabel.Text = "Continue sent. Keep the ST-LINK and SWD wires steady.";
            return;
        }

        AddWorkflowMessage("Continue unavailable", "OpenOCD is not waiting for input now.");
    }

    private async Task RunSelectedActionAsync()
    {
        if (_runner is null)
        {
            AddWorkflowMessage("Blocked", "OpenOCD is not available.");
            return;
        }

        switch (_selectedAction)
        {
            case GuiAction.CheckConnection:
                await RunCheckConnectionAsync();
                break;
            case GuiAction.Dump:
                await RunDumpAsync();
                break;
            case GuiAction.Flash:
                await RunFlashAsync();
                break;
        }
    }

    private async Task RunCheckConnectionAsync()
    {
        await RunOpenOcdAsync(
            GuiAction.CheckConnection,
            "Checking connection",
            GetModeInstruction("Keep the ST-LINK and SWD wires steady until the check finishes."),
            GetStages("Connect to target", "Probe flash"),
            runner => runner.CheckAdapterAsync(_selectedConnectionMode, GetCloneC45CountdownSeconds(), AppendConsoleOutput, CancellationToken.None),
            result =>
            {
                _lastConnectionStatus = result.IsSuccess ? "PASS" : "FAIL";
                return result.IsSuccess
                    ? WorkflowResult.Success("Connection check completed.")
                    : WorkflowResult.Failure(GetOpenOcdFailureMessage($"Connection check failed. Exit code: {result.ExitCode}. Check the console log for details."));
            });
    }

    private async Task RunDumpAsync()
    {
        var dumpFolder = _dumpFolderTextBox.Text;
        if (string.IsNullOrWhiteSpace(dumpFolder))
        {
            AddWorkflowMessage("Dump folder required", "Choose a dump folder before starting a dump.");
            return;
        }

        Directory.CreateDirectory(dumpFolder);
        var dumpPath = Path.Combine(dumpFolder, "x3utils_dump_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss") + ".bin");

        await RunOpenOcdAsync(
            GuiAction.Dump,
            "Dumping firmware",
            GetModeInstruction("Keep the ST-LINK and SWD wires steady until the dump completes."),
            GetStages("Connect to target", "Probe flash", "Read 128 KB", "Validate dump"),
            runner => runner.DumpAsync(_selectedConnectionMode, GetCloneC45CountdownSeconds(), dumpPath, AppendConsoleOutput, CancellationToken.None),
            result =>
            {
                if (!result.IsSuccess)
                {
                    return WorkflowResult.Failure(GetOpenOcdFailureMessage($"Dump failed. Exit code: {result.ExitCode}. Check the console log for details."));
                }

                var validation = FirmwareValidator.Validate(dumpPath);
                if (!validation.IsValid)
                {
                    return WorkflowResult.Failure("Dump was saved but failed validation. Do not trust this file. Retry the dump. " + validation.Message);
                }

                return WorkflowResult.Success("Dump completed and verified. Saved to: " + dumpPath);
            });
    }

    private async Task RunFlashAsync()
    {
        var firmwarePath = _firmwarePathTextBox.Text;
        var validation = FirmwareValidator.Validate(firmwarePath);
        if (!validation.IsValid)
        {
            AddWorkflowMessage("Firmware invalid", validation.Message);
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
            AddWorkflowMessage("Flash cancelled", "No changes were made.");
            return;
        }

        await RunOpenOcdAsync(
            GuiAction.Flash,
            "Flashing firmware",
            GetModeInstruction("Keep the ST-LINK and SWD wires steady until verify completes."),
            GetStages("Validate firmware", "Connect to target", "Erase flash", "Write firmware", "Verify firmware"),
            runner => runner.FlashAsync(_selectedConnectionMode, GetCloneC45CountdownSeconds(), firmwarePath, AppendConsoleOutput, CancellationToken.None),
            result => result.IsSuccess
                ? WorkflowResult.Success("Flashing completed and verified successfully.")
                : WorkflowResult.Failure(GetOpenOcdFailureMessage($"OpenOCD failed. Nothing was verified. Exit code: {result.ExitCode}. Check the console log for details.")));
    }

    private async Task RunOpenOcdAsync(
        GuiAction action,
        string title,
        string instruction,
        IReadOnlyList<string> stages,
        Func<OpenOcdRunner, Task<OpenOcdResult>> operation,
        Func<OpenOcdResult, WorkflowResult> resultMessage)
    {
        if (_runner is null)
        {
            return;
        }

        AppendConsoleHeader(title);
        SetRunningState(title, instruction, stages);

        try
        {
            var result = await operation(_runner);
            _lastLog = result.Log;
            var workflowResult = resultMessage(result);
            CompleteWorkflow(title, stages, workflowResult.IsSuccess, workflowResult.Message);
            _lastFailedAction = workflowResult.IsSuccess ? null : action;
        }
        catch (Exception ex)
        {
            AppendConsoleOutput(ex + Environment.NewLine);
            _lastLog = _consoleForm.ConsoleText;
            CompleteWorkflow(title, stages, success: false, "Operation failed: " + ex.Message);
            _lastFailedAction = action;
        }
        finally
        {
            _isRunning = false;
            SetSettingsEnabled(true);
            UpdateActionControls();
            UpdateStatusStrip("Ready");
        }
    }

    private void SetRunningState(string title, string instruction, IReadOnlyList<string> stages)
    {
        _isRunning = true;
        _hasCompletedWorkflow = false;
        _lastOpenOcdDiagnosis = null;
        _lastOpenOcdDiagnosisPriority = 0;
        _cloneC45Phase = _selectedConnectionMode == ConnectionMode.CloneC45
            ? CloneC45Phase.WaitingForHold
            : CloneC45Phase.None;
        _lastFailedAction = null;
        SetSettingsEnabled(false);
        UpdateStatusStrip("Running");

        _workflowTitleLabel.Text = title;
        _workflowInstructionLabel.Text = instruction;
        SetWorkflowVisualState(WorkflowVisualState.Neutral);
        _workflowStagesLabel.Text = FormatStages(stages, activeIndex: 0, failed: false);
        _workflowStagesLabel.Visible = false;
        _workflowProgressBar.Visible = true;
        _workflowProgressBar.MarqueeAnimationSpeed = 30;
        _retryButton.Visible = false;
        _cancelButton.Visible = true;
        _dismissButton.Visible = false;
        _continueButton.Visible = _selectedConnectionMode == ConnectionMode.CloneC45;
        _continueButton.Enabled = _selectedConnectionMode == ConnectionMode.CloneC45;
        if (_selectedConnectionMode == ConnectionMode.CloneC45)
        {
            ShowContinuePrompt(
                "Hold C45/nRST to GND",
                "Hold the C45/nRST contact to GND. Keep it steady, then click Continue.",
                WorkflowVisualState.Hold);
        }

        _workflowGroupBox.Focus();
    }

    private void CompleteWorkflow(string title, IReadOnlyList<string> stages, bool success, string message)
    {
        _workflowTitleLabel.Text = success ? title + " complete" : title + " failed";
        _workflowInstructionLabel.Text = message;
        SetWorkflowVisualState(success ? WorkflowVisualState.Success : WorkflowVisualState.Failure);
        _hasCompletedWorkflow = true;
        _workflowStagesLabel.Text = FormatStages(stages, activeIndex: success ? stages.Count : Math.Max(0, stages.Count - 1), failed: !success);
        _workflowStagesLabel.Visible = false;
        _workflowProgressBar.MarqueeAnimationSpeed = 0;
        _workflowProgressBar.Visible = false;
        _retryButton.Visible = !success;
        _cancelButton.Visible = false;
        _continueButton.Visible = false;
        _continueButton.Enabled = false;
        _dismissButton.Visible = true;

        if (success)
        {
            _dismissButton.Focus();
        }
        else
        {
            _retryButton.Focus();
        }
    }

    private void SetIdleWorkflow()
    {
        _workflowTitleLabel.Text = "Ready";
        _workflowInstructionLabel.Text = "Choose an action and press Start.";
        SetWorkflowVisualState(WorkflowVisualState.Neutral);
        _workflowStagesLabel.Text = string.Empty;
        _workflowStagesLabel.Visible = false;
        _workflowProgressBar.Visible = false;
        _retryButton.Visible = false;
        _cancelButton.Visible = false;
        _continueButton.Visible = false;
        _continueButton.Enabled = false;
        _dismissButton.Visible = false;
        _hasCompletedWorkflow = false;
    }

    private void AddWorkflowMessage(string title, string instruction)
    {
        _workflowTitleLabel.Text = title;
        _workflowInstructionLabel.Text = instruction;
        SetWorkflowVisualState(WorkflowVisualState.Neutral);
        _workflowStagesLabel.Text = string.Empty;
        _workflowStagesLabel.Visible = false;
        _workflowProgressBar.Visible = false;
        _retryButton.Visible = false;
        _cancelButton.Visible = false;
        _continueButton.Visible = false;
        _continueButton.Enabled = false;
        _dismissButton.Visible = false;
        _hasCompletedWorkflow = false;
    }

    private void AppendConsoleOutput(string text)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => AppendConsoleOutput(text));
            return;
        }

        _consoleForm.Append(text);
        _lastLog = _consoleForm.ConsoleText;

        var lower = text.ToLowerInvariant();
        if (lower.Contains("target halted"))
        {
            _lastConnectionStatus = "PASS";
            UpdateStatusStrip(_isRunning ? "Running" : "Ready");
        }
        else if (lower.Contains("error: open failed") || lower.Contains("unable to connect"))
        {
            _lastConnectionStatus = "FAIL";
            UpdateStatusStrip(_isRunning ? "Running" : "Ready");
        }

        HandleCloneC45Prompt(text);
        HandleOpenOcdDiagnostics(text);
    }

    private void ShowConsoleWindow()
    {
        if (_consoleForm.Visible)
        {
            _consoleForm.Activate();
            return;
        }

        _consoleForm.Show();
    }

    private void ClearConsole()
    {
        _consoleForm.ClearConsole();
        _lastLog = string.Empty;
    }

    private void AppendConsoleHeader(string title)
    {
        var header = string.Join(
            Environment.NewLine,
            string.Empty,
            "============================================================",
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " - " + title,
            "============================================================",
            string.Empty);

        AppendConsoleOutput(header);
    }

    private void BrowseFirmware()
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
            AddWorkflowMessage("Firmware invalid", result.Message);
            UpdateStatusStrip("Ready");
            return;
        }

        _firmwarePathTextBox.Text = dialog.FileName;
        AddWorkflowMessage("Firmware loaded", Path.GetFileName(dialog.FileName));
        UpdateStatusStrip("Ready");
        OnActionChanged();
    }

    private void BrowseDumpFolder()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "Select dump folder",
            SelectedPath = Directory.Exists(_dumpFolderTextBox.Text) ? _dumpFolderTextBox.Text : GetDefaultDumpFolder(),
            UseDescriptionForTitle = true,
        };

        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }

        _dumpFolderTextBox.Text = dialog.SelectedPath;
        AddWorkflowMessage("Dump folder set", dialog.SelectedPath);
        UpdateStatusStrip("Ready");
    }

    private void DismissCompletedWorkflow()
    {
        if (_isRunning || !_hasCompletedWorkflow)
        {
            return;
        }

        SetIdleWorkflow();
    }

    private void SetSettingsEnabled(bool enabled)
    {
        _actionComboBox.Enabled = enabled && _runner is not null;
        _connectionModeComboBox.Enabled = enabled && _runner is not null;
        _browseFirmwareButton.Enabled = enabled && _runner is not null && _selectedAction == GuiAction.Flash;
        _browseDumpFolderButton.Enabled = enabled && _runner is not null && _selectedAction == GuiAction.Dump;
        _cloneC45CountdownNumericUpDown.Enabled = enabled && _runner is not null && _selectedConnectionMode == ConnectionMode.CloneC45;
        _startButton.Enabled = enabled && _runner is not null;
    }

    private void UpdateStatusStrip(string state)
    {
        _stateStatusLabel.Text = state;
        _firmwareStatusLabel.Text = string.IsNullOrWhiteSpace(_firmwarePathTextBox.Text)
            ? "Firmware: none"
            : "Firmware: " + Path.GetFileName(_firmwarePathTextBox.Text);
        _dumpFolderStatusLabel.Text = "Dump folder: " + _dumpFolderTextBox.Text;
        _connectionStatusLabel.Text = "Last connection: " + _lastConnectionStatus;
        _modeStatusLabel.Text = "Mode: " + GetModeStatusText(_selectedConnectionMode);
        _openOcdStatusLabel.Text = "OpenOCD: " + _openOcdStatus;
    }

    private string GetModeInstruction(string baseInstruction)
    {
        if (_selectedConnectionMode == ConnectionMode.CloneC45)
        {
            return baseInstruction + Environment.NewLine + "Follow the C45 hold/release prompts below.";
        }

        return baseInstruction;
    }

    private static string GetModeStatusText(ConnectionMode connectionMode)
    {
        return connectionMode switch
        {
            ConnectionMode.CloneC45 => "C45 clone",
            ConnectionMode.GenuineC45 => "C45 genuine",
            _ => "Default SWD",
        };
    }

    private IReadOnlyList<string> GetStages(params string[] regularStages)
    {
        if (_selectedConnectionMode != ConnectionMode.CloneC45)
        {
            return regularStages;
        }

        var stages = new List<string>
        {
            "Hold C45/nRST to GND",
            "Connect under reset",
            "Release C45/nRST",
        };
        stages.AddRange(regularStages);
        return stages;
    }

    private void HandleCloneC45Prompt(string text)
    {
        if (!_isRunning || _selectedConnectionMode != ConnectionMode.CloneC45)
        {
            return;
        }

        var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        foreach (var line in lines)
        {
            var lower = line.ToLowerInvariant();
            if (lower.Contains("hold a wire between") || lower.Contains("keep it grounded"))
            {
                _cloneC45Phase = CloneC45Phase.WaitingForHold;
                ShowContinuePrompt(
                    "Hold C45/nRST to GND",
                    "Hold the C45/nRST contact to GND. Keep it steady, then click Continue.",
                    WorkflowVisualState.Hold);
            }
            else if (lower.Contains("remove the wire from gnd") || lower.Contains("step 2/2 - release nrst"))
            {
                _cloneC45Phase = CloneC45Phase.WaitingForRelease;
                ShowContinuePrompt(
                    "RELEASE C45/nRST NOW",
                    "Release the C45/nRST contact now, then click Continue.",
                    WorkflowVisualState.Release);
            }
            else if (lower.Contains("connected.  ready"))
            {
                _cloneC45Phase = CloneC45Phase.AfterRelease;
                _continueButton.Enabled = false;
                _workflowInstructionLabel.Text = "Connected. Keep the ST-LINK and SWD wires steady until the operation finishes.";
            }
            else if (lower.Contains("connecting in "))
            {
                _cloneC45Phase = CloneC45Phase.HoldingCountdown;
                _continueButton.Enabled = false;
                _workflowTitleLabel.Text = "Connecting under reset";
                _workflowInstructionLabel.Text = "Keep holding C45/nRST to GND. Waiting " + GetCloneC45CountdownSeconds() + " seconds...";
                SetWorkflowVisualState(WorkflowVisualState.Hold);
            }
            else if (TryParseC45CountdownLine(line, out var seconds))
            {
                _cloneC45Phase = CloneC45Phase.HoldingCountdown;
                _continueButton.Enabled = false;
                _workflowTitleLabel.Text = "Connecting under reset";
                _workflowInstructionLabel.Text = seconds > 0
                    ? "Keep holding C45/nRST to GND. Connecting in " + seconds + "..."
                    : "Keep holding C45/nRST to GND. Connecting now...";
                SetWorkflowVisualState(WorkflowVisualState.Hold);
            }
        }
    }

    private void ShowContinuePrompt(string title, string instruction, WorkflowVisualState visualState)
    {
        _workflowTitleLabel.Text = title;
        _workflowInstructionLabel.Text = instruction;
        SetWorkflowVisualState(visualState);
        _continueButton.Visible = true;
        _continueButton.Enabled = true;
        _continueButton.Focus();
    }

    private void SetWorkflowVisualState(WorkflowVisualState visualState)
    {
        var backColor = visualState switch
        {
            WorkflowVisualState.Hold => WorkflowHoldBackColor,
            WorkflowVisualState.Release => WorkflowReleaseBackColor,
            WorkflowVisualState.Success => WorkflowSuccessBackColor,
            WorkflowVisualState.Failure => WorkflowFailureBackColor,
            _ => WorkflowNeutralBackColor,
        };

        _workflowGroupBox.BackColor = backColor;
        _workflowTitleLabel.BackColor = backColor;
        _workflowInstructionLabel.BackColor = backColor;
        _workflowStagesLabel.BackColor = backColor;

        _workflowTitleLabel.ForeColor = visualState switch
        {
            WorkflowVisualState.Release => Color.FromArgb(120, 70, 0),
            WorkflowVisualState.Failure => Color.FromArgb(140, 0, 0),
            WorkflowVisualState.Success => Color.FromArgb(0, 100, 30),
            WorkflowVisualState.Hold => Color.FromArgb(0, 80, 120),
            _ => SystemColors.ControlText,
        };
    }

    private void HandleOpenOcdDiagnostics(string text)
    {
        if (!_isRunning)
        {
            return;
        }

        var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var line in lines)
        {
            var cleanLine = line.Trim();
            if (cleanLine.Length == 0)
            {
                continue;
            }

            var diagnosis = ClassifyOpenOcdLine(cleanLine);
            if (diagnosis is null)
            {
                continue;
            }

            RememberOpenOcdDiagnosis(diagnosis.Value);
            _workflowInstructionLabel.Text = _lastOpenOcdDiagnosis ?? cleanLine;
        }
    }

    private OpenOcdDiagnosis? ClassifyOpenOcdLine(string line)
    {
        var lower = line.ToLowerInvariant();

        if (lower.Contains("no device found")
            || lower.Contains("st-link not found")
            || lower.Contains("libusb_open"))
        {
            return new OpenOcdDiagnosis(
                "ST-LINK was not found. Plug in the ST-LINK USB adapter and retry.",
                Priority: 100);
        }

        if (lower.Contains("error: open failed"))
        {
            if (_selectedConnectionMode == ConnectionMode.CloneC45
                && (_cloneC45Phase == CloneC45Phase.WaitingForHold || _cloneC45Phase == CloneC45Phase.HoldingCountdown))
            {
                return new OpenOcdDiagnosis(
                    "Target did not answer during manual connect. Check C45/nRST grounding, SWD wires, and target power. Keep C45/nRST grounded before pressing Retry.",
                    Priority: 85);
            }

            if (_selectedConnectionMode == ConnectionMode.CloneC45)
            {
                return new OpenOcdDiagnosis(
                    "OpenOCD could not connect. Check ST-LINK USB, C45/nRST contact, SWD wires, and target power.",
                    Priority: 80);
            }

            return new OpenOcdDiagnosis(
                "ST-LINK was not found. Plug in the ST-LINK USB adapter and retry.",
                Priority: 100);
        }

        if (lower.Contains("demcr write failed"))
        {
            return new OpenOcdDiagnosis(
                "C45/nRST was probably not held to GND. Hold it before pressing Retry and keep holding through the countdown.",
                Priority: 90);
        }

        if (lower.Contains("unable to connect to the target"))
        {
            if (_selectedConnectionMode == ConnectionMode.CloneC45
                && (_cloneC45Phase == CloneC45Phase.WaitingForHold || _cloneC45Phase == CloneC45Phase.HoldingCountdown))
            {
                return new OpenOcdDiagnosis(
                    "Target did not answer while C45/nRST should be grounded. Check SWD wires and target power. Keep C45/nRST grounded before pressing Retry.",
                    Priority: 85);
            }

            if (_selectedConnectionMode == ConnectionMode.CloneC45
                && (_cloneC45Phase == CloneC45Phase.WaitingForRelease || _cloneC45Phase == CloneC45Phase.AfterRelease))
            {
                return new OpenOcdDiagnosis(
                    "Target did not answer after release. Check release timing, SWD wires, and target power, then retry.",
                    Priority: 85);
            }

            return new OpenOcdDiagnosis(
                "ST-LINK is present, but the target did not answer. Check SWD wires and target power, then retry.",
                Priority: 80);
        }

        if (lower.Contains("could not re-examine target"))
        {
            return new OpenOcdDiagnosis(
                "C45/nRST may not have been released when prompted. Release it when prompted, then press Retry.",
                Priority: 90);
        }

        if (lower.Contains("check nrst was released"))
        {
            return new OpenOcdDiagnosis(
                "C45/nRST was probably still grounded. Release it when prompted, then press Retry.",
                Priority: 95);
        }

        if (lower.Contains("timed out while waiting for target halted")
            && _selectedConnectionMode == ConnectionMode.CloneC45
            && (_cloneC45Phase == CloneC45Phase.WaitingForRelease || _cloneC45Phase == CloneC45Phase.AfterRelease))
        {
            return new OpenOcdDiagnosis(
                "Target did not halt after release. Make sure C45/nRST is released when prompted and the chip is powered.",
                Priority: 90);
        }

        if (lower.Contains("could not halt target"))
        {
            return new OpenOcdDiagnosis(
                "Target connected but did not halt. Retry, and check SWD wires and target power.",
                Priority: 75);
        }

        if (lower.Contains("verify failed"))
        {
            return new OpenOcdDiagnosis(
                "Verify failed: firmware does not match after write.",
                Priority: 90);
        }

        if (lower.Contains("write failed"))
        {
            return new OpenOcdDiagnosis(
                "Write failed: target connection was lost during flashing. Check SWD wires and retry.",
                Priority: 90);
        }

        if (lower.Contains("erase failed"))
        {
            return new OpenOcdDiagnosis(
                "Erase failed: target did not accept the erase command. Check connection and retry.",
                Priority: 90);
        }

        if (lower.Contains("target voltage") || lower.Contains("target not examined"))
        {
            return new OpenOcdDiagnosis(
                "ST-LINK is present, but the target did not answer. Check SWD wires and target power, then retry.",
                Priority: 70);
        }

        if (lower.Contains("adapter init failed") || lower.Contains("[fail]") || lower.Contains("error:"))
        {
            return new OpenOcdDiagnosis(
                line,
                Priority: 40);
        }

        return null;
    }

    private void RememberOpenOcdDiagnosis(OpenOcdDiagnosis diagnosis)
    {
        if (diagnosis.Priority < _lastOpenOcdDiagnosisPriority)
        {
            return;
        }

        _lastOpenOcdDiagnosis = diagnosis.Message;
        _lastOpenOcdDiagnosisPriority = diagnosis.Priority;
    }

    private string GetOpenOcdFailureMessage(string fallback)
    {
        return string.IsNullOrWhiteSpace(_lastOpenOcdDiagnosis)
            ? fallback
            : _lastOpenOcdDiagnosis;
    }

    private void UpdateCloneC45CountdownVisibility()
    {
        var visible = _selectedConnectionMode == ConnectionMode.CloneC45;
        _cloneC45CountdownLabel.Visible = visible;
        _cloneC45CountdownNumericUpDown.Visible = visible;
        _cloneC45CountdownNumericUpDown.Enabled = visible && !_isRunning && _runner is not null;
    }

    private int GetCloneC45CountdownSeconds()
    {
        return (int)_cloneC45CountdownNumericUpDown.Value;
    }

    private static bool TryParseC45CountdownLine(string line, out int seconds)
    {
        seconds = 0;
        var trimmed = line.Trim();
        if (trimmed.Length < 1)
        {
            return false;
        }

        var numberLength = 0;
        while (numberLength < trimmed.Length && char.IsDigit(trimmed[numberLength]))
        {
            numberLength++;
        }

        if (numberLength == 0)
        {
            return false;
        }

        if (numberLength < trimmed.Length && trimmed[numberLength] != ' ' && trimmed[numberLength] != '.')
        {
            return false;
        }

        return int.TryParse(trimmed[..numberLength], out seconds);
    }

    private static string GetDefaultDumpFolder()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "x3utils",
            "dumps");
    }

    private static string FormatStages(IReadOnlyList<string> stages, int activeIndex, bool failed)
    {
        var lines = new List<string>();
        for (var i = 0; i < stages.Count; i++)
        {
            string marker;
            if (failed && i == activeIndex)
            {
                marker = "[FAIL]";
            }
            else if (i < activeIndex)
            {
                marker = "[OK]  ";
            }
            else if (i == activeIndex)
            {
                marker = "[..]  ";
            }
            else
            {
                marker = "[ ]  ";
            }

            lines.Add(marker + stages[i]);
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static void AddRow(TableLayoutPanel grid, int row, string label, Control content, Control button)
    {
        var labelControl = new Label
        {
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Text = label,
            Margin = new Padding(0, 4, 8, 4),
        };

        content.Margin = new Padding(0, 4, 8, 4);
        button.Margin = new Padding(0, 4, 0, 4);

        grid.Controls.Add(labelControl, 0, row);
        grid.Controls.Add(content, 1, row);
        grid.Controls.Add(button, 2, row);
    }

    private void SelectAction(GuiAction action)
    {
        for (var i = 0; i < _actionComboBox.Items.Count; i++)
        {
            if (_actionComboBox.Items[i] is ActionItem item && item.Action == action)
            {
                _actionComboBox.SelectedIndex = i;
                return;
            }
        }
    }
}

internal enum GuiAction
{
    CheckConnection,
    Dump,
    Flash,
}

internal enum ConnectionMode
{
    DefaultSwd,
    CloneC45,
    GenuineC45,
}

internal enum WorkflowVisualState
{
    Neutral,
    Hold,
    Release,
    Success,
    Failure,
}

internal enum CloneC45Phase
{
    None,
    WaitingForHold,
    HoldingCountdown,
    WaitingForRelease,
    AfterRelease,
}

internal readonly record struct OpenOcdDiagnosis(string Message, int Priority);

internal readonly record struct WorkflowResult(bool IsSuccess, string Message)
{
    public static WorkflowResult Success(string message)
    {
        return new WorkflowResult(true, message);
    }

    public static WorkflowResult Failure(string message)
    {
        return new WorkflowResult(false, message);
    }
}

internal sealed record ActionItem(GuiAction Action, string Text)
{
    public override string ToString()
    {
        return Text;
    }
}
