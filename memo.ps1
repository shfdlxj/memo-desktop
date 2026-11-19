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
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class Note
{
    public string Text { get; set; }
    public List<string> Items { get; set; }   // 이 메모에 붙은 바로 가기 경로
    public Note() { Text = ""; Items = new List<string>(); }
}

// 기본 ListBox는 항목을 다시 그릴 때마다 지웠다 그려서 깜빡이므로, 화면 밖에서 다 그린 뒤 한 번에 내보낸다
public class NoteList : ListBox
{
    public NoteList()
    {
        DrawMode = DrawMode.OwnerDrawFixed;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using (var b = new SolidBrush(BackColor)) e.Graphics.FillRectangle(b, ClientRectangle);
        for (int i = TopIndex; i < Items.Count; i++)
        {
            var r = GetItemRectangle(i);
            if (r.Top > ClientSize.Height) break;
            OnDrawItem(new DrawItemEventArgs(e.Graphics, Font, r, i, GetSelected(i) ? DrawItemState.Selected : DrawItemState.None));
        }
    }
}

// 마크다운 기호는 그대로 두고 흐리게 보이게, 내용은 제목·굵게·체크 등으로 바로 꾸며 주는 입력창 (저장은 평범한 마크다운 글)
public class MarkdownBox : RichTextBox
{
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, ref Point l);
    [DllImport("user32.dll", EntryPoint = "SendMessage")]
    static extern IntPtr SendMessageOle(IntPtr h, int msg, IntPtr w, [MarshalAs(UnmanagedType.IUnknown)] out object l);
    [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr h);
    [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr h, IntPtr c);
    [DllImport("imm32.dll", CharSet = CharSet.Unicode)] static extern int ImmGetCompositionString(IntPtr c, int index, IntPtr buf, int len);
    const int WM_SETREDRAW = 0x0B, EM_GETSCROLLPOS = 0x4DD, EM_SETSCROLLPOS = 0x4DE, EM_GETOLEINTERFACE = 0x43C, GCS_COMPSTR = 0x8;
    const int TomSuspend = -9999995, TomResume = -9999994;

    public static readonly Regex Heading = new Regex(@"^(#{1,3})\s"),
        Check = new Regex(@"^(\s*[-*+]\s\[([ xX])\])\s"),
        Bullet = new Regex(@"^(\s*(?:[-*+]|\d+\.))\s"),
        Quote = new Regex(@"^>\s?"),
        Bold = new Regex(@"\*\*(.+?)\*\*"),
        Strike = new Regex(@"~~(.+?)~~"),
        Code = new Regex(@"`([^`]+)`");

    public Color Ink, Muted, Accent, CodeBack;
    public string FontName = "Segoe UI";
    public float BaseSize = 13f;
    public bool Styling { get; private set; }
    Dictionary<string, Font> fonts = new Dictionary<string, Font>();
    Timer timer;
    bool needFull;

    public MarkdownBox()
    {
        BorderStyle = BorderStyle.None;
        DetectUrls = false;
        AcceptsTab = true;
        LanguageOption = (RichTextBoxLanguageOptions)0;   // 한글을 칠 때 글꼴을 멋대로 바꾸는 자동 글꼴 기능을 끈다
        timer = new Timer { Interval = 300 };
        timer.Tick += (s, e) =>
        {
            if (Composing()) return;   // 한글 조합 중에 꾸미면 조합이 끊긴다
            timer.Stop();
            Restyle(needFull);
            needFull = false;
        };
    }

    protected override void OnTextChanged(EventArgs e)
    {
        if (!Styling) { timer.Stop(); timer.Start(); }
        base.OnTextChanged(e);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        // 웹 등에서 복사한 서식·그림이 섞이지 않게 글자만 붙여 넣는다
        if ((e.Control && e.KeyCode == Keys.V) || (e.Shift && e.KeyCode == Keys.Insert))
        {
            e.SuppressKeyPress = true;
            if (!ReadOnly && Clipboard.ContainsText())
            {
                needFull = true;
                SelectedText = Clipboard.GetText().Replace("\r\n", "\n");
            }
            return;
        }
        base.OnKeyDown(e);
    }

    // 체크박스 "[ ]" 부분을 누르면 체크/해제
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || SelectionLength > 0 || ReadOnly) return;
        int idx = GetCharIndexFromPosition(e.Location);
        string text = Text;
        int start = idx > 0 ? text.LastIndexOf('\n', idx - 1) + 1 : 0;
        int end = text.IndexOf('\n', start);
        if (end < 0) end = text.Length;
        var m = Check.Match(text.Substring(start, end - start));
        if (!m.Success || idx > start + m.Groups[1].Length) return;
        int box = text.IndexOf('[', start) + 1;
        Select(box, 1);
        SelectedText = m.Groups[2].Value == " " ? "x" : " ";
        Select(start + m.Length, 0);
    }

    bool Composing()
    {
        IntPtr c = ImmGetContext(Handle);
        if (c == IntPtr.Zero) return false;
        try { return ImmGetCompositionString(c, GCS_COMPSTR, IntPtr.Zero, 0) > 0; }
        finally { ImmReleaseContext(Handle, c); }
    }

    Font F(float size, FontStyle style, string name = null)
    {
        name = name ?? FontName;
        string key = name + "|" + size + "|" + style;
        Font f;
        if (!fonts.TryGetValue(key, out f)) fonts[key] = f = new Font(name, size, style);
        return f;
    }

    // 꾸미기도 되돌리기(Ctrl+Z) 기록에 쌓이면 Ctrl+Z가 글 대신 서식을 되돌리므로 그동안 기록을 멈춘다
    void SetUndoRecording(bool on)
    {
        try
        {
            object doc;
            SendMessageOle(Handle, EM_GETOLEINTERFACE, IntPtr.Zero, out doc);
            doc.GetType().InvokeMember("Undo", BindingFlags.InvokeMethod, null, doc, new object[] { on ? TomResume : TomSuspend });
            Marshal.ReleaseComObject(doc);
        }
        catch (Exception) { }   // 못 멈추면 서식 변경이 되돌리기 기록에 섞일 뿐
    }

    // all이 아니면 커서가 있는 줄과 바로 윗줄만 (Enter로 줄이 나뉘거나 합쳐질 때 두 줄이 바뀐다)
    public void Restyle(bool all)
    {
        if (!IsHandleCreated) return;
        string text = Text;
        int caret = SelectionStart, selLen = SelectionLength;
        int from = 0, to = text.Length;
        if (!all)
        {
            int c = Math.Min(caret, text.Length);
            int cur = c > 0 ? text.LastIndexOf('\n', c - 1) + 1 : 0;
            from = cur >= 2 ? text.LastIndexOf('\n', cur - 2) + 1 : 0;
            to = text.IndexOf('\n', c);
            if (to < 0) to = text.Length;
        }

        var scroll = new Point();
        SendMessage(Handle, EM_GETSCROLLPOS, IntPtr.Zero, ref scroll);
        Styling = true;
        SendMessage(Handle, WM_SETREDRAW, IntPtr.Zero, IntPtr.Zero);
        SetUndoRecording(false);
        try
        {
            int pos = from;
            while (true)
            {
                int end = text.IndexOf('\n', pos);
                if (end < 0) end = text.Length;
                StyleLine(pos, text.Substring(pos, end - pos));
                if (end >= to) break;
                pos = end + 1;
            }
        }
        finally
        {
            Select(caret, selLen);
            SetUndoRecording(true);
            SendMessage(Handle, EM_SETSCROLLPOS, IntPtr.Zero, ref scroll);
            SendMessage(Handle, WM_SETREDRAW, new IntPtr(1), IntPtr.Zero);
            Invalidate();
            Styling = false;
        }
    }

    void Style(int start, int length, Font font, Color color, Color back)
    {
        Select(start, length);
        SelectionFont = font;
        SelectionColor = color;
        SelectionBackColor = back;
    }

    void StyleLine(int s, string line)
    {
        var body = F(BaseSize, FontStyle.Regular);
        Style(s, line.Length, body, Ink, BackColor);
        if (line.Length == 0) return;

        var m = Heading.Match(line);
        if (m.Success)
        {
            int level = m.Groups[1].Length;
            var font = F(level == 1 ? BaseSize * 1.6f : level == 2 ? BaseSize * 1.3f : BaseSize * 1.1f, FontStyle.Bold);
            Style(s, line.Length, font, Ink, BackColor);
            Style(s, m.Length, font, Muted, BackColor);
            return;
        }
        if ((m = Quote.Match(line)).Success)
        {
            Style(s, line.Length, F(BaseSize, FontStyle.Italic), Muted, BackColor);
            return;
        }
        if ((m = Check.Match(line)).Success)
        {
            Style(s, m.Groups[1].Length, F(BaseSize, FontStyle.Bold), Accent, BackColor);
            if (m.Groups[2].Value != " ")
            {
                Style(s + m.Length, line.Length - m.Length, F(BaseSize, FontStyle.Strikeout), Muted, BackColor);
                return;
            }
        }
        else if ((m = Bullet.Match(line)).Success)
            Style(s, m.Groups[1].Length, F(BaseSize, FontStyle.Bold), Accent, BackColor);

        foreach (Match b in Bold.Matches(line))
        {
            Style(s + b.Index, b.Length, F(BaseSize, FontStyle.Bold), Ink, BackColor);
            Style(s + b.Index, 2, F(BaseSize, FontStyle.Bold), Muted, BackColor);
            Style(s + b.Index + b.Length - 2, 2, F(BaseSize, FontStyle.Bold), Muted, BackColor);
        }
        foreach (Match x in Strike.Matches(line))
            Style(s + x.Index, x.Length, F(BaseSize, FontStyle.Strikeout), Muted, BackColor);
        foreach (Match c in Code.Matches(line))
        {
            var mono = F(BaseSize * 0.95f, FontStyle.Regular, "Consolas");
            Style(s + c.Index, c.Length, mono, Ink, CodeBack);
            Style(s + c.Index, 1, mono, Muted, CodeBack);
            Style(s + c.Index + c.Length - 1, 1, mono, Muted, CodeBack);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); foreach (var f in fonts.Values) f.Dispose(); }
        base.Dispose(disposing);
    }
}

