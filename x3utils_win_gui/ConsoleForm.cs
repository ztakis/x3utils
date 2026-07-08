using System.Drawing;

namespace X3Utils.WinGui;

internal sealed class ConsoleForm : Form
{
    private readonly TextBox _consoleTextBox = new();
    private readonly Button _copyButton = new();
    private readonly Button _clearButton = new();
    private readonly Button _closeButton = new();

    public ConsoleForm()
    {
        Text = "OpenOCD Console";
        StartPosition = FormStartPosition.CenterParent;
        MinimumSize = new Size(720, 360);
        Size = new Size(900, 520);

        BuildLayout();
    }

    public string ConsoleText => _consoleTextBox.Text;

    public void Append(string text)
    {
        if (IsDisposed)
        {
            return;
        }

        if (InvokeRequired)
        {
            BeginInvoke(() => Append(text));
            return;
        }

        _consoleTextBox.AppendText(text);
    }

    public void ClearConsole()
    {
        _consoleTextBox.Clear();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        base.OnFormClosing(e);
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(8),
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        _consoleTextBox.Dock = DockStyle.Fill;
        _consoleTextBox.Multiline = true;
        _consoleTextBox.ReadOnly = true;
        _consoleTextBox.ScrollBars = ScrollBars.Vertical;
        _consoleTextBox.WordWrap = true;
        _consoleTextBox.Font = new Font(FontFamily.GenericMonospace, 9);
        root.Controls.Add(_consoleTextBox, 0, 0);

        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(0, 8, 0, 0),
        };

        _closeButton.AutoSize = true;
        _closeButton.Text = "Close";
        _closeButton.Click += (_, _) => Hide();

        _clearButton.AutoSize = true;
        _clearButton.Text = "Clear";
        _clearButton.Click += (_, _) => ClearConsole();

        _copyButton.AutoSize = true;
        _copyButton.Text = "Copy";
        _copyButton.Click += (_, _) =>
        {
            if (!string.IsNullOrWhiteSpace(_consoleTextBox.Text))
            {
                Clipboard.SetText(_consoleTextBox.Text);
            }
        };

        buttonPanel.Controls.Add(_closeButton);
        buttonPanel.Controls.Add(_clearButton);
        buttonPanel.Controls.Add(_copyButton);
        root.Controls.Add(buttonPanel, 0, 1);

        Controls.Add(root);
    }
}
