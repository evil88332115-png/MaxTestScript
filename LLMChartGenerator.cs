using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Windows.Forms;

public class LLMChartGenerator : Form
{
    private readonly string[] models =
    {
        "Llama 3.1 8B",
        "Llama 3.2 3B",
        "Qwen2.5 7B",
        "Gemma 2 2B",
        "Phi 3.5 3B",
        "SmolLM2"
    };

    private readonly double[] defaultOfficial = { 19.14, 43.07, 21.75, 34.97, 38.10, 64.50 };
    private readonly double[] defaultB442 = { 17.13, 35.42, 18.72, 33.12, 32.36, 60.19 };

    private TextBox[] officialBoxes;
    private TextBox[] b442Boxes;
    private TextBox titleBox;
    private TextBox officialLabelBox;
    private TextBox b442LabelBox;

    public LLMChartGenerator()
    {
        Text = "LLM Performance Chart Generator";
        Width = 780;
        Height = 430;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;

        BuildUi();
    }

    private void BuildUi()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 1,
            RowCount = 5
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        Controls.Add(root);

        titleBox = AddLabeledTextBox(root, "Chart title:", "LLM Performance (Power Mode: MAXN_SUPER)");
        officialLabelBox = AddLabeledTextBox(root, "Official label:", "Jetson Orin Nano Super (Official)");

        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 3,
            RowCount = models.Length + 1,
            CellBorderStyle = TableLayoutPanelCellBorderStyle.Single
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 31));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 31));
        root.Controls.Add(grid, 0, 2);

        AddHeader(grid, "Model", 0, 0);
        AddHeader(grid, "Official", 1, 0);
        AddHeader(grid, "B442", 2, 0);

        officialBoxes = new TextBox[models.Length];
        b442Boxes = new TextBox[models.Length];

        for (int i = 0; i < models.Length; i++)
        {
            var label = new Label
            {
                Text = models[i],
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(6, 0, 0, 0)
            };
            grid.Controls.Add(label, 0, i + 1);

            officialBoxes[i] = MakeValueBox(defaultOfficial[i]);
            b442Boxes[i] = MakeValueBox(defaultB442[i]);
            grid.Controls.Add(officialBoxes[i], 1, i + 1);
            grid.Controls.Add(b442Boxes[i], 2, i + 1);
        }

        var bottom = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight
        };
        root.Controls.Add(bottom, 0, 3);

        b442LabelBox = new TextBox
        {
            Text = "Jetson Orin Nano Super (B442)",
            Width = 250
        };
        bottom.Controls.Add(new Label { Text = "B442 label:", AutoSize = true, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(0, 8, 0, 0) });
        bottom.Controls.Add(b442LabelBox);

        var saveButton = new Button
        {
            Text = "Generate PNG",
            Width = 130,
            Height = 28
        };
        saveButton.Click += SaveButton_Click;
        bottom.Controls.Add(saveButton);

        var resetButton = new Button
        {
            Text = "Reset Defaults",
            Width = 120,
            Height = 28
        };
        resetButton.Click += (s, e) => ResetDefaults();
        bottom.Controls.Add(resetButton);

        root.Controls.Add(new Label
        {
            Text = "Only B442 values usually need editing. Official values are editable if needed.",
            Dock = DockStyle.Fill,
            ForeColor = Color.DimGray
        }, 0, 4);
    }

    private TextBox AddLabeledTextBox(TableLayoutPanel root, string label, string value)
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 95));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        panel.Controls.Add(new Label
        {
            Text = label,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        }, 0, 0);

        var box = new TextBox { Text = value, Dock = DockStyle.Fill };
        panel.Controls.Add(box, 1, 0);
        root.Controls.Add(panel);
        return box;
    }

    private static void AddHeader(TableLayoutPanel grid, string text, int col, int row)
    {
        grid.Controls.Add(new Label
        {
            Text = text,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Arial", 9, FontStyle.Bold),
            BackColor = Color.FromArgb(240, 240, 240)
        }, col, row);
    }

    private static TextBox MakeValueBox(double value)
    {
        return new TextBox
        {
            Text = value.ToString("0.##", CultureInfo.InvariantCulture),
            Dock = DockStyle.Fill,
            TextAlign = HorizontalAlignment.Center
        };
    }

    private void ResetDefaults()
    {
        for (int i = 0; i < models.Length; i++)
        {
            officialBoxes[i].Text = defaultOfficial[i].ToString("0.##", CultureInfo.InvariantCulture);
            b442Boxes[i].Text = defaultB442[i].ToString("0.##", CultureInfo.InvariantCulture);
        }
        titleBox.Text = "LLM Performance (Power Mode: MAXN_SUPER)";
        officialLabelBox.Text = "Jetson Orin Nano Super (Official)";
        b442LabelBox.Text = "Jetson Orin Nano Super (B442)";
    }

    private void SaveButton_Click(object sender, EventArgs e)
    {
        try
        {
            double[] official = ParseValues(officialBoxes, "Official");
            double[] b442 = ParseValues(b442Boxes, "B442");

            using (var dialog = new SaveFileDialog())
            {
                dialog.Title = "Save chart PNG";
                dialog.Filter = "PNG image (*.png)|*.png";
                dialog.FileName = "10-1_llm_performance_b442_vs_official.png";
                dialog.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return;

                DrawChart(dialog.FileName, official, b442);
                MessageBox.Show(this, "PNG saved:\n" + dialog.FileName, "Done", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private double[] ParseValues(TextBox[] boxes, string columnName)
    {
        var values = new double[boxes.Length];
        for (int i = 0; i < boxes.Length; i++)
        {
            string text = boxes[i].Text.Trim();
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]))
            {
                if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out values[i]))
                    throw new Exception(columnName + " value is invalid: " + models[i]);
            }
        }
        return values;
    }

    private void DrawChart(string outputPath, double[] official, double[] b442)
    {
        int w = 1200;
        int h = 750;
        using (var bmp = new Bitmap(w, h))
        using (var g = Graphics.FromImage(bmp))
        using (var titleFont = new Font("Arial", 16))
        using (var axisFont = new Font("Arial", 12))
        using (var tickFont = new Font("Arial", 11))
        using (var legendFont = new Font("Arial", 11))
        using (var axisPen = new Pen(Color.FromArgb(35, 35, 35), 1.5f))
        using (var gridPen = new Pen(Color.FromArgb(190, 190, 190), 1))
        using (var officialBrush = new SolidBrush(Color.FromArgb(154, 205, 50)))
        using (var b442Brush = new SolidBrush(Color.FromArgb(46, 139, 87)))
        using (var textBrush = new SolidBrush(Color.Black))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            g.Clear(Color.White);
            gridPen.DashStyle = DashStyle.Dash;

            int left = 75, right = 40, top = 55, bottom = 145;
            int plotW = w - left - right;
            int plotH = h - top - bottom;
            // Fixed to match the reference report chart layout.
            double maxY = 75.0;

            using (var center = new StringFormat { Alignment = StringAlignment.Center })
                g.DrawString(titleBox.Text, titleFont, textBrush, new RectangleF(0, 12, w, 30), center);

            for (int v = 0; v <= maxY; v += 10)
            {
                float y = top + plotH - (float)(v / maxY * plotH);
                g.DrawLine(gridPen, left, y, w - right, y);
                g.DrawString(v.ToString(CultureInfo.InvariantCulture), tickFont, textBrush, left - 45, y - 9);
            }

            g.DrawRectangle(axisPen, left, top, plotW, plotH);

            var state = g.Save();
            using (var center = new StringFormat { Alignment = StringAlignment.Center })
            {
                g.TranslateTransform(22, top + plotH / 2);
                g.RotateTransform(-90);
                g.DrawString("Performance", axisFont, textBrush, new RectangleF(-100, -10, 200, 25), center);
            }
            g.Restore(state);

            int n = models.Length;
            float groupW = plotW / (float)n;
            // Match the matplotlib reference chart: grouped bars are visibly wider.
            float barW = 58;
            for (int i = 0; i < n; i++)
            {
                float cx = left + groupW * (i + 0.5f);
                float h1 = (float)(official[i] / maxY * plotH);
                float h2 = (float)(b442[i] / maxY * plotH);
                float x1 = cx - barW;
                float x2 = cx;
                float y1 = top + plotH - h1;
                float y2 = top + plotH - h2;
                g.FillRectangle(officialBrush, x1, y1, barW, h1);
                g.FillRectangle(b442Brush, x2, y2, barW, h2);

                state = g.Save();
                g.TranslateTransform(cx - 8, top + plotH + 58);
                g.RotateTransform(-25);
                g.DrawString(models[i], tickFont, textBrush, new PointF(-60, -12));
                g.Restore(state);
            }

            int legendX = 86, legendY = 56, legendW = 342, legendH = 55;
            using (var legendBrush = new SolidBrush(Color.FromArgb(250, 250, 250)))
            using (var legendPen = new Pen(Color.FromArgb(200, 200, 200), 1))
            {
                g.FillRectangle(legendBrush, legendX, legendY, legendW, legendH);
                g.DrawRectangle(legendPen, legendX, legendY, legendW, legendH);
            }
            g.FillRectangle(officialBrush, legendX + 12, legendY + 13, 30, 12);
            g.DrawString(officialLabelBox.Text, legendFont, textBrush, legendX + 50, legendY + 8);
            g.FillRectangle(b442Brush, legendX + 12, legendY + 35, 30, 12);
            g.DrawString(b442LabelBox.Text, legendFont, textBrush, legendX + 50, legendY + 30);

            Directory.CreateDirectory(Path.GetDirectoryName(outputPath));
            bmp.Save(outputPath, ImageFormat.Png);
        }
    }

    private static double Max(double[] values)
    {
        double max = double.MinValue;
        foreach (double value in values)
            if (value > max) max = value;
        return max;
    }

    [STAThread]
    public static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new LLMChartGenerator());
    }
}