// 바로 가기를 담는 둥근 카드. 비어 있거나 파일을 끌고 오는 중이면 점선 테두리로 놓을 자리를 알려 준다
public class ShortcutPanel : FlowLayoutPanel
{
    public Color Card, Border, DragCard, DragBorder, Muted;
    public Font HintFont, HintSubFont;
    public int Radius = 12;
    public float Dpi = 1;
    bool dragging;

    public ShortcutPanel()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw, true);
    }

    public bool Dragging
    {
        get { return dragging; }
        set { if (dragging != value) { dragging = value; Invalidate(true); } }
    }

    public Color Fill { get { return dragging ? DragCard : Card; } }

    protected override void OnScroll(ScrollEventArgs se) { base.OnScroll(se); Invalidate(); }
    protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); Invalidate(); }
    protected override void OnControlAdded(ControlEventArgs e) { base.OnControlAdded(e); Invalidate(); }
    protected override void OnControlRemoved(ControlEventArgs e) { base.OnControlRemoved(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        int inset = (int)Math.Ceiling(Dpi * 2);
        var r = new Rectangle(inset, inset, Width - inset * 2 - 1, Height - inset * 2 - 1);
        bool empty = Controls.Count == 0;
        using (var path = MemoDesktop.RoundRect(r, Radius))
        using (var b = new SolidBrush(Fill))
        using (var pen = new Pen(dragging ? DragBorder : Border, Dpi * (dragging ? 2 : 1.2f)))
        {
            if (dragging || empty) pen.DashPattern = new[] { 4f, 3f };
            g.FillPath(b, path);
            g.DrawPath(pen, path);
        }
        if (!empty && !dragging) return;
        string main = dragging ? "여기에 놓으면 이 메모의 바로 가기가 돼요" : "＋  파일 · 폴더 · 앱을 여기로 끌어다 놓으세요";
        string sub = dragging ? "" : "이 메모를 열었을 때만 보이는 바로 가기가 돼요";
        var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix;
        int mid = r.Y + r.Height / 2;
        if (sub.Length == 0) TextRenderer.DrawText(g, main, HintFont, r, dragging ? DragBorder : Muted, flags);
        else
        {
            int lh = HintFont.Height;
            TextRenderer.DrawText(g, main, HintFont, new Rectangle(r.X, mid - lh, r.Width, lh), Muted, flags);
            TextRenderer.DrawText(g, sub, HintSubFont, new Rectangle(r.X, mid + (int)(Dpi * 4), r.Width, HintSubFont.Height), Muted, flags);
        }
    }
}

