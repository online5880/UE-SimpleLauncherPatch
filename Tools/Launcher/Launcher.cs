// PatchGame Launcher - full-build updater, game-launcher style UI
// Single-file WinForms, .NET Framework 4.x. Build: Launcher\build.cmd
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--self-test")
        {
            string dir = Path.Combine(Path.GetTempPath(), "LauncherSelfTest_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "test.part");
            string meta = path + ".sha256";
            try
            {
                File.WriteAllBytes(path, Encoding.ASCII.GetBytes("abc"));
                string hash = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";
                File.WriteAllText(meta, hash);
                bool ok = LauncherForm.ComputeSha256(path) == hash &&
                    LauncherForm.PreparePartial(path, meta, hash, 3) == 3;

                string manifest = "$VERSION = 1.2.3\n$NUM_ENTRIES = 1\n" +
                    "Game.exe\t3\tSHA256:" + hash + "\n";
                ok = ok && LauncherForm.ParseFullManifest(manifest, "1.2.3").Count == 1;

                byte[] signedData = Encoding.UTF8.GetBytes("signed manifest");
                using (var rsa = new RSACryptoServiceProvider(1024))
                {
                    rsa.PersistKeyInCsp = false;
                    byte[] signature = rsa.SignData(signedData, CryptoConfig.MapNameToOID("SHA256"));
                    string publicKey = rsa.ToXmlString(false);
                    ok = ok && LauncherForm.VerifySignature(signedData, publicKey, signature);
                    signedData[0] ^= 1;
                    ok = ok && !LauncherForm.VerifySignature(signedData, publicKey, signature);
                }

                File.WriteAllText(meta, new string('0', 64));
                ok = ok && LauncherForm.PreparePartial(path, meta, hash, 3) == 0 &&
                    !File.Exists(path);
                Environment.ExitCode = ok ? 0 : 1;
            }
            finally { Directory.Delete(dir, true); }
            return;
        }

        if (args.Length > 0 && (args[0] == "/?" || args[0] == "-?" || args[0] == "--help"))
            return; // immediate-exit switch (headless verification)

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new LauncherForm(args.Length > 0 && args[0] == "--play"));
    }
}

class FullFileEntry
{
    public string Path;
    public long Size;
    public string Hash;
}

class LauncherForm : Form
{
    const int HttpTimeoutMs = 5000;
    const int UiTickMs = 200;
    const int ProgressLogMs = 5000;

    static readonly Color Bg = Color.FromArgb(16, 16, 22);
    static readonly Color PanelBg = Color.FromArgb(26, 26, 36);
    static readonly Color PanelBorder = Color.FromArgb(52, 52, 66);
    static readonly Color TitleText = Color.FromArgb(245, 245, 248);
    static readonly Color DimText = Color.FromArgb(150, 150, 162);
    static readonly Color Green = Color.FromArgb(40, 167, 69);
    static readonly Color GreenHover = Color.FromArgb(51, 187, 85);
    static readonly Color GreenDisabled = Color.FromArgb(56, 82, 62);

    readonly string _gameDir;
    readonly string _exeName;
    string _cdnUrl = "http://127.0.0.1:8080";
    string _gameExe = "YourGame.exe";
    string _gameTitle = "GAME";
    string _manifestPublicKey = "";

    readonly Label _badge;
    readonly Label _localVer;
    readonly Label _latestVer;
    readonly Label _status;
    readonly Label _progressText;
    readonly ProgressBar _progress;
    readonly Button _play;
    readonly Timer _uiTimer;
    readonly Stopwatch _sw = new Stopwatch();
    readonly object _dlLock = new object();
    readonly List<KeyValuePair<long, long>> _samples = new List<KeyValuePair<long, long>>();

    long _bytesReceived;
    long _totalBytes;
    long _lastProgressLogMs;
    bool _phaseDownloading;
    bool _busy;
    bool _autoPlay;
    bool _selfUpdateScheduled;
    string _currentVersion = "";
    string _latestVersion = "";
    string _dlFileName = "PatchGame.zip";

    readonly Font _titleFont = new Font("Segoe UI", 26f, FontStyle.Bold);
    readonly Font _badgeFont = new Font("Segoe UI", 11f, FontStyle.Bold);
    readonly Font _artFont = new Font("Segoe UI", 52f, FontStyle.Bold);
    readonly Font _artSubFont = new Font("Segoe UI", 11f);
    readonly Font _textFont = new Font("Segoe UI", 10.5f);
    readonly Font _playFont = new Font("Segoe UI", 20f, FontStyle.Bold);

