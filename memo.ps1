param(
    [Parameter(Position = 0)] [string]$Command,
    [switch]$Host_
)

# 메모 바탕화면: 맥 메모처럼 생긴 창을 바탕화면 층(Progman)의 아이콘 위에 붙여서 배경화면처럼 쓴다.
# 아이콘 층보다 위라서 클릭·글쓰기가 되고, 메모마다 자기 바로 가기 아이콘을 따로 가진다.
#   memo        켜기 (켜져 있으면 끄기)
#   memo off    끄기

$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $env:TEMP 'memo-desktop.pid'
$dataFile = Join-Path $PSScriptRoot 'notes.json'
$stopName = 'Local\memo-desktop-stop'

if (-not $Host_) {
    # 실행 중인지는 메모 창이 만든 이름 있는 신호로 판단한다 (pid 파일은 재부팅 뒤 다른 프로세스 번호일 수 있음)
    $signal = $null
    try { $signal = [Threading.EventWaitHandle]::OpenExisting($stopName) } catch { }
    if ($signal -or $Command -eq 'off') {
        if ($signal) {
            # 바로 죽이면 저장 전 글이 날아갈 수 있어서, 신호를 보내 스스로 저장하고 끝나게 한다
            [void]$signal.Set()
            $signal.Dispose()   # 열어 둔 채면 신호가 계속 남아서 바로 다시 켤 때 '이미 실행 중'으로 보인다
            $old = Get-Content $pidFile -ErrorAction SilentlyContinue
            $p = if ($old -match '^\d+$') { Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue }
            if ($p -and $p.ProcessName -eq 'powershell' -and -not $p.WaitForExit(5000)) {
                try { $p.Kill() } catch { }
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host '메모 바탕화면을 껐습니다.'
        return
    }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", '-Host_')
    Set-Content -Path $pidFile -Value $p.Id
    Write-Host '메모 바탕화면을 켰습니다. (끄기: memo off 또는 한 번 더 실행)'
    return
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class Note
{
    public string Text { get; set; }
    public List<string> Items { get; set; }   // 이 메모에 붙은 바로 가기 경로
    public Note() { Text = ""; Items = new List<string>(); }
}

public class MemoDesktop : Form
{
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int idx, int v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItemImageFactory item);

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr hbitmap); }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    const int WS_CHILD = 0x40000000, WS_POPUP = unchecked((int)0x80000000);
    const int WS_EX_LAYERED = 0x80000, WS_EX_TOOLWINDOW = 0x80;
    const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;

    static readonly Color Desk = Color.FromArgb(233, 231, 226), Paper = Color.White, Side = Color.FromArgb(246, 245, 242),
        Line = Color.FromArgb(226, 224, 219), Ink = Color.FromArgb(29, 29, 31), Gray = Color.FromArgb(138, 138, 142),
        Pick = Color.FromArgb(250, 229, 150), Hover = Color.FromArgb(244, 243, 240);
    const string FontName = "맑은 고딕";

    IntPtr parent;
    Size hostSize;
    float k = 1;             // DPI 배율 (이 프로세스는 실제 픽셀 단위로 그린다)
    Rectangle win;           // 화면 가운데 떠 있는 메모 창 영역
    int sideW, x0, w0, dividerY;
    string dataPath;
    System.Threading.EventWaitHandle stop;
    ListBox list;
    TextBox editor;
    FlowLayoutPanel icons;
    Font titleFont, subFont, tileFont;
    ToolTip tip = new ToolTip();
    Timer saveTimer, poll;
    Note current;
    bool loading;

    public static void Run(string dataPath)
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        Application.EnableVisualStyles();
        bool isNew;
        using (var stop = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, @"Local\memo-desktop-stop", out isNew))
        {
            if (!isNew) return;   // 이미 하나 떠 있으면 같은 notes.json을 서로 덮어쓰므로 띄우지 않는다
            Application.Run(new MemoDesktop(dataPath, stop));
        }
    }

    MemoDesktop(string dataPath, System.Threading.EventWaitHandle stop)
    {
        this.dataPath = dataPath;
        this.stop = stop;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Desk;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);

        FindHost();
        uint dpi = GetDpiForWindow(parent);
        if (dpi > 0) k = dpi / 96f;
        RECT rc; GetClientRect(parent, out rc);
        hostSize = new Size(rc.R - rc.L, rc.B - rc.T);
        Bounds = new Rectangle(Point.Empty, hostSize);

        // 작업 표시줄을 뺀 주 모니터 영역 가운데에 창을 띄운다
        var wa = Screen.PrimaryScreen.WorkingArea;
        var p = new POINT { X = wa.X, Y = wa.Y };
        ScreenToClient(parent, ref p);
        var area = new Rectangle(p.X, p.Y, wa.Width, wa.Height);
        win = Rectangle.Inflate(area, -(int)(area.Width * 0.05), -(int)(area.Height * 0.06));

        saveTimer = new Timer { Interval = 600 };
        saveTimer.Tick += (s, e) => Save();

        BuildControls();
        LoadNotes();
    }

    int S(float v) { return (int)Math.Round(v * k); }

    void FindHost()
    {
        IntPtr progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) throw new InvalidOperationException("바탕화면(Progman) 창을 찾을 수 없습니다.");
        // 아이콘 층(SHELLDLL_DefView)을 가진 창에 붙어야 아이콘 위에 올라간다
        if (FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) { parent = progman; return; }
        // 이전 Windows에서 다른 배경 프로그램이 아이콘 층을 WorkerW로 옮겨 둔 경우
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) found = h;
            return true;
        }, IntPtr.Zero);
        parent = found != IntPtr.Zero ? found : progman;
    }

    // ---- 화면 구성 ----

    void BuildControls()
    {
        titleFont = new Font(FontName, 11f, FontStyle.Bold);
        subFont = new Font(FontName, 9.5f);
        tileFont = new Font(FontName, 9f);
        sideW = S(300);

        var newBtn = new Label
        {
            Text = "+", Font = new Font(FontName, 16f), ForeColor = Gray, BackColor = Side, AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand,
            Bounds = new Rectangle(win.X + sideW - S(50), win.Y + S(10), S(38), S(38))
        };
        newBtn.Click += (s, e) => NewNote();
        tip.SetToolTip(newBtn, "새 메모");

        list = new ListBox
        {
            DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = Math.Min(255, S(68)), BorderStyle = BorderStyle.None,
            BackColor = Side, IntegralHeight = false,
            Bounds = new Rectangle(win.X + S(12), win.Y + S(56), sideW - S(24), win.Height - S(68))
        };
        list.DrawItem += DrawNoteItem;
        list.SelectedIndexChanged += (s, e) => ShowNote();
        list.MouseDown += (s, e) =>
        {
            int i = list.IndexFromPoint(e.Location);
            if (e.Button == MouseButtons.Right && i >= 0) list.SelectedIndex = i;
        };
        var listMenu = new ContextMenuStrip();
        listMenu.Items.Add("메모 삭제", null, (s, e) => DeleteNote());
        list.ContextMenuStrip = listMenu;

        x0 = win.X + sideW + S(56);
        w0 = win.Right - S(56) - x0;
        int iconsH = S(150);
        dividerY = win.Bottom - iconsH - S(56);

        editor = new TextBox
        {
            Multiline = true, BorderStyle = BorderStyle.None, BackColor = Paper, ForeColor = Ink,
            Font = new Font(FontName, 14f), AcceptsTab = true, MaxLength = 0,   // 기본값은 32767자 제한
            Bounds = new Rectangle(x0, win.Y + S(48), w0, dividerY - S(16) - (win.Y + S(48)))
        };
        // 여러 줄 TextBox는 Ctrl+A를 기본으로 지원하지 않는다
        editor.KeyDown += (s, e) => { if (e.Control && e.KeyCode == Keys.A) { editor.SelectAll(); e.SuppressKeyPress = true; } };
        editor.TextChanged += (s, e) =>
        {
            if (loading || current == null) return;
            current.Text = editor.Text;
            if (list.SelectedIndex >= 0) list.Invalidate(list.GetItemRectangle(list.SelectedIndex));
            ScheduleSave();
        };

        var header = new Label
        {
            Text = "바로 가기  ·  파일, 폴더, 프로그램을 여기로 끌어다 놓으세요", Font = subFont, ForeColor = Gray,
            BackColor = Paper, AutoSize = false,
            Bounds = new Rectangle(x0, dividerY + S(12), w0, S(28))
        };
        icons = new FlowLayoutPanel
        {
            BackColor = Paper, AutoScroll = true,
            Bounds = new Rectangle(x0 - S(4), win.Bottom - iconsH - S(12), w0 + S(8), iconsH)
        };
        foreach (Control c in new Control[] { this, header, icons }) AcceptDrops(c);

        Controls.AddRange(new Control[] { newBtn, list, editor, header, icons });
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Desk);
        int r = S(14);
        using (var shadow = RoundRect(new Rectangle(win.X, win.Y + S(6), win.Width, win.Height), r))
        using (var b = new SolidBrush(Color.FromArgb(22, 0, 0, 0)))
            g.FillPath(b, shadow);
        using (var path = RoundRect(win, r))
        using (var paper = new SolidBrush(Paper))
        using (var side = new SolidBrush(Side))
        using (var pen = new Pen(Line, Math.Max(1, k)))
        {
            g.FillPath(paper, path);
            g.SetClip(path);
            g.FillRectangle(side, win.X, win.Y, sideW, win.Height);
            g.ResetClip();
            g.DrawLine(pen, win.X + sideW, win.Y, win.X + sideW, win.Bottom);
            g.DrawLine(pen, x0, dividerY, x0 + w0, dividerY);
            g.DrawPath(pen, path);
        }
        // 맥 창 왼쪽 위의 빨강·노랑·초록 버튼 (장식)
        var dots = new[] { Color.FromArgb(255, 95, 87), Color.FromArgb(254, 188, 46), Color.FromArgb(40, 200, 64) };
        for (int i = 0; i < 3; i++)
            using (var b = new SolidBrush(dots[i]))
                g.FillEllipse(b, win.X + S(20) + i * S(20), win.Y + S(20), S(12), S(12));
    }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        int d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    static string[] Lines(string text)
    {
        return text.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
    }

    void DrawNoteItem(object sender, DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var b = new SolidBrush(Side)) g.FillRectangle(b, e.Bounds);
        var r = Rectangle.Inflate(e.Bounds, 0, -S(3));
        if ((e.State & DrawItemState.Selected) != 0)
            using (var b = new SolidBrush(Pick))
            using (var path = RoundRect(r, S(10)))
                g.FillPath(b, path);

        // 맥 메모처럼 첫 줄이 제목, 둘째 줄이 미리보기
        var lines = Lines(((Note)list.Items[e.Index]).Text);
        string title = lines.Length > 0 ? lines[0] : "새로운 메모";
        string sub = lines.Length > 1 ? lines[1] : "추가 텍스트 없음";
        var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        TextRenderer.DrawText(g, title, titleFont, new Rectangle(r.X + S(14), r.Y + S(8), r.Width - S(28), S(28)), Ink, flags);
        TextRenderer.DrawText(g, sub, subFont, new Rectangle(r.X + S(14), r.Y + S(36), r.Width - S(28), S(24)), Gray, flags);
    }

    // ---- 메모 ----

    void ShowNote()
    {
        current = list.SelectedIndex >= 0 ? (Note)list.Items[list.SelectedIndex] : null;
        loading = true;
        editor.Text = current == null ? "" : current.Text;
        editor.Enabled = current != null;
        loading = false;
        RebuildIcons();
    }

    void NewNote()
    {
        list.Items.Insert(0, new Note());
        list.SelectedIndex = 0;
        editor.Focus();
        ScheduleSave();
    }

    void DeleteNote()
    {
        int i = list.SelectedIndex;
        if (i < 0) return;
        var lines = Lines(((Note)list.Items[i]).Text);
        string title = lines.Length > 0 ? lines[0] : "새로운 메모";
        if (MessageBox.Show("'" + title + "' 메모를 지울까요?", "메모 삭제", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        list.Items.RemoveAt(i);
        if (list.Items.Count > 0) list.SelectedIndex = Math.Min(i, list.Items.Count - 1);
        else ShowNote();
        ScheduleSave();
    }

    void LoadNotes()
    {
        List<Note> loaded = null;
        if (File.Exists(dataPath))
        {
            try { loaded = Json().Deserialize<List<Note>>(File.ReadAllText(dataPath, Encoding.UTF8)); }
            catch (Exception)
            {
                // 깨진 파일을 덮어쓰지 않도록 옆으로 치워 둔다
                File.Move(dataPath, dataPath + ".broken-" + DateTime.Now.ToString("yyyyMMddHHmmss"));
            }
        }
        if (loaded != null) loaded.RemoveAll(n => n == null);
        if (loaded == null || loaded.Count == 0) loaded = new List<Note> { new Note { Text = Welcome } };
        foreach (var n in loaded)
        {
            if (n.Text == null) n.Text = "";
            if (n.Items == null) n.Items = new List<string>();
            list.Items.Add(n);
        }
        list.SelectedIndex = 0;
    }

    const string Welcome =
        "메모 바탕화면\r\n" +
        "왼쪽 위 + 로 새 메모를 만들어요. 첫 줄이 메모 제목이 돼요.\r\n\r\n" +
        "아래 '바로 가기' 칸에 파일, 폴더, 프로그램을 끌어다 놓으면 이 메모 전용 아이콘이 생겨요.\r\n" +
        "아이콘은 더블클릭하면 열리고, 오른쪽 클릭으로 뺄 수 있어요.\r\n\r\n" +
        "메모는 쓰는 즉시 자동 저장돼요.";

    // 기본 한도(약 2MB)를 넘으면 저장이 실패하고, 읽을 때는 깨진 파일로 오해해서 치워 버린다
    static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }; }

    void ScheduleSave() { saveTimer.Stop(); saveTimer.Start(); }

    void Save()
    {
        saveTimer.Stop();
        try
        {
            var json = Json().Serialize(list.Items.Cast<Note>().ToList());
            // 저장 도중 꺼져도 원본이 깨지지 않게 임시 파일에 쓰고 바꿔치기한다
            string tmp = dataPath + ".tmp";
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            if (File.Exists(dataPath)) File.Replace(tmp, dataPath, null);
            else File.Move(tmp, dataPath);
        }
        catch (IOException) { saveTimer.Start(); }   // 다른 프로그램이 잡고 있으면 잠시 뒤 다시
        catch (UnauthorizedAccessException) { saveTimer.Start(); }
    }

    // ---- 바로 가기 아이콘 ----

    void AcceptDrops(Control c)
    {
        c.AllowDrop = true;
        c.DragEnter += OnDragEnter;
        c.DragDrop += OnDragDrop;
    }

    void OnDragEnter(object sender, DragEventArgs e)
    {
        e.Effect = current != null && e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
    }

    void OnDragDrop(object sender, DragEventArgs e)
    {
        if (current == null) return;
        var paths = e.Data.GetData(DataFormats.FileDrop) as string[];
        if (paths == null) return;
        foreach (var path in paths)
            if (!current.Items.Contains(path, StringComparer.OrdinalIgnoreCase)) current.Items.Add(path);
        RebuildIcons();
        ScheduleSave();
    }

    void RebuildIcons()
    {
        var old = icons.Controls.Cast<Label>().ToList();
        icons.Controls.Clear();
        foreach (var t in old)
        {
            if (t.Image != null) t.Image.Dispose();
            if (t.ContextMenuStrip != null) t.ContextMenuStrip.Dispose();   // 라벨을 지워도 메뉴는 따로 남는다
            tip.SetToolTip(t, null);
            t.Dispose();
        }
        if (current == null) return;
        foreach (var path in current.Items) icons.Controls.Add(MakeTile(path));
    }

    Label MakeTile(string path)
    {
        string name = Directory.Exists(path) ? Path.GetFileName(path.TrimEnd('\\')) : Path.GetFileNameWithoutExtension(path);
        if (string.IsNullOrEmpty(name)) name = path;   // 드라이브 루트(C:\ 등)
        var t = new Label
        {
            AutoSize = false, Size = new Size(S(96), S(112)), Text = name, Image = GetIcon(path, S(48)),
            ImageAlign = ContentAlignment.TopCenter, TextAlign = ContentAlignment.BottomCenter, AutoEllipsis = true,
            Font = tileFont, ForeColor = File.Exists(path) || Directory.Exists(path) ? Ink : Gray, BackColor = Paper,
            Padding = new Padding(S(2), S(10), S(2), S(6)), Margin = new Padding(S(4)), Cursor = Cursors.Hand
        };
        t.DoubleClick += (s, e) => Open(path);
        t.MouseEnter += (s, e) => t.BackColor = Hover;
        t.MouseLeave += (s, e) => t.BackColor = Paper;
        var menu = new ContextMenuStrip();
        menu.Items.Add("열기", null, (s, e) => Open(path));
        menu.Items.Add("바로 가기 빼기", null, (s, e) =>
        {
            current.Items.Remove(path);
            BeginInvoke((Action)RebuildIcons);   // 메뉴를 가진 라벨을 지우므로 메뉴 처리가 끝난 뒤에
            ScheduleSave();
        });
        t.ContextMenuStrip = menu;
        tip.SetToolTip(t, path);
        AcceptDrops(t);   // 이미 있는 아이콘 위에 놓아도 추가되게
        return t;
    }

    static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(path + "\n\n열 수 없어요: " + ex.Message, "바로 가기"); }
    }

    // 탐색기와 같은 아이콘(사진은 미리보기)을 원하는 크기로 받아온다
    Bitmap GetIcon(string path, int size)
    {
        IShellItemImageFactory f;
        try { SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f); }
        catch (Exception) { return null; }   // 지워졌거나 옮겨진 파일
        try
        {
            IntPtr h;
            if (f.GetImage(new SIZE { cx = size, cy = size }, 0, out h) != 0) return null;
            try { return ToArgb(h); } finally { DeleteObject(h); }
        }
        catch (Exception) { return null; }   // 아이콘 하나 때문에 앱 전체가 죽으면 안 된다
        finally { Marshal.ReleaseComObject(f); }
    }

    // FromHbitmap은 투명도를 버리므로 32비트 픽셀을 한 줄씩 그대로 ARGB로 옮긴다
    // (탐색기가 주는 비트맵은 아래에서 위로 저장돼 Stride가 음수일 수 있어서 통째로 복사하면 안 된다)
    static Bitmap ToArgb(IntPtr h)
    {
        using (var src = Image.FromHbitmap(h))
        {
            if (src.PixelFormat != PixelFormat.Format32bppRgb && src.PixelFormat != PixelFormat.Format32bppArgb) return new Bitmap(src);
            var rect = new Rectangle(Point.Empty, src.Size);
            var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
            var from = src.LockBits(rect, ImageLockMode.ReadOnly, src.PixelFormat);
            var to = dst.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            bool hasAlpha = false;
            try
            {
                var row = new byte[src.Width * 4];
                for (int y = 0; y < src.Height; y++)
                {
                    Marshal.Copy(new IntPtr(from.Scan0.ToInt64() + (long)y * from.Stride), row, 0, row.Length);
                    for (int i = 3; i < row.Length && !hasAlpha; i += 4) hasAlpha = row[i] != 0;
                    Marshal.Copy(row, 0, new IntPtr(to.Scan0.ToInt64() + (long)y * to.Stride), row.Length);
                }
            }
            finally { src.UnlockBits(from); dst.UnlockBits(to); }
            if (hasAlpha) return dst;
            dst.Dispose();
            return new Bitmap(src);   // 투명도 없는 미리보기 사진
        }
    }

    // ---- 바탕화면에 붙이기 ----

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        // WinForms가 창을 다 만든 뒤에 붙여야 한다 (더 일찍 붙이면 WinForms가 다시 떼어 숨겨버림)
        Attach();
        poll = new Timer { Interval = 1000 };
        poll.Tick += (s, a) =>
        {
            // 끄기 신호를 받았거나 탐색기가 재시작되면 저장하고 종료, 떨어졌으면 다시 붙임
            if (stop.WaitOne(0) || !IsWindow(parent)) { Close(); return; }
            if (GetParent(Handle) != parent) Attach();
        };
        poll.Start();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        Save();
        base.OnFormClosing(e);
    }

    void Attach()
    {
        int style = GetWindowLong(Handle, GWL_STYLE);
        SetWindowLong(Handle, GWL_STYLE, (style & ~WS_POPUP) | WS_CHILD);
        SetParent(Handle, parent);
        // 24H2의 Progman 자식은 레이어드 창이어야 합성(DirectComposition)에 그려진다
        SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) | WS_EX_LAYERED);
        SetLayeredWindowAttributes(Handle, 0, 255, 2);
        // HWND_TOP: 아이콘 층보다 위 (그래서 클릭과 글쓰기가 된다)
        SetWindowPos(Handle, IntPtr.Zero, 0, 0, hostSize.Width, hostSize.Height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
'@

try { [MemoDesktop]::Run($dataFile) }
catch { $_ | Out-String | Set-Content (Join-Path $PSScriptRoot 'memo-error.log') -Encoding UTF8; throw }