// 바로 가기 아이콘 하나: 아이콘 + 두 줄까지 이름, 마우스를 올리면 둥근 배경
public class Tile : Control
{
    public string Target;
    public Image Icon;
    public bool Missing;
    public int IconSize = 44, Pad = 10, Radius = 10;
    public Color Ink, Muted, HoverBack;
    bool hover;

    public Tile()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var panel = Parent as ShortcutPanel;
        g.Clear(panel != null ? panel.Fill : BackColor);
        if (hover)
            using (var b = new SolidBrush(HoverBack))
            using (var path = MemoDesktop.RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
                g.FillPath(b, path);
        if (Icon != null)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(Icon, (Width - IconSize) / 2, Pad, IconSize, IconSize);
        }
        int top = Pad + IconSize + Pad / 2;
        TextRenderer.DrawText(g, Text, Font, new Rectangle(Pad / 2, top, Width - Pad, Height - top - Pad / 2), Missing ? Muted : Ink,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (Icon != null) Icon.Dispose();
            if (ContextMenuStrip != null) ContextMenuStrip.Dispose();   // 컨트롤을 지워도 메뉴는 따로 남는다
        }
        base.Dispose(disposing);
    }
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
        Pick = Color.FromArgb(250, 229, 150), Hover = Color.FromArgb(240, 237, 229),
        Gold = Color.FromArgb(201, 152, 30), Card = Color.FromArgb(251, 250, 246), DragCard = Color.FromArgb(255, 249, 226),
        CodeBack = Color.FromArgb(243, 241, 236);
    const string FontName = "맑은 고딕";

    IntPtr parent;
    Size hostSize;
    float k = 1;             // DPI 배율 (이 프로세스는 실제 픽셀 단위로 그린다)
    Rectangle win;           // 화면 가운데 떠 있는 메모 창 영역
    int sideW, x0, w0, dividerY;
    string dataPath;
    System.Threading.EventWaitHandle stop;
    NoteList list;
    MarkdownBox editor;
    ShortcutPanel icons;
    Label iconsTitle;
    string shownPreview;     // 목록에 보이는 제목+미리보기 (바뀔 때만 목록을 다시 그린다)
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

        list = new NoteList
        {
            ItemHeight = Math.Min(255, S(68)), BorderStyle = BorderStyle.None,
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
        int iconsH = S(148);
        dividerY = win.Bottom - iconsH - S(76);   // 바로 가기 영역의 위쪽 경계

        editor = new MarkdownBox
        {
            BackColor = Paper, ForeColor = Ink, Ink = Ink, Muted = Gray, Accent = Gold, CodeBack = CodeBack,
            FontName = FontName, BaseSize = 13f, Font = new Font(FontName, 13f), MaxLength = int.MaxValue,
            Bounds = new Rectangle(x0, win.Y + S(48), w0, dividerY - S(12) - (win.Y + S(48)))
        };
        editor.TextChanged += (s, e) =>
        {
            if (loading || current == null || editor.Styling) return;
            current.Text = editor.Text;
            string preview = string.Join("\n", Preview(current.Text));
            if (preview != shownPreview && list.SelectedIndex >= 0)
            {
                shownPreview = preview;
                list.Invalidate(list.GetItemRectangle(list.SelectedIndex));
            }
            ScheduleSave();
        };

        iconsTitle = new Label
        {
            Font = new Font(FontName, 10f, FontStyle.Bold), ForeColor = Ink, BackColor = Paper, AutoSize = false,
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(x0, dividerY + S(16), w0 / 2, S(30))
        };
        var iconsHint = new Label
        {
            Text = "더블클릭으로 열기 · 오른쪽 클릭으로 빼기", Font = new Font(FontName, 9f), ForeColor = Gray, BackColor = Paper,
            AutoSize = false, TextAlign = ContentAlignment.MiddleRight,
            Bounds = new Rectangle(x0 + w0 / 2, dividerY + S(16), w0 - w0 / 2, S(30))
        };
        icons = new ShortcutPanel
        {
            BackColor = Paper, AutoScroll = true, Card = Card, Border = Line, DragCard = DragCard, DragBorder = Gold, Muted = Gray,
            HintFont = new Font(FontName, 10.5f), HintSubFont = new Font(FontName, 9f), Radius = S(12), Dpi = k,
            Padding = new Padding(S(10)),
            Bounds = new Rectangle(x0, win.Bottom - iconsH - S(24), w0, iconsH)
        };
        foreach (Control c in new Control[] { this, iconsTitle, iconsHint, icons }) AcceptDrops(c);

        Controls.AddRange(new Control[] { newBtn, list, editor, iconsTitle, iconsHint, icons });
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
            g.DrawPath(pen, path);
        }
        // 맥 창 왼쪽 위의 빨강·노랑·초록 버튼 (장식)
        var dots = new[] { Color.FromArgb(255, 95, 87), Color.FromArgb(254, 188, 46), Color.FromArgb(40, 200, 64) };
        for (int i = 0; i < 3; i++)
            using (var b = new SolidBrush(dots[i]))
                g.FillEllipse(b, win.X + S(20) + i * S(20), win.Y + S(20), S(12), S(12));
    }

    public static GraphicsPath RoundRect(Rectangle r, int radius)
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

    static readonly Regex LineMarks = new Regex(@"^(#{1,6}\s+|\s*[-*+]\s\[[ xX]\]\s+|\s*(?:[-*+]|\d+\.)\s+|>\s?)");

    // 목록에 보일 제목·미리보기: 앞의 빈 줄을 건너뛴 첫 두 줄을 마크다운 기호 없이 (글 전체를 나누지 않고 앞에서부터 찾는다)
    static string[] Preview(string text)
    {
        var lines = new List<string>();
        int pos = 0;
        while (lines.Count < 2 && pos <= text.Length)
        {
            int end = text.IndexOf('\n', pos);
            if (end < 0) end = text.Length;
            string line = LineMarks.Replace(text.Substring(pos, end - pos).Trim(), "").Replace("**", "").Replace("~~", "").Replace("`", "").Trim();
            if (line.Length > 0) lines.Add(line);
            pos = end + 1;
        }
        return lines.ToArray();
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
        var lines = Preview(((Note)list.Items[e.Index]).Text);
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
        // 입력창은 줄바꿈을 \n 하나로 다루므로 맞춰 둔다 (예전 \r\n 메모도 그대로 열리게)
        if (current != null) current.Text = current.Text.Replace("\r\n", "\n");
        editor.Text = current == null ? "" : current.Text;
        editor.ReadOnly = current == null;
        // shortcut: 아주 긴 메모(20만 자 넘게)는 열 때 전체를 꾸미면 몇 초 멈춰서 커서 주변만 꾸민다, 자주 쓰이면 화면에 보이는 부분만 꾸미게 바꾸기
        editor.Restyle(editor.TextLength <= 200000);
        editor.ClearUndo();   // 다른 메모로 넘어온 뒤 Ctrl+Z로 이전 메모 내용이 돌아오지 않게
        shownPreview = current == null ? null : string.Join("\n", Preview(current.Text));
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
        var lines = Preview(((Note)list.Items[i]).Text);
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
        "# 메모 바탕화면\n" +
        "왼쪽 위 **+** 로 새 메모를 만들어요. 첫 줄이 메모 제목이 돼요.\n\n" +
        "## 마크다운\n" +
        "- # 제목, ## 소제목, ### 작은 제목\n" +
        "- **굵게**, ~~취소선~~, `코드`\n" +
        "- [ ] 할 일은 - [ ] 로 쓰고, 네모를 누르면 체크돼요\n" +
        "- [x] 끝난 일\n" +
        "> 인용은 > 로 시작해요\n\n" +
        "## 바로 가기\n" +
        "아래 칸에 파일, 폴더, 프로그램을 끌어다 놓으면 이 메모 전용 아이콘이 생겨요.\n\n" +
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
        c.DragLeave += (s, e) => icons.Dragging = false;
    }

    void OnDragEnter(object sender, DragEventArgs e)
    {
        bool ok = current != null && e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effect = ok ? DragDropEffects.Copy : DragDropEffects.None;
        icons.Dragging = ok;
    }

    void OnDragDrop(object sender, DragEventArgs e)
    {
        icons.Dragging = false;
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
        var old = icons.Controls.Cast<Tile>().ToList();
        icons.SuspendLayout();
        icons.Controls.Clear();
        foreach (var t in old) { tip.SetToolTip(t, null); t.Dispose(); }
        if (current != null)
            foreach (var path in current.Items) icons.Controls.Add(MakeTile(path));
        icons.ResumeLayout();
        int n = current == null ? 0 : current.Items.Count;
        iconsTitle.Text = n == 0 ? "바로 가기" : "바로 가기  " + n;
    }

    Tile MakeTile(string path)
    {
        string name = Directory.Exists(path) ? Path.GetFileName(path.TrimEnd('\\')) : Path.GetFileNameWithoutExtension(path);
        if (string.IsNullOrEmpty(name)) name = path;   // 드라이브 루트(C:\ 등)
        var t = new Tile
        {
            Target = path, Text = name, Icon = GetIcon(path, S(44)), Missing = !File.Exists(path) && !Directory.Exists(path),
            Size = new Size(S(92), S(106)), Margin = new Padding(S(2)), Font = tileFont,
            IconSize = S(44), Pad = S(10), Radius = S(10), Ink = Ink, Muted = Gray, HoverBack = Hover
        };
        t.DoubleClick += (s, e) => Open(path);
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
        ShowNote();   // 처음 불러올 때는 입력창이 아직 만들어지기 전이라 꾸미기를 못 했다
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
