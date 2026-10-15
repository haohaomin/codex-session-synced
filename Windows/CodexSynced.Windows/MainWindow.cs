using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using WpfBinding = System.Windows.Data.Binding;
using WpfBrush = System.Windows.Media.Brush;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfButton = System.Windows.Controls.Button;
using WpfColor = System.Windows.Media.Color;
using WpfControl = System.Windows.Controls.Control;
using WpfCursors = System.Windows.Input.Cursors;
using WpfFontFamily = System.Windows.Media.FontFamily;
using WpfPoint = System.Windows.Point;
using WpfProgressBar = System.Windows.Controls.ProgressBar;
using WpfSize = System.Windows.Size;

namespace CodexSynced.Windows;

internal enum UiSection { Home, Pending, History, Backups, Settings }
internal enum UiLanguage { Zh, En }

internal sealed class MainWindow : Window
{
    private static readonly WpfBrush Blue = Brush("#055EEB");
    private static readonly WpfBrush Ink = Brush("#14171F");
    private static readonly WpfBrush Muted = Brush("#6D7480");
    private static readonly WpfBrush PageBg = Brush("#F6F8FB");
    private static readonly WpfBrush SidebarBg = Brush("#FBFCFE");
    private static readonly WpfBrush Subtle = Brush("#FBFCFE");
    private static readonly WpfBrush Line = Brush("#12000000");
    private static readonly WpfBrush Ok = Brush("#0D804D");
    private static readonly WpfBrush Warn = Brush("#D1610D");
    private static readonly string AppVersion = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "dev";

    private readonly RepairService _service = new();
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly Grid _root = new();
    private readonly Grid _host = new();
    private readonly StackPanel _nav = new();
    private readonly List<WpfButton> _navButtons = [];
    private readonly Dictionary<WpfButton, UiLanguage> _languageButtons = [];
    private readonly Dictionary<WpfButton, BackupMode> _modeButtons = [];
    private readonly HistoryEntrypointService _historyService = new();
    private ScanResult? _scan;
    private HistoryScanResult? _historyScan;
    private List<HistoryRepairRecord> _historyRecords = [];
    private string? _scanError;
    private UiSection _section;
    private UiLanguage _language = UiLanguage.Zh;
    private BackupMode _backupMode;
    private bool _busy;
    private string _busyTitle = "";
    private string _busyDetail = "";
    private double _busyProgress;
    private bool _checkingUpdate;
    private bool _startupUpdateChecked;
    private SoftwareUpdate? _updateCandidate;
    private string? _updateError;
    private DateTime? _updateCheckedAt;
    private string? _historyMessage;
    private bool _historyScanning;
    private List<ManagedBackup> _managedBackups = [];
    private List<string> _backupWarnings = [];
    private bool _loadingBackups;

    public MainWindow()
    {
        Title = "Codex Synced";
        Width = 1180;
        Height = 780;
        MinWidth = 1040;
        MinHeight = 680;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = PageBg;
        FontFamily = new WpfFontFamily("Microsoft YaHei UI, Segoe UI, Arial");
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        _section = UiSection.Home;
        _language = string.Equals(_settings.Language, "en", StringComparison.OrdinalIgnoreCase) ? UiLanguage.En : UiLanguage.Zh;
        _backupMode = _settings.DefaultBackupMode;
        _host.Background = PageBg;

        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        _root.ColumnDefinitions.Add(new ColumnDefinition());
        Content = _root;

        Add(BuildSidebar(), 0);
        Add(new Border { Background = Brush("#11000000"), Width = 1, HorizontalAlignment = System.Windows.HorizontalAlignment.Right }, 0);
        Add(_host, 1);
        Show(BuildHome(), false);
        ContentRendered += (_, _) => { if (_host.Children.Count == 0) Show(CurrentView(), false); };
        Loaded += async (_, _) => await ScanAsync();
        Loaded += async (_, _) =>
        {
            if (_startupUpdateChecked) return;
            _startupUpdateChecked = true;
            if (_settings.CheckForUpdatesOnLaunch) await CheckForUpdatesAsync(manual: false);
        };
    }

    public void SaveSnapshot(string outputPath, string? codexHome)
    {
        if (!string.IsNullOrWhiteSpace(codexHome)) _settings.CodexHome = codexHome;
        _scan = _service.Scan(SnapshotSettings());
        _scanError = null;
        _busy = false;
        Show(BuildHome(), false);
        _root.Width = 1120;
        _root.Height = 760;
        _root.Measure(new WpfSize(1120, 760));
        _root.Arrange(new Rect(0, 0, 1120, 760));
        _root.UpdateLayout();
        var bitmap = new RenderTargetBitmap(1120, 760, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(_root);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        using var stream = File.Create(outputPath);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(stream);
    }

    private string T(string zh, string en) => _language == UiLanguage.Zh ? zh : en;
    private void Add(UIElement element, int column) { Grid.SetColumn(element, column); _root.Children.Add(element); }

    private UIElement BuildSidebar()
    {
        var dock = new DockPanel { Background = SidebarBg };
        var language = LanguageSwitch();
        language.Margin = new Thickness(18, 0, 18, 18);
        DockPanel.SetDock(language, Dock.Bottom);
        dock.Children.Add(language);

        var stack = new StackPanel { Margin = new Thickness(14, 22, 14, 0) };
        dock.Children.Add(stack);
        var brand = new Grid { Margin = new Thickness(4, 0, 4, 24) };
        brand.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        brand.ColumnDefinitions.Add(new ColumnDefinition());
        brand.Children.Add(new Border
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(8),
            Background = Blue,
            Child = Text("↻", 19, FontWeights.SemiBold, WpfBrushes.White, center: true)
        });
        var copy = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        copy.Children.Add(Text("Codex Synced", 16, FontWeights.SemiBold, Ink));
        copy.Children.Add(Text(T($"会话历史修复 · v{AppVersion}", $"History Repair · v{AppVersion}"), 12, FontWeights.Normal, Muted));
        Grid.SetColumn(copy, 1);
        brand.Children.Add(copy);
        stack.Children.Add(brand);
        stack.Children.Add(_nav);
        BuildNavButtons();
        return dock;
    }

    private void BuildNavButtons()
    {
        _nav.Children.Clear();
        _navButtons.Clear();
        AddNav(UiSection.Home, "⌂", T("首页", "Home"));
        AddNav(UiSection.Pending, "☷", T("待修复项", "Pending"));
        AddNav(UiSection.History, "▱", T("对话修复", "Chat Repair"));
        AddNav(UiSection.Backups, "▣", T("备份", "Backups"));
        AddNav(UiSection.Settings, "⚙", T("设置", "Settings"));
        UpdateNav();
    }

    private void AddNav(UiSection section, string icon, string title)
    {
        var b = Button($"{icon}  {title}", false, () =>
        {
            if (_section == section) return;
            _section = section;
            UpdateNav();
            Show(CurrentView(), true);
            if (section == UiSection.Backups) _ = RefreshBackupsAsync();
        });
        b.Tag = section;
        b.Height = 42;
        b.Margin = new Thickness(0, 0, 0, 8);
        b.HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left;
        _navButtons.Add(b);
        _nav.Children.Add(b);
    }

    private Border LanguageSwitch()
    {
        var grid = new UniformGrid { Columns = 2 };
        var zh = Segment("中文", () => ChangeLanguage(UiLanguage.Zh));
        var en = Segment("English", () => ChangeLanguage(UiLanguage.En));
        RegisterLanguageSegment(zh, UiLanguage.Zh);
        RegisterLanguageSegment(en, UiLanguage.En);
        grid.Children.Add(zh);
        grid.Children.Add(en);
        var box = Shell(grid, 8, 3);
        UpdateLanguageSegments();
        return box;
    }

    private void RegisterLanguageSegment(WpfButton button, UiLanguage language)
    {
        _languageButtons[button] = language;
        button.Unloaded += (_, _) => _languageButtons.Remove(button);
    }

    private void ChangeLanguage(UiLanguage language)
    {
        if (_language == language) return;
        _language = language;
        _settings.Language = language == UiLanguage.En ? "en" : "zh";
        _settings.Save();
        BuildNavButtons();
        UpdateLanguageSegments();
        Show(CurrentView(), true);
    }

    private UIElement CurrentView() => _section switch
    {
        UiSection.Pending => BuildPending(),
        UiSection.History => BuildHistory(),
        UiSection.Backups => BuildBackups(),
        UiSection.Settings => BuildSettings(),
        _ => BuildHome()
    };

    private void Show(UIElement view, bool animate)
    {
        _host.Children.Clear();
        view.Opacity = animate ? 0 : 1;
        view.RenderTransform = new TranslateTransform(animate ? 14 : 0, 0);
        _host.Children.Add(view);
        if (!animate) return;
        Anim(view, UIElement.OpacityProperty, 0, 1, 180);
        Anim((TranslateTransform)view.RenderTransform, TranslateTransform.XProperty, 14, 0, 200);
        WatchVisible(view);
    }