    public LauncherForm(bool autoPlay = false)
    {
        _autoPlay = autoPlay;
        _gameDir = AppDomain.CurrentDomain.BaseDirectory;
        _exeName = Path.GetFileName(Application.ExecutablePath);
        LoadConfig();

        Text = _gameTitle + " Launcher";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = false;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(960, 600);
        BackColor = Bg;
        DoubleBuffered = true;

        // top bar: game title + version badge
        var title = new Label
        {
            Text = _gameTitle.ToUpperInvariant(), Font = _titleFont, ForeColor = TitleText,
            AutoSize = true, Location = new Point(40, 24), BackColor = Color.Transparent
        };
        _badge = new Label
        {
            Text = "v--", Font = _badgeFont, ForeColor = Color.FromArgb(180, 220, 190),
            BackColor = Color.FromArgb(38, 38, 52), BorderStyle = BorderStyle.FixedSingle,
            Padding = new Padding(10, 4, 10, 4), AutoSize = true,
            Anchor = AnchorStyles.Top | AnchorStyles.Right
        };
        _badge.Left = ClientSize.Width - _badge.Width - 40;
        _badge.Top = 30;

        // center art panel
        var art = new Panel
        {
            BackColor = PanelBg,
            Location = new Point(40, 84),
            Size = new Size(880, 320)
        };
        art.Paint += (s, e) =>
        {
            using (var pen = new Pen(PanelBorder))
                e.Graphics.DrawRectangle(pen, 0, 0, art.Width - 1, art.Height - 1);
        };
        var artTitle = new Label
        {
            Text = _gameTitle.ToUpperInvariant(), Font = _artFont, ForeColor = Color.FromArgb(232, 232, 240),
            Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter,
            BackColor = Color.Transparent
        };
        var artSub = new Label
        {
            Text = _gameExe + "  ·  자동 업데이트 런처", Font = _artSubFont,
            ForeColor = Color.FromArgb(110, 110, 128), AutoSize = true,
            BackColor = Color.Transparent
        };
        artSub.Left = (art.Width - artSub.Width) / 2;
        artSub.Top = 208;
        art.Controls.Add(artTitle);
        art.Controls.Add(artSub);

        // version row (always visible)
        _localVer = new Label
        {
            Text = "현재 버전: --", Font = _textFont, ForeColor = DimText,
            AutoSize = true, Location = new Point(40, 420)
        };
        _latestVer = new Label
        {
            Text = "최신 버전: --", Font = _textFont, ForeColor = DimText,
            AutoSize = true, Location = new Point(220, 420)
        };

        // update progress area (hidden until download)
        _progress = new ProgressBar
        {
            Location = new Point(40, 448), Size = new Size(880, 16), Visible = false
        };
        _progressText = new Label
        {
            Font = _textFont, ForeColor = Color.FromArgb(140, 200, 150),
            Location = new Point(40, 472), Size = new Size(880, 20), Visible = false
        };

        // status line
        _status = new Label
        {
            Text = "확인 중...", Font = _textFont, ForeColor = TitleText,
            Location = new Point(40, 500), Size = new Size(880, 22)
        };

        // play button
        _play = new Button
        {
            Text = "PLAY", Font = _playFont, ForeColor = Color.White,
            BackColor = Green, FlatStyle = FlatStyle.Flat,
            Location = new Point(380, 530), Size = new Size(200, 60)
        };
        _play.FlatAppearance.BorderSize = 0;
        _play.EnabledChanged += (s, e) => _play.BackColor = _play.Enabled ? Green : GreenDisabled;
        _play.MouseEnter += (s, e) => { if (_play.Enabled) _play.BackColor = GreenHover; };
        _play.MouseLeave += (s, e) => _play.BackColor = _play.Enabled ? Green : GreenDisabled;
        _play.Click += (s, e) => PlayClicked();

        Controls.Add(title);
        Controls.Add(_badge);
        Controls.Add(art);
        Controls.Add(_localVer);
        Controls.Add(_latestVer);
        Controls.Add(_progress);
        Controls.Add(_progressText);
        Controls.Add(_status);
        Controls.Add(_play);

        _uiTimer = new Timer { Interval = UiTickMs };
        _uiTimer.Tick += (s, e) => OnUiTick();
        _uiTimer.Start();
        FormClosed += (s, e) => _uiTimer.Stop();

        UpdateVersionLabels();
        Log(string.Format("launcher start. dir={0}, cdn={1}, gameExe={2}", _gameDir, _cdnUrl, _gameExe));
        Shown += (s, e) => Run();
    }

    void Log(string msg)
    {
        try
        {
            File.AppendAllText(Path.Combine(_gameDir, "Launcher.log"),
                string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}\r\n", DateTime.Now, msg));
        }
        catch { }
    }

    // raw line without timestamp (headless progress parsing)
    void LogProgress(string msg)
    {
        try
        {
            File.AppendAllText(Path.Combine(_gameDir, "Launcher.log"), msg + "\r\n");
        }
        catch { }
    }

    void LoadConfig()
    {
        string iniPath = Path.Combine(_gameDir, "Launcher.ini");
        if (!File.Exists(iniPath)) return;
        foreach (string line in File.ReadAllLines(iniPath))
        {
            int i = line.IndexOf('=');
            if (i <= 0) continue;
            string key = line.Substring(0, i).Trim();
            string val = line.Substring(i + 1).Trim();
            if (val.Length == 0) continue;
            if (key.Equals("CdnUrl", StringComparison.OrdinalIgnoreCase)) _cdnUrl = val;
            else if (key.Equals("GameExe", StringComparison.OrdinalIgnoreCase)) _gameExe = val;
            else if (key.Equals("GameTitle", StringComparison.OrdinalIgnoreCase)) _gameTitle = val;
            else if (key.Equals("ManifestPublicKey", StringComparison.OrdinalIgnoreCase)) _manifestPublicKey = val;
        }
    }

