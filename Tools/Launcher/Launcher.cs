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
            string path = Path.GetTempFileName();
            try
            {
                File.WriteAllBytes(path, Encoding.ASCII.GetBytes("abc"));
                Environment.ExitCode = LauncherForm.ComputeSha256(path) ==
                    "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD" ? 0 : 1;
            }
            finally { File.Delete(path); }
            return;
        }

        if (args.Length > 0 && (args[0] == "/?" || args[0] == "-?" || args[0] == "--help"))
            return; // immediate-exit switch (headless verification)

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new LauncherForm());
    }
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
    string _gameExe = "TP_ThirdPerson.exe";

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
    string _currentVersion = "";
    string _latestVersion = "";
    string _dlFileName = "PatchGame.zip";

    readonly Font _titleFont = new Font("Segoe UI", 26f, FontStyle.Bold);
    readonly Font _badgeFont = new Font("Segoe UI", 11f, FontStyle.Bold);
    readonly Font _artFont = new Font("Segoe UI", 52f, FontStyle.Bold);
    readonly Font _artSubFont = new Font("Segoe UI", 11f);
    readonly Font _textFont = new Font("Segoe UI", 10.5f);
    readonly Font _playFont = new Font("Segoe UI", 20f, FontStyle.Bold);

    public LauncherForm()
    {
        _gameDir = AppDomain.CurrentDomain.BaseDirectory;
        _exeName = Path.GetFileName(Application.ExecutablePath);
        LoadConfig();

        Text = "PatchGame Launcher";
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
            Text = "PATCH GAME", Font = _titleFont, ForeColor = TitleText,
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
            Text = "PATCH GAME", Font = _artFont, ForeColor = Color.FromArgb(232, 232, 240),
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
                    HttpGetString(_cdnUrl.TrimEnd('/') + "/Full/FullVersion.txt"));
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
            if (UpdateAvailable())
                await RunUpdate(); // failure is swallowed inside: status set, launch anyway

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
        return !string.IsNullOrEmpty(_latestVersion) &&
            !string.Equals(local, _latestVersion, StringComparison.Ordinal);
    }

    // full update pipeline: download (manual stream) -> extract -> move-first apply
    async Task RunUpdate()
    {
        string zipUrl = _cdnUrl.TrimEnd('/') + "/Full/PatchGame.zip";
        _dlFileName = Path.GetFileName(new Uri(zipUrl).LocalPath);
        string tempZip = Path.Combine(Path.GetTempPath(), "PatchGame_update.zip");
        // delete stale temp zip before download (never reuse a partial file)
        try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }
        try
        {
            string expectedHash = (await Task.Run(() => HttpGetString(zipUrl + ".sha256"))).Trim();

            // 3. download (progress on background thread -> thread-safe fields)
            long size = await Task.Run(() => GetContentLength(zipUrl));
            Log(string.Format("download start: {0}, size={1} bytes", _dlFileName, size));

            _status.Text = "업데이트 다운로드 중...";
            _progress.Visible = true;
            _progressText.Visible = true;
            _phaseDownloading = true;
            lock (_dlLock) { _bytesReceived = 0; _totalBytes = 0; }
            _samples.Clear();
            _lastProgressLogMs = 0;
            _sw.Restart();

            // manual stream download: byte-level progress guaranteed, no WebClient events
            await Task.Run(() => DownloadStream(zipUrl, tempZip));
            _phaseDownloading = false;

            // fallback: on-disk size is ground truth if progress events missed reporting
            if (_totalBytes <= 0)
            {
                lock (_dlLock) { _totalBytes = new FileInfo(tempZip).Length; }
            }

            long elapsedMs = _sw.ElapsedMilliseconds;
            double avg = elapsedMs > 0 ? _totalBytes / 1048576.0 / (elapsedMs / 1000.0) : 0.0;
            Log(string.Format("download complete: {0} bytes in {1:F1}s, avg {2:F1} MB/s",
                _totalBytes, elapsedMs / 1000.0, avg));

            _status.Text = "다운로드 무결성 검사 중...";
            string actualHash = await Task.Run(() => ComputeSha256(tempZip));
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new Exception("업데이트 파일 SHA-256 검증에 실패했습니다.");
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
        }
        catch (Exception ex)
        {
            _phaseDownloading = false;
            Log("update failed: " + ex);
            _status.Text = "업데이트 실패 — PLAY로 기존 게임 실행";
        }
        finally
        {
            try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }
            _progress.Visible = false;
            _progressText.Visible = false;
        }
    }

    static long GetContentLength(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "HEAD";
        req.Timeout = HttpTimeoutMs;
        using (var resp = (HttpWebResponse)req.GetResponse())
            return resp.ContentLength; // -1 = unknown
    }

    // GET via HttpWebRequest, streamed to disk in 256KB chunks; every chunk updates
    // the lock-guarded byte counters that the UI timer and 5s progress log read
    void DownloadStream(string url, string destPath)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = HttpTimeoutMs;

        using (var resp = (HttpWebResponse)req.GetResponse())
        {
            lock (_dlLock)
            {
                _bytesReceived = 0;
                _totalBytes = resp.ContentLength > 0 ? resp.ContentLength : 0;
            }

            using (Stream input = resp.GetResponseStream())
            using (FileStream output = new FileStream(destPath, FileMode.Create, FileAccess.Write))
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
    }

    // small GET for the version file; returns raw UTF-8 text
    static string HttpGetString(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = HttpTimeoutMs;
        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var reader = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
            return reader.ReadToEnd();
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

        // kill any running game so the update can replace locked files
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
                "\n\n설치 폴더에 TP_ThirdPerson.exe가 최상위에 있는지 확인하세요.");
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