    private void WatchVisible(UIElement view)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(420) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_host.Children.Count == 0)
            {
                _host.Children.Add(BuildFallbackPage(T("界面加载中断", "View Loading Interrupted"), T("内容区域被意外清空。请重新扫描，或重启应用。", "The content area was cleared unexpectedly. Scan again or restart the app.")));
                return;
            }
            if (ReferenceEquals(_host.Children[0], view) && view.Opacity < .05)
                view.Opacity = 1;
        };
        timer.Start();
    }

    private ScrollViewer Page(string title, string subtitle, params UIElement[] blocks)
    {
        var stack = new StackPanel { Margin = new Thickness(28, 22, 28, 22) };
        stack.Children.Add(Header(title, subtitle));
        foreach (var block in blocks)
        {
            if (block is FrameworkElement fe) fe.Margin = new Thickness(0, 0, 0, 14);
            stack.Children.Add(block);
        }
        return new ScrollViewer { Background = PageBg, Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private UIElement Header(string title, string subtitle)
    {
        var s = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        s.Children.Add(Text(title, 24, FontWeights.SemiBold, Ink));
        var sub = Text(subtitle, 13, FontWeights.Normal, Muted);
        sub.Margin = new Thickness(0, 4, 0, 0);
        s.Children.Add(sub);
        return s;
    }

    private UIElement BuildHome()
    {
        var status = _scanError is not null ? Warn : _scan?.HasRepairs == true ? Blue : _scan?.HasWarnings == true ? Warn : Ok;
        if (_busy) status = Blue;
        var top = Panel(StatusPanel(status));
        var metrics = new UniformGrid { Columns = 3, Margin = new Thickness(0, 0, 0, 10) };
        metrics.Children.Add(Metric("Provider", _scan?.SqliteProviderUpdates.Count ?? 0, T("按 rollout 回写 SQLite", "SQLite follows rollout")));
        metrics.Children.Add(Metric(T("标题", "Titles"), _scan?.SqliteTitleRepairs.Count ?? 0, T("避免新对话", "Avoid untitled rows")));
        metrics.Children.Add(Metric(T("时间", "Timestamps"), (_scan?.SqliteTimestampRepairs.Count ?? 0) + (_scan?.RolloutMtimeRepairs.Count ?? 0), "SQLite + mtime"));
        metrics.Children.Add(Metric(T("索引", "Index"), _scan?.IndexRepairs.Count ?? 0, "session_index.jsonl"));
        metrics.Children.Add(Metric(T("UI 状态", "UI State"), _scan?.GlobalStateRepair?.Changes.Count ?? 0, ".codex-global-state.json"));
        metrics.Children.Add(Metric(T("兼容字段", "Compatibility"), _scan?.SqliteCompatibilityUpdates.Count ?? 0, T("保守禁用", "Conservative")));
        return Page(T("会话历史修复", "Conversation History Repair"), T("修复 Codex Desktop 侧边栏标题、时间、索引和本地 UI 状态。", "Repair Codex Desktop sidebar titles, timestamps, index, and local UI state."), top, metrics, _scan?.HasWarnings == true ? Panel(PaginatedWarningPanel()) : new Border(), Panel(ActionPanel()));
    }

    private UIElement StatusPanel(WpfBrush status)
    {
        var outer = new StackPanel();
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(8), Background = Alpha(status, .10), Child = Text(_scan?.HasRepairs == true ? "⌁" : _scan?.HasWarnings == true ? "!" : "✓", 18, FontWeights.SemiBold, status, center: true) });
        var copy = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        copy.Children.Add(Text(StatusTitle(), 18, FontWeights.SemiBold, Ink));
        var detail = Text(StatusSubtitle(), 12, FontWeights.Normal, Muted);
        detail.Margin = new Thickness(0, 4, 0, 0);
        detail.TextWrapping = TextWrapping.Wrap;
        copy.Children.Add(detail);
        Grid.SetColumn(copy, 1);
        row.Children.Add(copy);
        if (_scan is not null)
        {
            var tags = new StackPanel { HorizontalAlignment = System.Windows.HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 220 };
            tags.Children.Add(Pill(_scan.ProviderInfo.AuthLabel, status));
            tags.Children.Add(Pill($"Provider: {_scan.ProviderInfo.Provider}", Blue));
            tags.Children.Add(Pill(Path.GetFileName(_scan.StateDatabase?.Path ?? T("未找到状态库", "No state database")), Muted));
            Grid.SetColumn(tags, 2);
            row.Children.Add(tags);
        }
        outer.Children.Add(row);
        outer.Children.Add(Divider());
        if (_busy) outer.Children.Add(BusyProgress(status));
        outer.Children.Add(InfoRow());
        return outer;
    }

    private UIElement InfoRow()
    {
        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(Info(T("Codex 本地目录", "Codex Home"), _scan?.CodexHome ?? _settings.CodexHome));
        var line = new Border { Background = Brush("#14000000"), Margin = new Thickness(16, 0, 16, 0) };
        Grid.SetColumn(line, 1);
        grid.Children.Add(line);
        var last = Info(T("最近修复", "Last Repair"), T("暂无记录", "No record"));
        Grid.SetColumn(last, 2);
        grid.Children.Add(last);
        return grid;
    }

    private UIElement ActionPanel()
    {
        var repairs = _scan?.HasRepairs == true;
        var warnings = _scan?.HasWarnings == true;
        var failed = _scanError is not null;
        var s = new StackPanel();
        s.Children.Add(Text(_busy ? T("正在处理", "Working") : failed ? T("扫描遇到问题", "Scan Needs Attention") : repairs ? T("发现待修复项", "Repairs Found") : warnings ? T("发现分页风险", "Paginated Review Needed") : T("侧边栏状态正常", "Sidebar Looks Healthy"), 16, FontWeights.SemiBold, Ink));
        var sub = Text(_busy ? _busyDetail : failed ? _scanError! : repairs ? T($"发现 {_scan!.PendingCount} 项侧边栏摘要问题。下一步查看变更并选择备份模式。", $"Found {_scan!.PendingCount} sidebar summary issues. Review changes and select a backup mode.") : warnings ? T($"发现分页 Provider 复核项。普通修复不会改写分页首行；通过校验的项目可在下方独立确认。", $"Paginated Provider review items were found. Ordinary repair never rewrites paginated headers; validated items can be confirmed separately below.") : T("当前没有待处理项。重新扫描即可检查本地历史。", "No pending items. Scan again to check local history state."), 12, FontWeights.Normal, failed || warnings ? Warn : Muted);
        sub.Margin = new Thickness(0, 4, 0, 14);
        sub.TextWrapping = TextWrapping.Wrap;
        s.Children.Add(sub);
        var primary = Button(repairs ? T("查看并修复", "Review and Repair") : T("重新扫描", "Scan Again"), true, () => { if (repairs) { _section = UiSection.Pending; UpdateNav(); Show(BuildPending(), true); } else _ = ScanAsync(); }, _busy);
        primary.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        s.Children.Add(repairs
            ? Flow(primary, Button(T("重新扫描", "Scan Again"), false, async () => await ScanAsync()), Button(T("打开备份目录", "Open Backups"), false, () => RepairService.OpenDirectory(RepairService.BackupRoot(_settings.CodexHome))), Button(T("打开 Codex", "Open Codex"), false, RepairService.OpenCodex))
            : Flow(primary, Button(T("打开备份目录", "Open Backups"), false, () => RepairService.OpenDirectory(RepairService.BackupRoot(_settings.CodexHome))), Button(T("打开 Codex", "Open Codex"), false, RepairService.OpenCodex)));
        s.Children.Add(Divider());
        s.Children.Add(Text(T("最近备份", "Recent Backup"), 14, FontWeights.SemiBold, Ink));
        var backup = _scan?.Backups.FirstOrDefault();
        s.Children.Add(Text(backup is null ? T("尚未创建备份。只有存在实际待修复项时才会备份。", "No backups yet. Backups are created only when repairs are applied.") : $"{ShortDate(backup.CreatedAt)} · {ModeTitle(backup.Mode)} · {FileSize(backup.SizeBytes)}", 12, FontWeights.Normal, Muted));
        return s;
    }

    private UIElement BuildPending()
    {
        var summary = Panel(Summary(
            (T("目标 Provider", "Target Provider"), _scan?.ProviderInfo.Provider ?? "-"),
            (_settings.AlignProvidersForVisibility ? T("对齐到当前 Provider 的 SQLite 记录", "SQLite rows aligned to active provider") : T("按 rollout 修正 Provider 的 SQLite 记录", "SQLite provider rows matched to rollout"), (_scan?.SqliteProviderUpdates.Count ?? 0).ToString()),
            (T("待对齐 rollout Provider", "Rollout providers to align"), (_scan?.RolloutRepairs.Count ?? 0).ToString()),
            (T("分页 Provider 风险", "Paginated Provider warnings"), (_scan?.PaginatedProviderWarnings.Count ?? 0).ToString()),
            (T("可安全重算分页偏移", "Validated paginated repairs"), (_scan?.PaginatedProviderRepairs.Count ?? 0).ToString()),
            (T("待写入短标题", "Sidebar title rows"), (_scan?.SqliteTitleRepairs.Count ?? 0).ToString()),
            (T("待修复更新时间", "Timestamp rows"), ((_scan?.SqliteTimestampRepairs.Count ?? 0) + (_scan?.RolloutMtimeRepairs.Count ?? 0)).ToString()),
            (T("待重建索引条目", "Index entries to rebuild"), (_scan?.IndexRepairs.Count ?? 0).ToString()),
            (T("全局 UI 状态变更", "Global UI state changes"), (_scan?.GlobalStateRepair?.Changes.Count ?? 0).ToString())));
        var choice = new Grid();
        choice.ColumnDefinitions.Add(new ColumnDefinition());
        choice.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        choice.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        choice.Children.Add(TextBlockPair(T("备份模式", "Backup Mode"), T("轻量备份只保存必要回滚数据；全量备份会额外保存 sessions。", "Lightweight stores rollback data; full also copies sessions.")));
        var mode = ModeSwitch();
        mode.Margin = new Thickness(16, 0, 0, 0);
        var repair = Button(T("备份并修复", "Back Up and Repair"), true, RepairAsync, !(_scan?.HasRepairs ?? false) || _busy);
        repair.Margin = new Thickness(12, 0, 0, 0);
        AddTo(choice, mode, 1);
        AddTo(choice, repair, 2);
        return _busy
            ? Page(T("待修复项", "Pending Repairs"), T("修复前预览，不会写入数据，确认后先备份再修复。", "Dry-run preview. Confirming creates a backup before changes."), summary, Panel(choice), Panel(BusyProgress(Blue)), Panel(PreviewList()))
            : Page(T("待修复项", "Pending Repairs"), T("修复前预览，不会写入数据，确认后先备份再修复。", "Dry-run preview. Confirming creates a backup before changes."), summary, Panel(choice), Panel(PreviewList()));
    }

    private UIElement BuildHistory()
    {
        var databases = new List<string>();
        try { databases = _historyService.DatabaseCandidates(SnapshotSettings()); }
        catch (Exception ex) { _historyMessage = ex.Message; }
        try { _historyRecords = _historyService.Records(SnapshotSettings()); }
        catch (Exception ex) { _historyMessage = ex.Message; }
        var selector = new System.Windows.Controls.ComboBox { MinWidth = 260, MaxWidth = 640, IsEnabled = !_busy };
        selector.Items.Add(T("自动（仅有一个状态库时）", "Automatic (only if unambiguous)"));
        foreach (var path in databases) selector.Items.Add(path);
        if (_settings.HistoryDatabase is { } selectedDatabase && !databases.Contains(selectedDatabase)) selector.Items.Add(selectedDatabase);
        selector.SelectedIndex = _settings.HistoryDatabase is null ? 0 : selector.Items.IndexOf(_settings.HistoryDatabase);
        selector.SelectionChanged += (_, _) =>
        {
            _settings.HistoryDatabase = selector.SelectedIndex <= 0 ? null : selector.SelectedItem as string;
            _historyScan = null;
            _historyMessage = null;
            try { _settings.Save(); } catch (Exception ex) { _historyMessage = ex.Message; }
            TryShowCurrent(false);
        };
        var content = new List<UIElement>
        {
            Panel(TextBlockPair(T("只改读取入口，不拼接正文", "Repair the entrypoint, never concatenate messages"), T("扫描只读。入口修复或撤销前必须退出 Codex；多个末端、缺失父分支、序号或字节边界不一致会停在人工确认。", "Scanning is read-only. Quit Codex before repair or rollback; ambiguous tips, missing parents, ordinal gaps, and byte-boundary mismatches require manual review."))),
            Panel(Row(Button(T(_historyScanning ? "正在扫描…" : "只读扫描", _historyScanning ? "Scanning…" : "Read-only Scan"), false, ScanHistoryAsync, _busy), Button(T("打开修复记录", "Open Repair Records"), false, () => OpenExistingBackupFolder(Path.Combine(_settings.CodexHome, "history-entrypoint-backups"))), Button(T("刷新状态库列表", "Refresh Databases"), false, () => TryShowCurrent(false), _busy))),
            Panel(Row(UpdateText(T("诊断状态库（仅用于本页）；多个文件时明确选择，不猜测、不移动数据库。其他目录可在设置中选择 SQLite Home。", "Database for this page only: select a file when ambiguous; no guessing or moving databases. For other directories, set SQLite Home in Settings."), Muted), selector))
        };
        if (_busy) content.Add(Panel(BusyProgress(Blue)));
        if (_historyMessage is not null) content.Add(Panel(UpdateText(_historyMessage, Warn)));
        if (_historyScan is null)
        {
            content.Add(Panel(Empty("⌁", T("尚未扫描对话入口", "Chat entrypoints have not been scanned"), T("扫描会沿 history_base 检查唯一后继链，不会写入文件。", "The scan follows history_base and never writes files."))));
        }
        else
        {
            content.Add(Panel(TextBlockPair(T("状态库", "State database"), _historyScan.Database)));
            foreach (var warning in _historyScan.Warnings)
            {
                var text = Text(warning, 12, FontWeights.Normal, Warn, mono: true);
                text.TextWrapping = TextWrapping.Wrap;
                content.Add(Panel(text));
            }
            if (_historyScan.Diagnoses.Count == 0)
                content.Add(Panel(Empty("✓", T("未发现可识别的分页对话", "No recognized paginated chats"), T("这不代表所有历史都已验证；旧格式不在此入口修复范围内。", "This is not an all-clear; legacy formats are outside this repair entrypoint."))));
            foreach (var diagnosis in _historyScan.Diagnoses.OrderBy(item => item.CanRepair ? 0 : 1).ThenBy(item => item.Id, StringComparer.OrdinalIgnoreCase))
            {
                var stack = new StackPanel();
                stack.Children.Add(Text(PreviewTitle(diagnosis.Title, diagnosis.Id), 15, FontWeights.SemiBold, Ink));
                stack.Children.Add(Text(diagnosis.Id, 12, FontWeights.Normal, Muted, mono: true));
                stack.Children.Add(Text(diagnosis.Detail, 12, FontWeights.Normal, diagnosis.CanRepair ? Blue : Muted));
                stack.Children.Add(Text(T("当前入口", "Current entrypoint") + ": " + diagnosis.CurrentPath, 11, FontWeights.Normal, Muted, mono: true));
                if (diagnosis.ProposedPath is not null)
                {
                    stack.Children.Add(Text(T("建议入口", "Proposed entrypoint") + ": " + diagnosis.ProposedPath, 11, FontWeights.Normal, Muted, mono: true));
                    stack.Children.Add(Text(T($"有效继承范围内 message 记录：{diagnosis.MessageCount}（非客户端轮数）", $"Message records in effective lineage: {diagnosis.MessageCount} (not client turns)"), 11, FontWeights.Normal, Muted));
                    stack.Children.Add(Button(T("预览并修复这一条", "Review and repair this chat"), false, () => RepairHistoryAsync(diagnosis), _busy));
                }
                content.Add(Panel(stack));
            }
        }
        if (_historyRecords.Count > 0)
        {
            content.Add(Text(T("修复记录与安全撤销", "Repair records and safe rollback"), 16, FontWeights.SemiBold, Ink));
            foreach (var record in _historyRecords)
                content.Add(Panel(Row(TextBlockPair(PreviewTitle(record.Title, record.ThreadId), $"{record.CreatedAt.ToLocalTime():g}\n{record.OldPath} → {record.NewPath}"), Button(T("检查并撤销", "Check & Revert"), false, () => RollbackHistoryAsync(record), _busy))));
        }
        return Page(T("对话诊断与修复", "Chat Diagnosis & Repair"), T("针对原始 JSONL 仍在、但主入口停留旧分支导致后续消息不显示的分页对话。", "For paginated chats whose JSONL exists but the main entrypoint still points to an older branch."), content.ToArray());
    }

    private UIElement PreviewList()
    {
        var s = new StackPanel();
        s.Children.Add(Text(T("预览", "Preview"), 16, FontWeights.SemiBold, Ink));
        if (_scan is not { HasRepairs: true } && _scan is not { HasWarnings: true }) { s.Children.Add(Empty("✓", T("当前没有待修复项", "No pending repairs"), T("侧边栏会话摘要状态正常。", "Sidebar conversation summaries look healthy."))); return s; }
        var rows = PreviewRows(_scan).Take(10).ToList();
        if (rows.Count == 0) s.Children.Add(Empty("◇", T("没有可预览的写入项", "No previewable writes"), T("确认后会先创建备份，再写入必要的侧边栏摘要数据。", "A backup is created before writing sidebar summary data.")));
        foreach (var row in rows) s.Children.Add(PreviewRow(row));
        var hidden = PreviewRows(_scan).Count - rows.Count;
        if (hidden > 0) s.Children.Add(Text(T($"还有 {hidden} 条记录未显示。", $"{hidden} more rows hidden."), 12, FontWeights.Normal, Muted));
        if (_scan.HasPaginatedReview)
            s.Children.Add(PaginatedWarningPanel());
        return s;
    }

    private UIElement PaginatedWarningPanel()
    {
        var s = new StackPanel();
        s.Children.Add(Text(T("分页 Provider 需人工确认", "Paginated Provider review required"), 15, FontWeights.SemiBold, Warn));
        s.Children.Add(Text(T("这些 rollout 的首行长度参与 history_base 字节边界计算。Windows 版会保护文件，不会把它们混入普通 Provider 修复。", "The first-line byte length participates in history_base offsets. Windows protects these files and keeps them out of ordinary Provider repairs."), 12, FontWeights.Normal, Muted));
        foreach (var warning in (_scan?.PaginatedProviderWarnings ?? []).Take(5))
        {
            var title = PreviewTitle(warning.Title, warning.ThreadId);
            s.Children.Add(TextBlockPair(title, $"{warning.CurrentProvider} -> {warning.TargetProvider}\n{Path.GetFileName(warning.RolloutPath)}"));
        }
        if ((_scan?.PaginatedProviderWarnings.Count ?? 0) > 5)
            s.Children.Add(Text(T($"还有 {(_scan?.PaginatedProviderWarnings.Count ?? 0) - 5} 个风险项未显示。", $"{(_scan?.PaginatedProviderWarnings.Count ?? 0) - 5} more warnings hidden."), 12, FontWeights.Normal, Muted));
        foreach (var diagnostic in (_scan?.PaginatedProviderDiagnostics ?? []).Take(5))
        {
            var detail = Text(diagnostic, 12, FontWeights.Normal, Warn, mono: true);
            detail.TextWrapping = TextWrapping.Wrap;
            s.Children.Add(detail);
        }
        if ((_scan?.PaginatedProviderRepairs.Count ?? 0) > 0)
        {
            s.Children.Add(Divider());
            s.Children.Add(Text(T("可安全重算分页偏移", "Validated paginated repairs"), 14, FontWeights.SemiBold, Blue));
            foreach (var repair in _scan!.PaginatedProviderRepairs)
            {
                var grid = new Grid { Margin = new Thickness(0, 8, 0, 0) };
                grid.ColumnDefinitions.Add(new ColumnDefinition());
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var detail = TextBlockPair(PreviewTitle(repair.Title, repair.ThreadId), $"{repair.RolloutRepairs.Count} rollout · {repair.TurnOffsetRepairs.Count} turn · {repair.ProjectionOffsetRepairs.Count} projection");
                AddTo(grid, detail, 0);
                AddTo(grid, Button(T("预览并修复", "Review & Repair"), false, () => RepairPaginatedAsync(repair), _busy), 1);
                s.Children.Add(grid);
            }
        }
        return s;
    }

    private UIElement BuildBackups()
    {
        var s = new StackPanel();
        s.Children.Add(Row(Text(T("本地备份", "Local Backups"), 16, FontWeights.SemiBold, Ink), Button(T("刷新", "Refresh"), false, async () => await RefreshBackupsAsync(), _busy || _loadingBackups), Button(T("打开备份目录", "Open Folder"), false, () => OpenExistingBackupFolder(RepairService.BackupRoot(_settings.CodexHome)))));
        s.Children.Add(Button(T("打开已删除备份", "Open Deleted Backups"), false, () => OpenExistingBackupFolder(BackupManagementService.DeletedRoot(_settings.CodexHome))));
        if (_loadingBackups) s.Children.Add(UpdateText(T("正在读取备份…", "Reading backups…"), Muted));
        foreach (var warning in _backupWarnings) s.Children.Add(UpdateText(warning, Warn));
        if (!_loadingBackups && _managedBackups.Count == 0) s.Children.Add(Empty("⊞", T("暂无可管理的备份", "No manageable backups"), T("相应备份或修复操作会创建备份；无法识别的目录会显示警告，不允许自动删除。", "Backups are created by backup/repair operations. Unrecognized directories are reported and cannot be deleted automatically.")));
        foreach (var item in _managedBackups)
        {
            var row = new StackPanel();
            row.Children.Add(UpdateText($"{(item.IsHistory ? T("对话修复备份", "Chat Repair Backup") : T("普通备份", "Ordinary Backup"))} · {item.CreatedAt.ToLocalTime():g}\n{item.Title}\n{item.Directory}", Ink));
            row.Children.Add(Row(
                Button(item.IsHistory ? T("前往对话修复", "Open Chat Repair") : T("恢复此备份", "Restore"), false, () =>
                {
                    if (item.IsHistory) { _section = UiSection.History; UpdateNav(); TryShowCurrent(false); }
                    else
                    {
                        try
                        {
                            var backup = System.Text.Json.JsonSerializer.Deserialize<BackupRecord>(item.RecordJson, JsonOptions.Pretty)
                                ?? throw new IOException(T("备份记录无效。", "Invalid backup record."));
                            RestoreAsync(backup);
                        }
                        catch (Exception ex) { Notice(T("无法恢复", "Cannot Restore"), ex.Message, Warn); }
                    }
                }, _busy),
                Button(T("删除备份…", "Delete Backup…"), false, () => DeleteBackupAsync(item), _busy || _loadingBackups)));
            s.Children.Add(Panel(row));
        }
        return Page(T("备份", "Backups"), T("删除会移到当前 Codex Home 下的 codex-synced-deleted-backups，不永久擦除；可移回原路径后刷新恢复。恢复前需退出 Codex。", "Deletion moves backups to codex-synced-deleted-backups under the current Codex Home, without erasing them. Move them back to their original paths and refresh to recover. Quit Codex before restore."), Panel(s));
    }

    private void OpenExistingBackupFolder(string path)
    {
        try
        {
            if (!Directory.Exists(path)) throw new IOException(T("目录尚不存在；完成相应备份、修复或删除后才会创建。", "This folder does not exist yet; a backup, repair or deletion creates it."));
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
            if (_section == UiSection.History) _historyMessage = T("已打开：", "Opened: ") + path;
        }
        catch (Exception ex)
        {
            if (_section == UiSection.History) _historyMessage = ex.Message + "\n" + path;
            Notice(T("未打开目录", "Folder Not Opened"), ex.Message + "\n" + path, Warn);
        }
        TryShowCurrent(false);
    }

    private async Task RefreshBackupsAsync()
    {
        if (_loadingBackups) return;
        _loadingBackups = true;
        var home = _settings.CodexHome;
        if (_section == UiSection.Backups) TryShowCurrent(false);
        try
        {
            var inventory = await Task.Run(() => new BackupManagementService().Inventory(home));
            if (home != _settings.CodexHome) return;
            _managedBackups = inventory.Items;
            _backupWarnings = inventory.Warnings;
        }
        catch (Exception ex) { _backupWarnings = [ex.Message]; }
        finally { _loadingBackups = false; if (_section == UiSection.Backups) TryShowCurrent(false); }
    }

    private async void DeleteBackupAsync(ManagedBackup item)
    {
        if (_busy) return;
        if (System.Windows.MessageBox.Show(this,
            item.Directory + "\n\n" + T("只移动这份备份到已删除备份目录，不修改当前会话。移走后无法直接恢复或撤销对应修复。需要恢复时，将文件夹移回上述原路径并刷新。继续吗？", "Move only this backup to the deleted-backup directory. Live chats are unchanged. Restore/rollback will be unavailable until you move the folder back to the original path above and refresh. Continue?"),
            T("确认删除备份", "Confirm Backup Deletion"), MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        var home = _settings.CodexHome;
        SetBusy(T("正在移动备份", "Moving Backup"), item.Directory, .5);
        try
        {
            var destination = await Task.Run(() => new BackupManagementService().Delete(item, home));
            _scan?.Backups.RemoveAll(backup => backup.Path == item.Directory);
            _historyRecords.RemoveAll(record => record.Directory == item.Directory);
            _busy = false;
            await RefreshBackupsAsync();
            Notice(T("备份已移走，可恢复", "Backup Removed, Recoverable"), destination, Ok);
        }
        catch (Exception ex) { _busy = false; TryShowCurrent(false); Notice(T("删除失败", "Deletion Failed"), ex.Message, Warn); }
    }

    private UIElement BuildSettings()
    {
        var s = new StackPanel();
        s.Children.Add(SettingsRow(T("界面语言", "Language"), LanguageSwitch()));
        s.Children.Add(Divider());
        s.Children.Add(PathRow("Codex Home", _settings.CodexHome, p => { _settings.CodexHome = p; ResetHistorySelection(); _ = ScanAsync(); }));
        s.Children.Add(Divider());
        s.Children.Add(PathRow("SQLite Home", _settings.SqliteHome ?? _settings.CodexHome, p => { _settings.SqliteHome = p; ResetHistorySelection(); _ = ScanAsync(); }));
        s.Children.Add(Divider());
        s.Children.Add(SettingsRow(T("默认备份模式", "Default Backup"), ModeSwitch()));
        s.Children.Add(Divider());
        s.Children.Add(Counter(T("轻量备份最大数量", "Lightweight Limit"), () => _settings.LightweightLimit, v => _settings.LightweightLimit = v, 1, 30));
        s.Children.Add(Divider());
        s.Children.Add(Counter(T("全量备份最大数量", "Full Limit"), () => _settings.FullLimit, v => _settings.FullLimit = v, 1, 12));
        s.Children.Add(Divider());
        s.Children.Add(TwoCol(
            TextBlockPair(T("跨 Provider 显示历史", "Cross-provider history visibility"), T("切到 custom/openai_http 后，将可恢复本地会话对齐到当前 Provider。", "When switching to custom/openai_http, align recoverable local threads to the active provider.")),
            Toggle(_settings.AlignProvidersForVisibility, v => { _settings.AlignProvidersForVisibility = v; Show(BuildSettings(), false); _ = ScanAsync(); })));
        s.Children.Add(Divider());
        s.Children.Add(ToggleRow());
        s.Children.Add(Button(T("保存设置", "Save Settings"), true, SaveSettings));
        return Page(T("设置", "Settings"), T("保留最少必要配置，避免把工具做成数据库管理器。", "Only the necessary settings for this repair tool."), Panel(s), BuildSoftwareUpdate());
    }

    private UIElement BuildSoftwareUpdate()
    {
        var panel = new StackPanel();
        panel.Children.Add(Text(T("应用更新", "Software Update"), 16, FontWeights.SemiBold, Ink));
        panel.Children.Add(Text(T($"当前版本：{AppVersion}", $"Current version: {AppVersion}"), 13, FontWeights.Normal, Ink));
        panel.Children.Add(TwoCol(UpdateText(T("启动时检查更新（不下载）", "Check on launch (no download)"), Ink),
            Toggle(_settings.CheckForUpdatesOnLaunch, value =>
            {
                var previous = _settings.CheckForUpdatesOnLaunch;
                try { _settings.CheckForUpdatesOnLaunch = value; _settings.Save(); }
                catch (Exception ex) { _settings.CheckForUpdatesOnLaunch = previous; _updateError = ex.Message; }
                TryShowCurrent(false);
            })));
        panel.Children.Add(Text(T("来源：haohaomin/codex-session-synced · GitHub 稳定发布", "Source: haohaomin/codex-session-synced · GitHub stable releases"), 12, FontWeights.Normal, Muted));
        panel.Children.Add(Button(T(_checkingUpdate ? "正在检查…" : "检查更新", _checkingUpdate ? "Checking…" : "Check for Updates"), false,
            async () => await CheckForUpdatesAsync(manual: true), _checkingUpdate));
        if (_updateCandidate is { } candidate)
        {
            panel.Children.Add(Text(T($"发现新版本：{candidate.Version}", $"New version: {candidate.Version}"), 14, FontWeights.SemiBold, Blue));
            if (candidate.Notes.Length > 0)
                panel.Children.Add(new ScrollViewer { MaxHeight = 180, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    Content = UpdateText(candidate.Notes, Ink) });
            panel.Children.Add(Button(T("打开下载页面", "Open Download Page"), false, OpenUpdatePage, _busy));
        }
        else if (_updateCheckedAt is not null)
            panel.Children.Add(Text(T("没有更新的稳定版本。", "No newer stable release is available."), 13, FontWeights.Normal, Ink));
        if (_updateCheckedAt is { } date)
            panel.Children.Add(Text(T($"检查时间：{date:g}", $"Checked: {date:g}"), 12, FontWeights.Normal, Muted));
        if (_updateError is not null)
            panel.Children.Add(UpdateText(T("更新检查或设置失败：", "Update check or settings failed: ") + _updateError, Warn));
        panel.Children.Add(UpdateText(T("当前仅检查版本并打开下载页，不自动安装。发布包尚无独立更新签名；请手动安装，并保留旧应用与备份。不会修改 Codex 对话或配置。", "Checks versions and opens the download page only; no automatic installation. Packages do not yet have independent updater signatures. Install manually and keep the old app and backups. Codex chats and configuration are not modified."), Muted));
        return Panel(panel);
    }

    private static TextBlock UpdateText(string value, WpfBrush color)
    {
        var text = Text(value, 12, FontWeights.Normal, color);
        text.TextWrapping = TextWrapping.Wrap;
        text.TextTrimming = TextTrimming.None;
        text.Margin = new Thickness(0, 8, 0, 8);
        return text;
    }

    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (_checkingUpdate) return;
        _checkingUpdate = true;
        _updateCandidate = null;
        _updateError = null;
        _updateCheckedAt = null;
        if (_section == UiSection.Settings) TryShowCurrent(false);
        try
        {
            _updateCandidate = await SoftwareUpdateService.CheckAsync(AppVersion);
            _updateCheckedAt = DateTime.Now;
        }
        catch (Exception ex)
        {
            // Startup checks never interrupt a repair with an alert.
            if (manual) _updateError = ex.Message;
            else System.Diagnostics.Trace.TraceWarning("Software update check failed: {0}", ex.Message);
        }
        finally
        {
            _checkingUpdate = false;
            if (_section == UiSection.Settings) TryShowCurrent(false);
        }
    }

    private void OpenUpdatePage()
    {
        if (_busy || _updateCandidate is not { } candidate) return;
        if (System.Windows.MessageBox.Show(this,
            T("将打开此版本的发布页。MSI 安装用户选择 x64 MSI，便携版用户选择 ZIP 并解压到新目录，不要覆盖正在运行的文件。请先完成修复，正常退出 Codex Synced，并保留旧应用和备份。打开页面不代表安装成功；重启后检查版本。", "Open this version's release page. MSI users: choose x64 MSI. Portable users: extract ZIP into a new directory, never over running files. Finish repairs, quit Codex Synced normally and keep the old app and backups. Opening the page does not mean installation succeeded; verify the version after relaunch."),
            T("手动更新 Codex Synced", "Update Codex Synced Manually"), MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(candidate.PageUrl.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception ex) { _updateError = ex.Message; TryShowCurrent(false); }
    }

    private async Task ScanAsync()
    {
        _scanError = null;
        SetBusy(T("识别当前环境", "Detecting environment"), T("正在读取 config.toml、状态库和 Provider 设置。", "Reading config.toml, state database, and provider settings."), .16);
        try
        {
            SetBusy(T("扫描本地历史", "Scanning local history"), T("正在比对 SQLite、rollout 和 session_index。", "Comparing SQLite, rollout files, and session_index."), .42);
            _scan = await Task.Run(() => _service.Scan(SnapshotSettings()));
            SetBusy(T("整理修复预览", "Preparing repair preview"), T("正在生成备份和写入预览。", "Preparing backup and write preview."), .86);
            _busy = false;
            Show(CurrentView(), true);
        }
        catch (Exception ex) { _scanError = ex.Message; _busy = false; TryShowCurrent(true); Notice(T("扫描失败", "Scan Failed"), ex.Message, Warn); }
    }

    private async void ScanHistoryAsync()
    {
        if (_busy) return;
        _historyScanning = true;
        _historyScan = null;
        _historyMessage = null;
        var captured = SnapshotSettings();
        SetBusy(T("扫描对话入口", "Scanning chat entrypoints"), T("沿 history_base 检查唯一后继链、序号和字节边界。", "Following history_base and checking unique lineage, ordinals, and byte boundaries."), .36);
        try
        {
            var result = await Task.Run(() => _historyService.Scan(captured));
            if (captured.CodexHome != _settings.CodexHome || captured.SqliteHome != _settings.SqliteHome || captured.HistoryDatabase != _settings.HistoryDatabase)
                throw new InvalidOperationException(T("目录或状态库选择已变化，请重新扫描。", "Directories or selected database changed; scan again."));
            _historyScan = result;
            _historyMessage = T($"扫描完成：检查了 {result.Diagnoses.Count} 个分页对话，{result.Diagnoses.Count(item => item.CanRepair)} 个入口可修复。", $"Scan complete: {result.Diagnoses.Count} paginated chats checked; {result.Diagnoses.Count(item => item.CanRepair)} entrypoints can be repaired.");
            _busy = false;
        }
        catch (Exception ex)
        {
            _busy = false;
            _historyMessage = ex.Message;
            Notice(T("对话扫描失败", "Chat scan failed"), ex.Message, Warn);
        }
        finally { _historyScanning = false; TryShowCurrent(true); }
    }

    private void ResetHistorySelection()
    {
        _settings.HistoryDatabase = null;
        _historyScan = null;
        _historyMessage = null;
        _historyRecords = [];
        _managedBackups = [];
        _backupWarnings = [];
    }

    private async void RepairHistoryAsync(HistoryDiagnosis diagnosis)
    {
        if (_historyScan is null || !diagnosis.CanRepair || _busy)
            return;
        if (System.Windows.MessageBox.Show(T("将先备份含 WAL 的状态库与原始分支文件，只修改这一条 rollout_path。继续吗？", "A WAL-consistent state backup and original branch copies will be created. Only this rollout_path will change. Continue?"), T("确认最小入口修复", "Confirm minimal entrypoint repair"), MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
            return;
        SetBusy(T("备份并修复对话入口", "Backing up and repairing entrypoint"), T("正在副本试写并复核文件哈希。", "Trialing the database copy and checking file hashes."), .48);
        try
        {
            await Task.Run(() => _historyService.Repair(_historyScan, diagnosis, SnapshotSettings()));
            _historyScan = await Task.Run(() => _historyService.Scan(SnapshotSettings()));
            _historyRecords = await Task.Run(() => _historyService.Records(SnapshotSettings()));
            Notice(T("入口修复完成", "Entrypoint repair complete"), T("只修改了 rollout_path。请重新打开并重启 Codex，逐条核对正文、遗漏、重复和项目归属。", "Only rollout_path changed. Reopen and restart Codex, then verify message order, omissions, duplicates, and project ownership."), Ok);
            _busy = false;
            Show(CurrentView(), true);
        }
        catch (Exception ex)
        {
            _busy = false;
            TryShowCurrent(true);
            Notice(T("入口修复失败", "Entrypoint repair failed"), ex.Message, Warn);
        }
    }

    private async void RollbackHistoryAsync(HistoryRepairRecord record)
    {
        if (_busy || System.Windows.MessageBox.Show(T("只在目标记录和文件未变化时撤销入口修改。继续吗？", "Rollback only if metadata and files are unchanged. Continue?"), T("确认安全撤销", "Confirm safe rollback"), MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
            return;
        SetBusy(T("检查并撤销入口", "Checking and rolling back entrypoint"), T("不会恢复整库，也不会覆盖新消息。", "The whole database will not be restored and new messages will not be overwritten."), .42);
        try
        {
            await Task.Run(() => _historyService.Rollback(record, SnapshotSettings()));
            _historyScan = await Task.Run(() => _historyService.Scan(SnapshotSettings()));
            _historyRecords = await Task.Run(() => _historyService.Records(SnapshotSettings()));
            Notice(T("入口已撤销", "Entrypoint rolled back"), T("已恢复这一条 rollout_path。", "This rollout_path was restored."), Ok);
            _busy = false;
            Show(CurrentView(), true);
        }
        catch (Exception ex)
        {
            _busy = false;
            TryShowCurrent(true);
            Notice(T("撤销失败", "Rollback failed"), ex.Message, Warn);
        }
    }

    private void TryShowCurrent(bool animate)
    {
        try
        {
            Show(CurrentView(), animate);
        }
        catch (Exception ex)
        {
            _scanError = ex.Message;
            Show(BuildFallbackPage(T("界面加载失败", "View Failed"), ex.Message), false);
        }
    }

    private ScrollViewer BuildFallbackPage(string title, string message) =>
        Page(title, T("应用仍在运行，你可以重新扫描或到设置里检查目录。", "The app is still running. Scan again or check folders in Settings."),
            Panel(TextBlockPair(title, message)));

    private AppSettings SnapshotSettings() => new()
    {
        CodexHome = _settings.CodexHome,
        SqliteHome = _settings.SqliteHome,
        HistoryDatabase = _settings.HistoryDatabase,
        DefaultBackupMode = _settings.DefaultBackupMode,
        LightweightLimit = _settings.LightweightLimit,
        FullLimit = _settings.FullLimit,
        OpenCodexAfterRepair = _settings.OpenCodexAfterRepair,
        AlignProvidersForVisibility = _settings.AlignProvidersForVisibility
    };

    private async void RepairAsync()
    {
        if (_scan is null || !_scan.HasRepairs) { Notice(T("当前没有待修复项", "No Pending Repairs"), T("侧边栏会话摘要状态正常。", "Sidebar conversation summaries look healthy."), Ok); return; }
        if (System.Windows.MessageBox.Show(T($"即将创建备份并修复 {_scan.PendingCount} 项。继续吗？", $"A backup will be created and {_scan.PendingCount} items repaired. Continue?"), "Codex Synced", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        SetBusy(T("备份并修复", "Backing up and repairing"), T("正在创建备份并写入 SQLite、rollout 和索引。", "Creating backup and writing SQLite, rollout, and index changes."), .48);
        try { var scan = _scan; await Task.Run(() => _service.Repair(scan, SnapshotSettings(), _backupMode)); Notice(T("修复完成", "Repair Complete"), T("侧边栏会话摘要已经修复。", "Sidebar conversation summaries were repaired."), Ok); await ScanAsync(); if (_settings.OpenCodexAfterRepair) RepairService.OpenCodex(); }
        catch (Exception ex) { _busy = false; TryShowCurrent(true); Notice(T("修复失败", "Repair Failed"), ex.Message, Warn); }
    }

    private async void RepairPaginatedAsync(PaginatedProviderRepair repair)
    {
        if (_busy)
            return;
        var message = T(
            $"将先备份状态库、历史库和相关 rollout，再同步改写 {repair.RolloutRepairs.Count} 个分页首行、{repair.TurnOffsetRepairs.Count} 个 turn 偏移和 {repair.ProjectionOffsetRepairs.Count} 个 projection 偏移。不会拼接正文。继续吗？",
            $"This will back up the state/history databases and rollouts, then update {repair.RolloutRepairs.Count} paginated headers, {repair.TurnOffsetRepairs.Count} turn offsets, and {repair.ProjectionOffsetRepairs.Count} projection offsets. Bodies are never concatenated. Continue?");
        if (System.Windows.MessageBox.Show(message, T("确认分页修复", "Confirm paginated repair"), MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
            return;
        SetBusy(T("备份并修复分页 Provider", "Backing up and repairing paginated Provider"), T("正在试写副本并校验 SQLite、字节边界和正文哈希。", "Trialing database and rollout copies, then checking offsets and body hashes."), .48);
        try
        {
            var scan = _scan!;
            await Task.Run(() => _service.RepairPaginated(scan, repair, SnapshotSettings(), _backupMode));
            Notice(T("分页修复完成", "Paginated repair complete"), T("已同步 Provider、history_base、turn 偏移和 projection。重新打开并重启 Codex 后仍需人工核对正文。", "Provider, history_base, turn offsets, and projection are synchronized. Reopen and restart Codex, then manually verify message content."), Ok);
            await ScanAsync();
        }
        catch (Exception ex)
        {
            _busy = false;
            TryShowCurrent(true);
            Notice(T("分页修复失败", "Paginated repair failed"), ex.Message, Warn);
        }
    }

    private async void RestoreAsync(BackupRecord backup)
    {
        if (System.Windows.MessageBox.Show(T($"将恢复备份 {backup.DirectoryName}。请确认 Codex 已退出。", $"Restore backup {backup.DirectoryName}. Make sure Codex is closed."), "Codex Synced", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        SetBusy(T("恢复备份", "Restoring backup"), T("正在还原 SQLite、session_index 和 rollout metadata。", "Restoring SQLite, session_index, and rollout metadata."), .32);
        try { await Task.Run(() => _service.Restore(backup)); Notice(T("备份恢复完成", "Backup Restored"), T("本地历史已经恢复到所选备份。", "Local history was restored from the selected backup."), Ok); await ScanAsync(); }
        catch (Exception ex) { _busy = false; TryShowCurrent(true); Notice(T("恢复失败", "Restore Failed"), ex.Message, Warn); }
    }

    private void SetBusy(string title, string detail, double progress)
    {
        _busy = true;
        _busyTitle = title;
        _busyDetail = detail;
        _busyProgress = Math.Clamp(progress, 0, 1);
        TryShowCurrent(false);
    }

    private void SaveSettings() { _settings.DefaultBackupMode = _backupMode; _settings.Save(); Notice(T("设置已保存", "Settings Saved"), T("已保存到本机配置。", "Saved to local app settings."), Ok); _ = ScanAsync(); }
    private string StatusTitle() => _busy ? _busyTitle : _scanError is not null ? T("扫描失败", "Scan Failed") : _scan is null ? T("正在识别当前环境", "Detecting Environment") : _scan.HasRepairs ? T($"发现 {_scan.PendingCount} 项待处理", $"{_scan.PendingCount} Items Need Attention") : _scan.HasWarnings ? T($"发现 {_scan.PaginatedProviderWarnings.Count} 个分页风险", $"{_scan.PaginatedProviderWarnings.Count} Paginated Warnings") : T("侧边栏状态正常", "Sidebar Looks Healthy");
    private string StatusSubtitle() => _busy ? _busyDetail : _scanError is not null ? _scanError : _scan?.HasRepairs == true ? T("请查看待修复项，确认变更后执行备份并修复。", "Review pending changes, then create a backup and repair.") : _scan?.HasWarnings == true ? T("分页文件已被保护，未直接改写首行；请在待修复项中查看并人工确认。", "Paginated files are protected and their headers were not rewritten. Review them in Pending.") : T("已读取本地会话摘要。不会修改 Token、API Key、第三方 URL 或会话正文。", "Local conversation summaries are inspected. Tokens, keys, URLs, and message bodies are never changed.");

    private void Notice(string title, string message, WpfBrush color)
    {
        var notice = new Border
        {
            Width = 360,
            Padding = new Thickness(13),
            Background = WpfBrushes.White,
            BorderBrush = Alpha(color, .22),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Effect = Shadow(.10, 18, 8),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 20, 20),
            Opacity = 0,
            RenderTransform = new TranslateTransform(0, 22),
            Child = TextBlockPair(title, message)
        };
        Grid.SetColumn(notice, 1);
        _root.Children.Add(notice);
        Anim(notice, OpacityProperty, 0, 1, 180);
        Anim((TranslateTransform)notice.RenderTransform, TranslateTransform.YProperty, 22, 0, 220);
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3.2) };
        timer.Tick += (_, _) => { timer.Stop(); _root.Children.Remove(notice); };
        timer.Start();
    }

    private WpfButton Segment(string text, Action action)
    {
        var b = new WpfButton
        {
            Content = text,
            MinHeight = 30,
            Height = 30,
            MinWidth = 0,
            Margin = new Thickness(0),
            Padding = new Thickness(12, 0, 12, 0),
            Background = WpfBrushes.Transparent,
            Foreground = Muted,
            BorderBrush = WpfBrushes.Transparent,
            BorderThickness = new Thickness(1),
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            Cursor = WpfCursors.Hand,
            Template = ButtonTemplate(8)
        };
        b.Click += (_, _) => action();
        return b;
    }
    private WpfButton Button(string text, bool primary, Action action, bool disabled = false) { var b = StyledButton(text, primary); b.IsEnabled = !disabled; b.Click += (_, _) => action(); return b; }
    private WpfButton Button(string text, bool primary, Func<Task> action, bool disabled = false) { var b = StyledButton(text, primary); b.IsEnabled = !disabled; b.Click += async (_, _) => await action(); return b; }

    private static WpfButton StyledButton(string text, bool primary)
    {
        var b = new WpfButton { Content = text, MinHeight = primary ? 36 : 34, MinWidth = primary ? 120 : 92, Margin = new Thickness(0, 0, 10, 0), Padding = new Thickness(primary ? 16 : 14, 0, primary ? 16 : 14, 0), Background = primary ? Blue : Subtle, Foreground = primary ? WpfBrushes.White : Ink, BorderBrush = primary ? Blue : Line, BorderThickness = new Thickness(1), FontSize = 14, FontWeight = primary ? FontWeights.SemiBold : FontWeights.Medium, Cursor = WpfCursors.Hand, RenderTransformOrigin = new WpfPoint(.5, .5), RenderTransform = new ScaleTransform(1, 1), Template = ButtonTemplate(8) };
        b.MouseEnter += (_, _) => { if (!b.IsEnabled) return; b.Background = primary ? Brush("#126CF2") : WpfBrushes.White; b.Foreground = primary ? WpfBrushes.White : Blue; Scale(b, 1.006); };
        b.MouseLeave += (_, _) => { b.Background = primary ? Blue : Subtle; b.Foreground = primary ? WpfBrushes.White : Ink; Scale(b, 1); };
        b.PreviewMouseDown += (_, _) => Scale(b, .94);
        b.PreviewMouseUp += (_, _) => Scale(b, 1.006);
        return b;
    }

    private static ControlTemplate ButtonTemplate(double radius)
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetBinding(Border.BackgroundProperty, new WpfBinding("Background") { RelativeSource = RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderBrushProperty, new WpfBinding("BorderBrush") { RelativeSource = RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderThicknessProperty, new WpfBinding("BorderThickness") { RelativeSource = RelativeSource.TemplatedParent });
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, System.Windows.HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        content.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(WpfControl.PaddingProperty));
        content.SetValue(TextElement.ForegroundProperty, new TemplateBindingExtension(WpfControl.ForegroundProperty));
        border.AppendChild(content);
        return new ControlTemplate(typeof(WpfButton)) { VisualTree = border };
    }

    private Border ModeSwitch()
    {
        _modeButtons.Clear();
        var grid = new UniformGrid { Columns = 2 };
        var light = Segment(ModeTitle(BackupMode.Lightweight), () => { _backupMode = BackupMode.Lightweight; _settings.DefaultBackupMode = _backupMode; Show(CurrentView(), false); });
        var full = Segment(ModeTitle(BackupMode.Full), () => { _backupMode = BackupMode.Full; _settings.DefaultBackupMode = _backupMode; Show(CurrentView(), false); });
        _modeButtons[light] = BackupMode.Lightweight; _modeButtons[full] = BackupMode.Full;
        grid.Children.Add(light); grid.Children.Add(full);
        var box = Shell(grid, 8, 3); box.Width = 240;
        UpdateSegments(_modeButtons.ToDictionary(x => x.Key, x => x.Value == _backupMode));
        return box;
    }

    private UIElement SettingsRow(string title, UIElement control) => TwoCol(Text(title, 14, FontWeights.Normal, Ink), control);
    private UIElement ToggleRow() => TwoCol(Text(T("修复完成后自动打开 Codex", "Open Codex after repair"), 14, FontWeights.Normal, Ink), Toggle(_settings.OpenCodexAfterRepair, v => { _settings.OpenCodexAfterRepair = v; Show(BuildSettings(), false); }));
    private UIElement Counter(string title, Func<int> get, Action<int> set, int min, int max) => TwoCol(Text(title, 14, FontWeights.Normal, Ink), Stepper(get, () => { set(Math.Clamp(get() - 1, min, max)); Show(BuildSettings(), false); }, () => { set(Math.Clamp(get() + 1, min, max)); Show(BuildSettings(), false); }));

    private UIElement PathRow(string title, string path, Action<string> choose)
    {
        var value = Text(path, 12, FontWeights.Normal, Muted, mono: true);
        value.TextAlignment = TextAlignment.Right;
        value.MaxWidth = 420;
        var button = Button(T("选择", "Choose"), false, () => { var dialog = new Microsoft.Win32.OpenFolderDialog { InitialDirectory = Directory.Exists(path) ? path : _settings.CodexHome, Title = title }; if (dialog.ShowDialog(this) == true) choose(dialog.FolderName); });
        return ThreeCol(Text(title, 14, FontWeights.Normal, Ink), value, button);
    }

    private static Grid Stepper(Func<int> get, Action decrement, Action increment)
    {
        var grid = new Grid { Width = 188, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(84) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        AddTo(grid, SmallButton("-", decrement), 0);
        var value = Text(get().ToString(), 14, FontWeights.SemiBold, Ink, center: true);
        value.FontFamily = new WpfFontFamily("Cascadia Mono, Consolas, Microsoft YaHei UI");
        AddTo(grid, value, 1);
        AddTo(grid, SmallButton("+", increment), 2);
        return grid;
    }

    private static WpfButton SmallButton(string text, Action action)
    {
        var b = StyledButton(text, false);
        b.MinWidth = 44;
        b.Width = 44;
        b.Height = 34;
        b.Margin = new Thickness(4, 0, 4, 0);
        b.Click += (_, _) => action();
        return b;
    }

    private sealed record PreviewItem(string Kind, string Icon, string Title, string Detail);

    private List<PreviewItem> PreviewRows(ScanResult scan)
    {
        var rows = new List<PreviewItem>();
        rows.AddRange(scan.SqliteProviderUpdates.Select(repair => new PreviewItem(_settings.AlignProvidersForVisibility ? T("Provider 对齐", "Provider Align") : "Provider", "▦", PreviewTitle(repair.Thread.Title, repair.Thread.Id), $"{repair.Thread.ModelProvider} -> {repair.TargetProvider}")));
        rows.AddRange(scan.RolloutRepairs.Select(repair => new PreviewItem(T("rollout Provider", "Rollout Provider"), "▣", PreviewTitle(repair.SessionId, Path.GetFileName(repair.Path)), $"{repair.CurrentProvider ?? "nil"} -> {repair.TargetProvider}")));
        rows.AddRange(scan.PaginatedProviderWarnings.Select(warning => new PreviewItem(T("分页 Provider 风险", "Paginated Provider review"), "!", PreviewTitle(warning.Title, warning.ThreadId), $"{warning.CurrentProvider} -> {warning.TargetProvider} · {Path.GetFileName(warning.RolloutPath)}")));
        rows.AddRange(scan.PaginatedProviderRepairs.Select(repair => new PreviewItem(T("分页 Provider 可修复", "Paginated Provider ready"), "↻", PreviewTitle(repair.Title, repair.ThreadId), $"{repair.RolloutRepairs.Count} rollout · {repair.TurnOffsetRepairs.Count} turn · {repair.ProjectionOffsetRepairs.Count} projection")));
        rows.AddRange(scan.SqliteTitleRepairs.Select(repair => new PreviewItem(T("标题", "Title"), "T", PreviewTitle(repair.TargetTitle, repair.ThreadId), PreviewTitle(repair.CurrentTitle, T("空标题", "empty title")))));
        rows.AddRange(scan.SqliteTimestampRepairs.Select(repair => new PreviewItem(T("时间", "Time"), "◷", PreviewTitle(repair.Title, repair.ThreadId), $"{repair.CurrentUpdatedAtMs} -> {repair.TargetUpdatedAtMs}")));
        rows.AddRange(scan.RolloutMtimeRepairs.Select(repair => new PreviewItem("mtime", "◴", PreviewTitle(repair.Title, repair.ThreadId), $"{repair.CurrentMtimeMs} -> {repair.TargetMtimeMs}")));
        if (scan.IndexRepairs.Count > 0)
            rows.Add(new(T("索引", "Index"), "≡", T("重建 session_index.jsonl", "Rebuild session_index.jsonl"), T($"{scan.IndexRepairs.Count} 条会话", $"{scan.IndexRepairs.Count} threads")));
        rows.AddRange((scan.GlobalStateRepair?.Changes ?? []).Select(change => new PreviewItem(T("UI 状态", "UI State"), "▤", change, ".codex-global-state.json")));
        return rows;
    }

    private Border PreviewRow(PreviewItem item)
    {
        var grid = new Grid { Margin = new Thickness(0, 8, 0, 0), MinHeight = 36 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(SoftIcon(item.Icon, Blue));
        AddTo(grid, TextBlockPair(item.Title, item.Detail), 1);
        AddTo(grid, Text(item.Kind, 12, FontWeights.Normal, Muted, mono: true), 2);
        return new Border { Padding = new Thickness(10), Background = Subtle, BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = grid };
    }

    private static string PreviewTitle(string value, string fallback)
    {
        var title = value
            .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault();
        return string.IsNullOrWhiteSpace(title) ? fallback : title;
    }

    private Border BackupRow(BackupRecord backup)
    {
        var grid = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(SoftIcon(backup.Mode == BackupMode.Full ? "■" : "□", Blue));
        AddTo(grid, TextBlockPair(ShortDate(backup.CreatedAt), $"{ModeTitle(backup.Mode)} · Provider {backup.TargetProvider} · {FileSize(backup.SizeBytes)}\nSQLite {backup.Summary.SqliteProviderUpdates} · Rollout {backup.Summary.RolloutUpdates} · Index {backup.Summary.IndexInsertions}"), 1);
        AddTo(grid, Button(T("恢复此备份", "Restore"), false, () => RestoreAsync(backup)), 2);
        return new Border { Padding = new Thickness(12), Background = Subtle, BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = grid };
    }

    private static UIElement Summary(params (string Title, string Value)[] rows) { var s = new StackPanel(); foreach (var row in rows) { s.Children.Add(TwoCol(Text(row.Title, 14, FontWeights.Normal, Muted), Text(row.Value, 14, FontWeights.SemiBold, Ink))); s.Children.Add(Divider()); } return s; }
    private static Border Metric(string title, int value, string caption) { var s = TextBlockPair(title, value.ToString(), caption); var p = Panel(s); p.Margin = new Thickness(0, 0, 10, 0); return p; }
    private static StackPanel TextBlockPair(string title, string detail, string? third = null, bool mono = false) { var s = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; s.Children.Add(Text(title, 14, FontWeights.SemiBold, Ink)); s.Children.Add(Text(detail, 12, FontWeights.Normal, Muted, mono)); if (third is not null) s.Children.Add(Text(third, 12, FontWeights.Normal, Muted)); return s; }
    private static StackPanel Flow(params UIElement[] children) { var s = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 0) }; foreach (var child in children) s.Children.Add(child); return s; }
    private static Grid Row(params UIElement[] children) { var s = new Grid(); for (var i = 0; i < children.Length; i++) { s.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 0 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto }); AddTo(s, children[i], i); } return s; }
    private static UIElement TwoCol(UIElement left, UIElement right) => ThreeCol(left, new Border(), right);
    private static Grid ThreeCol(UIElement left, UIElement center, UIElement right) { var g = new Grid { Margin = new Thickness(0, 10, 0, 10), MinHeight = 38 }; g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) }); g.ColumnDefinitions.Add(new ColumnDefinition()); g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); AddTo(g, left, 0); AddTo(g, center, 1); AddTo(g, right, 2); return g; }
    private static void AddTo(Grid grid, UIElement child, int column) { Grid.SetColumn(child, column); grid.Children.Add(child); }
    private static Border Panel(UIElement child) => new() { Padding = new Thickness(18), Background = WpfBrushes.White, BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Effect = Shadow(.045, 10, 3), Child = child };
    private static Border Shell(UIElement child, double radius, double padding) => new() { Padding = new Thickness(padding), Background = WpfBrushes.White, BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(Math.Min(radius, 8)), Child = child };
    private static Border Divider() => new() { Height = 1, Background = Line, Margin = new Thickness(0, 10, 0, 10) };
    private static UIElement Info(string title, string value) { var s = new StackPanel(); s.Children.Add(Text(title, 12, FontWeights.Medium, Muted)); s.Children.Add(Text(value, 13, FontWeights.Normal, Ink, mono: true)); return s; }
    private static Border Pill(string text, WpfBrush color) => new() { Background = Alpha(color, .08), BorderBrush = Alpha(color, .16), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 0, 5), Child = Text(text, 12, FontWeights.Medium, color == Muted ? Ink : color) };
    private static Border SoftIcon(string text, WpfBrush color) => new() { Width = 32, Height = 32, CornerRadius = new CornerRadius(8), Background = Alpha(color, .10), Child = Text(text, 15, FontWeights.SemiBold, color, center: true), VerticalAlignment = VerticalAlignment.Center };
    private static Border Empty(string icon, string title, string message) { var s = new StackPanel { Margin = new Thickness(0, 14, 0, 0) }; s.Children.Add(SoftIcon(icon, Blue)); s.Children.Add(Text(title, 16, FontWeights.SemiBold, Ink)); var msg = Text(message, 13, FontWeights.Normal, Muted); msg.TextWrapping = TextWrapping.Wrap; s.Children.Add(msg); return new Border { Child = s }; }
    private static Border Toggle(bool on, Action<bool> changed) { var shell = new Border { Width = 46, Height = 24, CornerRadius = new CornerRadius(12), Background = on ? Blue : Brush("#14000000"), Cursor = WpfCursors.Hand }; shell.Child = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = WpfBrushes.White, HorizontalAlignment = on ? System.Windows.HorizontalAlignment.Right : System.Windows.HorizontalAlignment.Left, Margin = new Thickness(3), Effect = Shadow(.12, 4, 1) }; shell.MouseLeftButtonUp += (_, _) => changed(!on); return shell; }
    private Border BusyProgress(WpfBrush color)
    {
        var s = new StackPanel();
        s.Children.Add(TwoCol(
            Text(_busyTitle, 12, FontWeights.SemiBold, Ink),
            Text($"{Math.Round(_busyProgress * 100):0}%", 12, FontWeights.SemiBold, color, center: true)));
        var bar = new WpfProgressBar
        {
            Minimum = 0,
            Maximum = 100,
            Value = _busyProgress * 100,
            Height = 7,
            Margin = new Thickness(0, 7, 0, 7),
            Foreground = color,
            Background = Alpha(color, .12),
            BorderBrush = WpfBrushes.Transparent
        };
        s.Children.Add(bar);
        var detail = Text(_busyDetail, 12, FontWeights.Normal, Muted);
        detail.TextWrapping = TextWrapping.Wrap;
        s.Children.Add(detail);
        return new Border { Padding = new Thickness(12), Background = Alpha(color, .07), BorderBrush = Alpha(color, .14), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = s };
    }
    private static Border Activity(WpfBrush color) { var bar = new Border { Height = 3, CornerRadius = new CornerRadius(2), Background = Alpha(color, .12), Margin = new Thickness(0, 14, 0, 0), ClipToBounds = true }; var glow = new Border { Width = 180, Background = Alpha(color, .65), RenderTransform = new TranslateTransform(-180, 0) }; bar.Child = glow; bar.Loaded += (_, _) => Anim((TranslateTransform)glow.RenderTransform, TranslateTransform.XProperty, -180, Math.Max(bar.ActualWidth, 360) + 180, 1050, true); return bar; }
    private static TextBlock Text(string text, double size, FontWeight weight, WpfBrush color, bool mono = false, bool center = false) => new() { Text = text, FontSize = size, FontWeight = weight, Foreground = color, FontFamily = mono ? new WpfFontFamily("Cascadia Mono, Consolas, Microsoft YaHei UI") : new WpfFontFamily("Microsoft YaHei UI, Segoe UI, Arial"), TextTrimming = TextTrimming.CharacterEllipsis, TextAlignment = center ? TextAlignment.Center : TextAlignment.Left, HorizontalAlignment = center ? System.Windows.HorizontalAlignment.Center : System.Windows.HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
    private static WpfBrush Brush(string hex) => (WpfBrush)new BrushConverter().ConvertFromString(hex)!;
    private static WpfBrush Alpha(WpfBrush brush, double opacity) { var c = ((SolidColorBrush)brush).Color; return new SolidColorBrush(WpfColor.FromArgb((byte)(opacity * 255), c.R, c.G, c.B)); }
    private static DropShadowEffect Shadow(double opacity, double blur, double depth) => new() { Color = WpfColor.FromRgb(25, 36, 56), Opacity = opacity, BlurRadius = blur, ShadowDepth = depth };
    private static void Lift(Border b, double y = 2) { b.RenderTransform = new TranslateTransform(); b.MouseEnter += (_, _) => Anim((TranslateTransform)b.RenderTransform, TranslateTransform.YProperty, 0, -y, 180); b.MouseLeave += (_, _) => Anim((TranslateTransform)b.RenderTransform, TranslateTransform.YProperty, -y, 0, 180); }
    private static void Scale(WpfButton b, double value) { if (b.RenderTransform is ScaleTransform s) { Anim(s, ScaleTransform.ScaleXProperty, s.ScaleX, value, 100); Anim(s, ScaleTransform.ScaleYProperty, s.ScaleY, value, 100); } }
    private static void Anim(DependencyObject target, DependencyProperty property, double from, double to, int ms, bool forever = false)
    {
        var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = new SineEase { EasingMode = EasingMode.EaseOut }, RepeatBehavior = forever ? RepeatBehavior.Forever : new RepeatBehavior(1) };
        if (target is UIElement element) element.BeginAnimation(property, a);
        else if (target is Animatable x) x.BeginAnimation(property, a);
    }
    private void UpdateLanguageSegments() => UpdateSegments(_languageButtons.ToDictionary(x => x.Key, x => x.Value == _language));
    private static void UpdateSegments(Dictionary<WpfButton, bool> states) { foreach (var (button, selected) in states) { button.Background = selected ? Blue : WpfBrushes.Transparent; button.Foreground = selected ? WpfBrushes.White : Muted; button.BorderBrush = WpfBrushes.Transparent; button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Medium; } }
    private void UpdateNav() { foreach (var button in _navButtons) { var selected = button.Tag is UiSection s && s == _section; button.Background = selected ? WpfBrushes.White : WpfBrushes.Transparent; button.Foreground = selected ? Ink : Muted; button.BorderBrush = selected ? Line : WpfBrushes.Transparent; button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal; button.Effect = selected ? Shadow(.08, 10, 5) : null; } }
    private string ModeTitle(BackupMode mode) => mode == BackupMode.Full ? T("全量备份", "Full") : T("轻量备份", "Lightweight");
    private static string ShortDate(DateTime date) => date.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    private static string FileSize(long bytes) { string[] units = ["B", "KB", "MB", "GB"]; var value = (double)bytes; var unit = 0; while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; } return $"{value:0.#} {units[unit]}"; }
}