    void UpdateVersionLabels()
    {
        string latest = string.IsNullOrEmpty(_latestVersion) ? "--" : _latestVersion;
        string current = string.IsNullOrEmpty(_currentVersion) ? "--" : _currentVersion;
        _badge.Text = "v" + latest;
        _localVer.Text = "현재 버전: " + current;
        _latestVer.Text = "최신 버전: " + latest;
    }

    // UI thread only: timer reads thread-safe download state, updates UI
    void OnUiTick()
    {
        if (!_phaseDownloading) return;

        long bytes, total;
        lock (_dlLock) { bytes = _bytesReceived; total = _totalBytes; }
        long ms = _sw.ElapsedMilliseconds;

        int pct = 0;
        if (total > 0)
        {
            pct = (int)(bytes * 100L / total);
            if (pct > 100) pct = 100;
            _progress.Value = pct;
        }

        // moving average over the last ~1s of samples
        _samples.Add(new KeyValuePair<long, long>(ms, bytes));
        while (_samples.Count > 1 && ms - _samples[0].Key > 1000)
            _samples.RemoveAt(0);
        long dt = ms - _samples[0].Key;
        long db = bytes - _samples[0].Value;
        double mbps = dt >= 50 ? db / 1048576.0 / (dt / 1000.0) : 0.0;

        long remaining = total > bytes ? total - bytes : 0;
        int etaSec = mbps > 0.0 ? (int)(remaining / 1048576.0 / mbps) : -1;

        _progressText.Text = string.Format("다운로드 {0}% · {1} · 남은 {2} · {3}",
            total > 0 ? pct : 0,
            mbps > 0.0 ? mbps.ToString("0.0") + " MB/s" : "-- MB/s",
            etaSec >= 0 ? TimeSpan.FromSeconds(etaSec).ToString(@"mm\:ss") : "--:--",
            _dlFileName);

        // 5-second progress log line, raw, e.g. "progress 43.2% 12.4MB/s"
        if (ms - _lastProgressLogMs >= ProgressLogMs)
        {
            double pctD = total > 0 ? (double)bytes / total * 100.0 : 0.0;
            LogProgress(string.Format("progress {0:0.0}% {1:0.0}MB/s", pctD, mbps));
            _lastProgressLogMs = ms;
        }
    }

    async void Run()
    {
        Log("run: startup flow (version check only)");
        _busy = true;
        _play.Enabled = false;
        try
        {
            // 1. CDN version check (5s timeout) — no download, no launch at startup
            _status.Text = "버전 확인 중...";
            string remote = null;
            try
            {
                remote = await Task.Run(() =>
                    HttpGetVerifiedString(_cdnUrl.TrimEnd('/') + "/Full/FullVersion.txt"));
                remote = remote.Trim();
                if (remote.Length == 0) throw new Exception("CDN 버전이 비어 있습니다.");
                _latestVersion = remote;
            }
            catch (Exception ex)
            {
                Log("CDN check failed: " + ex.Message);
                _status.Text = "CDN 오프라인";
            }

            UpdateVersionLabels();

            // 2. compare with local install, then wait for PLAY
            string localVersionPath = Path.Combine(_gameDir, "FullVersion.txt");
            string local = File.Exists(localVersionPath)
                ? File.ReadAllText(localVersionPath).Trim()
                : "";
            _currentVersion = local;
            UpdateVersionLabels();
            Log(string.Format("version check: local='{0}' remote='{1}'", local, remote ?? ""));

            bool installed = File.Exists(Path.Combine(_gameDir, _gameExe));
            if (remote == null)
                _status.Text = installed ? "CDN 오프라인 — 기존 게임 실행 가능" : "게임 설치 필요 — CDN 오프라인";
            else if (!installed)
                _status.Text = "게임 설치 필요 — PLAY를 눌러 설치 후 시작";
            else
                _status.Text = (local == remote)
                    ? "최신 버전입니다 — PLAY를 눌러 시작"
                    : string.Format("업데이트 {0} → {1} — PLAY를 눌러 업데이트 후 시작",
                        string.IsNullOrEmpty(local) ? "--" : local, _latestVersion);
        }
        catch (Exception ex)
        {
            Log("FATAL: " + ex);
            _status.Text = "오류: " + ex.Message;
        }
        finally
        {
            _busy = false;
            _play.Enabled = true;
            if (_autoPlay)
            {
                _autoPlay = false;
                BeginInvoke(new Action(PlayClicked));
            }
        }
    }

    // PLAY click: update if needed, then always launch the game
    async void PlayClicked()
    {
        if (_busy) return; // double-click guard; ignored while downloading
        _busy = true;
        _play.Enabled = false;
        try
        {
            bool updateSucceeded = !UpdateAvailable() || await RunUpdate();

            if (_selfUpdateScheduled)
            {
                Close();
                return;
            }

            if (!updateSucceeded && !File.Exists(Path.Combine(_gameDir, _gameExe)))
            {
                _busy = false;
                _play.Enabled = true;
                return;
            }

            _busy = false;
            _play.Enabled = true;
            Launch();
        }
        catch (Exception ex)
        {
            Log("FATAL: " + ex);
            _status.Text = "오류: " + ex.Message;
            _busy = false;
            _play.Enabled = true;
        }
    }

    bool UpdateAvailable()
    {
        if (!File.Exists(Path.Combine(_gameDir, _gameExe))) return true;

        string localVersionPath = Path.Combine(_gameDir, "FullVersion.txt");
        string local = File.Exists(localVersionPath)
            ? File.ReadAllText(localVersionPath).Trim()
            : "";
        if (!string.IsNullOrEmpty(_latestVersion) &&
            !string.Equals(local, _latestVersion, StringComparison.Ordinal))
            return true;

        foreach (FullFileEntry entry in ReadLocalManifest())
        {
            if (IsLauncherEntry(entry))
                return !File.Exists(Application.ExecutablePath) ||
                    new FileInfo(Application.ExecutablePath).Length != entry.Size ||
                    !string.Equals(ComputeSha256(Application.ExecutablePath), entry.Hash,
                        StringComparison.OrdinalIgnoreCase);
        }
        return false;
    }

    async Task<bool> RunUpdate()
    {
        string manifestUrl = _cdnUrl.TrimEnd('/') + "/Full/" +
            Uri.EscapeDataString(_latestVersion) + "/FullManifest.txt";
        bool useLegacy = false;
        string manifest = null;
        try
        {
            manifest = await Task.Run(() => HttpGetVerifiedString(manifestUrl));
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            if (!string.IsNullOrEmpty(_manifestPublicKey) ||
                response == null || response.StatusCode != HttpStatusCode.NotFound)
                return ReportUpdateFailure(ex, "manifest download failed");
            Log("file manifest not found; using legacy ZIP update");
            useLegacy = true;
        }
        catch (Exception ex)
        {
            return ReportUpdateFailure(ex, "manifest verification failed");
        }
        return useLegacy ? await RunLegacyUpdate() : await RunIncrementalUpdate(manifest, manifestUrl);
    }

    async Task<bool> RunIncrementalUpdate(string manifestText, string manifestUrl)
    {
        string cacheRoot = Path.Combine(_gameDir, ".launcher-cache", _latestVersion);
        try
        {
            List<FullFileEntry> entries = ParseFullManifest(manifestText, _latestVersion);
            _status.Text = "설치 파일 검사 중...";
            List<FullFileEntry> changed = await Task.Run(() => FindChangedFiles(entries));
            List<FullFileEntry> previous = ReadLocalManifest();
            var currentPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (FullFileEntry entry in entries) currentPaths.Add(entry.Path);
            var obsolete = new List<FullFileEntry>();
            foreach (FullFileEntry entry in previous)
                if (!currentPaths.Contains(entry.Path) && !IsLauncherEntry(entry)) obsolete.Add(entry);

            long totalBytes = 0;
            foreach (FullFileEntry entry in changed) totalBytes += entry.Size;
            long completedBytes = 0;
            if (changed.Count > 0)
            {
                _progress.Visible = true;
                _progressText.Visible = true;
                _phaseDownloading = true;
                _samples.Clear();
                _lastProgressLogMs = 0;
                _sw.Restart();
            }

            foreach (FullFileEntry entry in changed)
            {
                _dlFileName = entry.Path;
                string partial = SafePath(cacheRoot, entry.Path + ".part");
                Directory.CreateDirectory(Path.GetDirectoryName(partial));
                string partialHash = partial + ".sha256";
                long offset = PreparePartial(partial, partialHash, entry.Hash, entry.Size);
                lock (_dlLock)
                {
                    _bytesReceived = completedBytes + offset;
                    _totalBytes = totalBytes;
                }
                _status.Text = offset > 0 ? "변경 파일 이어받는 중..." : "변경 파일 다운로드 중...";
                string fileUrl = manifestUrl.Substring(0, manifestUrl.LastIndexOf('/') + 1) +
                    "Files/" + EscapeUrlPath(entry.Path);
                Log(string.Format("file download: {0}, size={1}, resume={2}", entry.Path, entry.Size, offset));
                await Task.Run(() => DownloadStream(fileUrl, partial, entry.Size, completedBytes, totalBytes));

                string actualHash = await Task.Run(() => ComputeSha256(partial));
                if (!string.Equals(actualHash, entry.Hash, StringComparison.OrdinalIgnoreCase))
                {
                    DeletePartial(partial, partialHash);
                    throw new Exception("파일 SHA-256 검증 실패: " + entry.Path);
                }
                completedBytes += entry.Size;
            }
            _phaseDownloading = false;

            _status.Text = "업데이트 적용 중...";
            await Task.Run(() => ApplyIncremental(changed, obsolete, cacheRoot));
            File.WriteAllText(Path.Combine(_gameDir, "FullManifest.txt"), manifestText, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(_gameDir, "FullVersion.txt"), _latestVersion, new UTF8Encoding(false));
            _currentVersion = _latestVersion;
            UpdateVersionLabels();

            FullFileEntry launcher = changed.Find(IsLauncherEntry);
            if (launcher != null)
            {
                string newLauncher = SafePath(cacheRoot, launcher.Path + ".part");
                ScheduleSelfUpdate(newLauncher, cacheRoot);
                _status.Text = "런처 업데이트 후 다시 시작합니다...";
                _selfUpdateScheduled = true;
            }
            else
            {
                try { if (Directory.Exists(cacheRoot)) Directory.Delete(cacheRoot, true); } catch { }
                _status.Text = changed.Count == 0 && obsolete.Count == 0
                    ? "최신 버전입니다"
                    : "업데이트 완료";
            }

            Log(string.Format("incremental update applied: {0}, changed={1}, removed={2}",
                _latestVersion, changed.Count, obsolete.Count));
            return true;
        }
        catch (Exception ex)
        {
            _phaseDownloading = false;
            return ReportUpdateFailure(ex, "incremental update failed");
        }
        finally
        {
            _progress.Visible = false;
            _progressText.Visible = false;
        }
    }

    List<FullFileEntry> FindChangedFiles(List<FullFileEntry> entries)
    {
        var changed = new List<FullFileEntry>();
        foreach (FullFileEntry entry in entries)
        {
            string path = IsLauncherEntry(entry) ? Application.ExecutablePath : SafePath(_gameDir, entry.Path);
            if (!File.Exists(path) || new FileInfo(path).Length != entry.Size ||
                !string.Equals(ComputeSha256(path), entry.Hash, StringComparison.OrdinalIgnoreCase))
                changed.Add(entry);
        }
        return changed;
    }

    List<FullFileEntry> ReadLocalManifest()
    {
        string path = Path.Combine(_gameDir, "FullManifest.txt");
        if (!File.Exists(path)) return new List<FullFileEntry>();
        try { return ParseFullManifest(File.ReadAllText(path), ""); }
        catch { return new List<FullFileEntry>(); }
    }

    internal static List<FullFileEntry> ParseFullManifest(string text, string expectedVersion)
    {
        var entries = new List<FullFileEntry>();
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string version = "";
        int expectedCount = -1;
        foreach (string raw in text.Replace("\r", "").Split('\n'))
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("$VERSION = "))
            {
                version = line.Substring(11).Trim();
                continue;
            }
            if (line.StartsWith("$NUM_ENTRIES = "))
            {
                if (!int.TryParse(line.Substring(15).Trim(), out expectedCount) || expectedCount < 0)
                    throw new Exception("전체 빌드 매니페스트 파일 수가 올바르지 않습니다.");
                continue;
            }

            string[] fields = line.Split('\t');
            long size;
            if (fields.Length != 3 || !long.TryParse(fields[1], out size) || size < 0 ||
                !fields[2].StartsWith("SHA256:", StringComparison.OrdinalIgnoreCase))
                throw new Exception("전체 빌드 매니페스트 형식이 올바르지 않습니다.");
            string path = fields[0].Replace('\\', '/');
            string hash = fields[2].Substring(7);
            if (path.Length == 0 || Path.IsPathRooted(path) || path.Contains("../") ||
                !IsSha256(hash) || !paths.Add(path))
                throw new Exception("전체 빌드 매니페스트 항목이 올바르지 않습니다: " + path);
            entries.Add(new FullFileEntry { Path = path, Size = size, Hash = hash });
        }
        if (version.Length == 0 ||
            (expectedVersion.Length > 0 && !string.Equals(version, expectedVersion, StringComparison.Ordinal)))
            throw new Exception("전체 빌드 매니페스트 버전이 일치하지 않습니다.");
        if (expectedCount != entries.Count)
            throw new Exception("전체 빌드 매니페스트 파일 수가 일치하지 않습니다.");
        return entries;
    }

    void ApplyIncremental(List<FullFileEntry> changed, List<FullFileEntry> obsolete, string cacheRoot)
    {
        StopRunningGame();
        string backupRoot = Path.Combine(_gameDir, "__patch_backup");
        if (Directory.Exists(backupRoot)) Directory.Delete(backupRoot, true);
        Directory.CreateDirectory(backupRoot);
        var touched = new List<string>();
        try
        {
            foreach (FullFileEntry entry in obsolete)
                BackupCurrentFile(entry.Path, backupRoot, touched);

            foreach (FullFileEntry entry in changed)
            {
                if (IsLauncherEntry(entry)) continue;
                BackupCurrentFile(entry.Path, backupRoot, touched);
                string source = SafePath(cacheRoot, entry.Path + ".part");
                string dest = SafePath(_gameDir, entry.Path);
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                File.Move(source, dest);
            }
        }
        catch
        {
            for (int i = touched.Count - 1; i >= 0; --i)
            {
                string dest = SafePath(_gameDir, touched[i]);
                string backup = SafePath(backupRoot, touched[i]);
                try { if (File.Exists(dest)) File.Delete(dest); } catch { }
                if (File.Exists(backup))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    try { File.Move(backup, dest); } catch { }
                }
            }
            try { Directory.Delete(backupRoot, true); } catch { }
            throw;
        }
        try { Directory.Delete(backupRoot, true); } catch { }
    }

    void BackupCurrentFile(string relativePath, string backupRoot, List<string> touched)
    {
        string dest = SafePath(_gameDir, relativePath);
        string backup = SafePath(backupRoot, relativePath);
        if (Directory.Exists(dest))
            throw new Exception("파일 경로가 디렉터리와 충돌합니다: " + relativePath);
        if (File.Exists(dest))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(backup));
            File.Move(dest, backup);
        }
        touched.Add(relativePath);
    }

    void ScheduleSelfUpdate(string newLauncher, string cacheRoot)
    {
        string script = Path.Combine(_gameDir, "LauncherUpdate.cmd");
        string current = Application.ExecutablePath;
        int pid = Process.GetCurrentProcess().Id;
        string body = "@echo off\r\nsetlocal\r\n:wait\r\n" +
            "tasklist /FI \"PID eq " + pid + "\" 2>NUL | find \"" + pid + "\" >NUL\r\n" +
            "if not errorlevel 1 (timeout /t 1 /nobreak >NUL & goto wait)\r\n" +
            "move /Y \"" + BatchPath(newLauncher) + "\" \"" + BatchPath(current) + "\" >NUL\r\n" +
            "if errorlevel 1 exit /b 1\r\n" +
            "rmdir /S /Q \"" + BatchPath(cacheRoot) + "\" 2>NUL\r\n" +
            "start \"\" \"" + BatchPath(current) + "\" --play\r\n" +
            "del \"%~f0\"\r\n";
        File.WriteAllText(script, body, Encoding.Default);
        Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/d /c call \"" + script + "\"",
            CreateNoWindow = true,
            UseShellExecute = false,
            WorkingDirectory = _gameDir
        });
    }

    static string SafePath(string root, string relativePath)
    {
        string fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string full = Path.GetFullPath(Path.Combine(fullRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
            throw new Exception("비정상적인 업데이트 경로: " + relativePath);
        return full;
    }

    static string EscapeUrlPath(string path)
    {
        string[] parts = path.Replace('\\', '/').Split('/');
        for (int i = 0; i < parts.Length; ++i) parts[i] = Uri.EscapeDataString(parts[i]);
        return string.Join("/", parts);
    }

    bool IsLauncherEntry(FullFileEntry entry)
    {
        return string.Equals(entry.Path, "Launcher.exe", StringComparison.OrdinalIgnoreCase);
    }

    static string BatchPath(string path)
    {
        return path.Replace("%", "%%");
    }

    // Legacy full ZIP fallback for CDN deployments created before version 1.3.
    async Task<bool> RunLegacyUpdate()
    {
        string zipUrl = _cdnUrl.TrimEnd('/') + "/Full/PatchGame.zip";
        _dlFileName = Path.GetFileName(new Uri(zipUrl).LocalPath);
        string tempZip = Path.Combine(_gameDir, "PatchGame_update.zip.part");
        string tempHash = tempZip + ".sha256";
        bool updateApplied = false;
        try
        {
            string expectedHash = (await Task.Run(() => HttpGetString(zipUrl + ".sha256"))).Trim();
            if (!IsSha256(expectedHash))
                throw new Exception("CDN SHA-256 파일 형식이 올바르지 않습니다.");

            // 3. download (progress on background thread -> thread-safe fields)
            long size = await Task.Run(() => GetContentLength(zipUrl));
            long resumeOffset = PreparePartial(tempZip, tempHash, expectedHash, size);
            Log(string.Format("download start: {0}, size={1} bytes, resume={2}",
                _dlFileName, size, resumeOffset));

            _status.Text = resumeOffset > 0 ? "업데이트 다운로드 재개 중..." : "업데이트 다운로드 중...";
            _progress.Visible = true;
            _progressText.Visible = true;
            _phaseDownloading = true;
            lock (_dlLock) { _bytesReceived = resumeOffset; _totalBytes = size; }
            _samples.Clear();
            _lastProgressLogMs = 0;
            _sw.Restart();

            await Task.Run(() => DownloadStream(zipUrl, tempZip, size));
            _phaseDownloading = false;

            long elapsedMs = _sw.ElapsedMilliseconds;
            long downloaded = new FileInfo(tempZip).Length - resumeOffset;
            double avg = elapsedMs > 0 ? downloaded / 1048576.0 / (elapsedMs / 1000.0) : 0.0;
            Log(string.Format("download complete: {0} new bytes in {1:F1}s, avg {2:F1} MB/s",
                downloaded, elapsedMs / 1000.0, avg));

            _status.Text = "다운로드 무결성 검사 중...";
            string actualHash = await Task.Run(() => ComputeSha256(tempZip));
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                DeletePartial(tempZip, tempHash);
                throw new Exception("업데이트 파일 SHA-256 검증에 실패했습니다.");
            }
            Log("download SHA-256 OK: " + actualHash);

            _progress.Visible = false;
            _progressText.Visible = false;

            // 4. extract & swap (self-update impossible: Launcher.exe/ini/log preserved)
            _status.Text = "압축 해제 중...";
            string extractDir = Path.Combine(Path.GetTempPath(), "PatchGame_extract");
            await Task.Run(() => Extract(tempZip, extractDir));

            _status.Text = "업데이트 적용 중...";
            await Task.Run(() => ApplyUpdate(extractDir));

            File.WriteAllText(Path.Combine(_gameDir, "FullVersion.txt"), _latestVersion, new UTF8Encoding(false));
            _currentVersion = _latestVersion;
            UpdateVersionLabels();
            Log("update applied: " + _latestVersion);
            _status.Text = "업데이트 완료";
            updateApplied = true;
            return true;
        }
        catch (Exception ex)
        {
            _phaseDownloading = false;
            return ReportUpdateFailure(ex, "legacy update failed");
        }
        finally
        {
            if (updateApplied) DeletePartial(tempZip, tempHash);
            _progress.Visible = false;
            _progressText.Visible = false;
        }
    }

    bool ReportUpdateFailure(Exception ex, string logPrefix)
    {
        Log(logPrefix + ": " + ex);
        bool installed = File.Exists(Path.Combine(_gameDir, _gameExe));
        _status.Text = installed ? "업데이트 실패 — 기존 버전을 실행합니다" : "설치 실패 — 다시 시도해 주세요";
        MessageBox.Show(ex.Message + "\n\n가능한 경우 이어받기 파일을 다음 시도를 위해 보존합니다.\n상세 로그: " +
            Path.Combine(_gameDir, "Launcher.log"), "업데이트 실패",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
        return false;
    }

    static long GetContentLength(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "HEAD";
        req.Timeout = HttpTimeoutMs;
        using (var resp = (HttpWebResponse)req.GetResponse())
            return resp.ContentLength; // -1 = unknown
    }

    // Continue a partial file with HTTP Range. Servers that ignore Range safely restart at byte 0.
    void DownloadStream(string url, string destPath, long expectedSize)
    {
        DownloadStream(url, destPath, expectedSize, 0, expectedSize);
    }

    void DownloadStream(string url, string destPath, long expectedSize, long completedBytes, long totalBytes)
    {
        long offset = File.Exists(destPath) ? new FileInfo(destPath).Length : 0;
        if (expectedSize >= 0 && offset == expectedSize) return;

        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = HttpTimeoutMs;
        req.ReadWriteTimeout = HttpTimeoutMs;
        if (offset > 0) req.AddRange(offset);

        using (var resp = (HttpWebResponse)req.GetResponse())
        {
            bool resumed = offset > 0 && resp.StatusCode == HttpStatusCode.PartialContent;
            if (offset > 0 && !resumed)
            {
                Log("server ignored HTTP Range; restarting download");
                offset = 0;
            }

            lock (_dlLock)
            {
                _bytesReceived = completedBytes + offset;
                _totalBytes = totalBytes > 0 ? totalBytes : completedBytes + offset + Math.Max(0, resp.ContentLength);
            }

            using (Stream input = resp.GetResponseStream())
            using (FileStream output = new FileStream(destPath,
                resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read))
            {
                byte[] buf = new byte[256 * 1024];
                int n;
                while ((n = input.Read(buf, 0, buf.Length)) > 0)
                {
                    output.Write(buf, 0, n);
                    lock (_dlLock) { _bytesReceived += n; }
                }
            }
        }

        if (expectedSize >= 0 && new FileInfo(destPath).Length != expectedSize)
            throw new Exception("업데이트 파일 크기가 CDN과 일치하지 않습니다.");
    }

    internal static long PreparePartial(string path, string hashPath, string expectedHash, long expectedSize)
    {
        string savedHash = File.Exists(hashPath) ? File.ReadAllText(hashPath).Trim() : "";
        long length = File.Exists(path) ? new FileInfo(path).Length : 0;
        if (!string.Equals(savedHash, expectedHash, StringComparison.OrdinalIgnoreCase) ||
            (expectedSize >= 0 && length > expectedSize))
        {
            DeletePartial(path, hashPath);
            length = 0;
        }
        File.WriteAllText(hashPath, expectedHash, new UTF8Encoding(false));
        return length;
    }

    static bool IsSha256(string value)
    {
        if (value == null || value.Length != 64) return false;
        foreach (char c in value)
            if (!Uri.IsHexDigit(c)) return false;
        return true;
    }

    static void DeletePartial(string path, string hashPath)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
        try { if (File.Exists(hashPath)) File.Delete(hashPath); } catch { }
    }

    // small GET for the version file; returns raw UTF-8 text
    string HttpGetVerifiedString(string url)
    {
        byte[] data = HttpGetBytes(url);
        if (!string.IsNullOrEmpty(_manifestPublicKey))
        {
            string encodedSignature = Encoding.UTF8.GetString(HttpGetBytes(url + ".sig")).Trim();
            byte[] signature;
            try { signature = Convert.FromBase64String(encodedSignature); }
            catch { throw new Exception("업데이트 서명 형식이 올바르지 않습니다: " + url); }

            if (!VerifySignature(data, _manifestPublicKey, signature))
                throw new Exception("업데이트 서명 검증에 실패했습니다: " + url);
        }
        return Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
    }

    internal static bool VerifySignature(byte[] data, string publicKey, byte[] signature)
    {
        using (var rsa = new RSACryptoServiceProvider())
        {
            rsa.PersistKeyInCsp = false;
            try { rsa.FromXmlString(publicKey); }
            catch { throw new Exception("Launcher.ini 공개 키 형식이 올바르지 않습니다."); }
            return rsa.VerifyData(data, CryptoConfig.MapNameToOID("SHA256"), signature);
        }
    }

    static byte[] HttpGetBytes(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = HttpTimeoutMs;
        using (var resp = (HttpWebResponse)req.GetResponse())
        using (Stream input = resp.GetResponseStream())
        using (var output = new MemoryStream())
        {
            input.CopyTo(output);
            return output.ToArray();
        }
    }

    static string HttpGetString(string url)
    {
        return Encoding.UTF8.GetString(HttpGetBytes(url)).TrimStart('\uFEFF');
    }

    internal static string ComputeSha256(string path)
    {
        using (var sha = SHA256.Create())
        using (var input = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "");
    }

    static void Extract(string zipPath, string extractDir)
    {
        if (Directory.Exists(extractDir)) Directory.Delete(extractDir, true);
        Directory.CreateDirectory(extractDir);

        string root = Path.GetFullPath(extractDir);
        string rootPrefix = root + Path.DirectorySeparatorChar;

        using (var zip = ZipFile.OpenRead(zipPath))
        {
            foreach (var entry in zip.Entries)
            {
                string dest = Path.GetFullPath(Path.Combine(root, entry.FullName));
                if (dest != root && !dest.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                    throw new Exception("비정상적인 압축 파일 경로: " + entry.FullName);

                if (entry.FullName.Length == 0 ||
                    entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\"))
                {
                    Directory.CreateDirectory(dest);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                // retry on transient locks (Defender/AV, e.g. dbghelp.dll)
                for (int attempt = 1; ; attempt++)
                {
                    try { entry.ExtractToFile(dest, true); break; }
                    catch (Exception)
                    {
                        if (attempt >= 3) throw;
                        System.Threading.Thread.Sleep(500);
                    }
                }
            }
        }
    }

    void ApplyUpdate(string extractDir)
    {
        if (!File.Exists(Path.Combine(extractDir, _gameExe)))
            throw new Exception("업데이트 패키지에 게임 실행 파일이 없습니다: " + _gameExe);

        string oldDir = Path.Combine(_gameDir, "__old");
        var movedIn = new List<string>();

        StopRunningGame();

        try
        {
            // fresh __old
            if (Directory.Exists(oldDir)) Directory.Delete(oldDir, true);
            Directory.CreateDirectory(oldDir);

            // move current install aside (keep the launcher itself and its ini in place)
            foreach (string path in Directory.GetFileSystemEntries(_gameDir))
            {
                string name = Path.GetFileName(path);
                if (string.Equals(name, _exeName, StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(name, "Launcher.ini", StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(name, "Launcher.log", StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(name, "__old", StringComparison.OrdinalIgnoreCase)) continue;
                if (Directory.Exists(path)) Directory.Move(path, Path.Combine(oldDir, name));
                else File.Move(path, Path.Combine(oldDir, name));
            }

            // move fresh build in; record what landed so a mid-swap failure can roll back
            foreach (string src in Directory.GetFileSystemEntries(extractDir))
            {
                string dest = Path.Combine(_gameDir, Path.GetFileName(src));
                if (Directory.Exists(src)) Directory.Move(src, dest);
                else File.Move(src, dest);
                movedIn.Add(Path.GetFileName(src));
            }
        }
        catch (Exception)
        {
            // restore the previous install (best effort), then rethrow
            try { Rollback(extractDir, oldDir, movedIn); } catch { }
            throw;
        }

        // success: drop the old copy; leftovers that won't delete are manual cleanup
        try { if (Directory.Exists(oldDir)) Directory.Delete(oldDir, true); } catch { }
    }

    void StopRunningGame()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "taskkill",
                Arguments = "/IM " + _gameExe + " /F",
                CreateNoWindow = true,
                UseShellExecute = false
            });
        }
        catch { }
        System.Threading.Thread.Sleep(1500); // give the OS time to release handles
    }

    // best-effort restore on mid-swap failure: pull newly installed items back out,
    // then move the previous install back from __old
    void Rollback(string extractDir, string oldDir, List<string> movedIn)
    {
        foreach (string name in movedIn)
        {
            string src = Path.Combine(_gameDir, name);
            string dst = Path.Combine(extractDir, name);
            try
            {
                if (Directory.Exists(src)) Directory.Move(src, dst);
                else if (File.Exists(src)) File.Move(src, dst);
            }
            catch { }
        }

        if (Directory.Exists(oldDir))
        {
            foreach (string src in Directory.GetFileSystemEntries(oldDir))
            {
                string dst = Path.Combine(_gameDir, Path.GetFileName(src));
                try
                {
                    if (Directory.Exists(src)) Directory.Move(src, dst);
                    else File.Move(src, dst);
                }
                catch { }
            }
            try { Directory.Delete(oldDir, true); } catch { }
        }
    }

    void Launch()
    {
        string exe = Path.Combine(_gameDir, _gameExe);
        Log("launch: " + exe);
        if (!File.Exists(exe))
        {
            FailToLaunch("게임 실행 파일이 없습니다:\n" + exe +
                "\n\n설치 폴더에 " + _gameExe + "가 최상위에 있는지 확인하세요.");
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo { FileName = exe, WorkingDirectory = _gameDir });
            Log("game started");
            Close();
        }
        catch (Exception ex)
        {
            Log("game start exception: " + ex);
            FailToLaunch("게임 실행 실패:\n" + ex.Message);
        }
    }

    void FailToLaunch(string reason)
    {
        Log("LAUNCH FAILED: " + reason.Replace("\n", " "));
        _status.Text = "게임 실행 실패 — Launcher.log 확인";
        MessageBox.Show(reason + "\n\n상세 로그: " + Path.Combine(_gameDir, "Launcher.log"),
            "게임 실행 실패", MessageBoxButtons.OK, MessageBoxIcon.Error);
        Close();
    }
}
