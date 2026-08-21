using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program
{
    private const string PayloadResource = "HarborProxy.Payload.7z";
    private const string ExtractorResource = "HarborProxy.7zr.exe";
    private const string InstallerRegistryPath = @"Software\HarborProxy\Installer";
    private const string InstallLocationValue = "InstallLocation";
    private const string HelperServiceName = "HarborProxyHelperService";
    private const uint ProcessQueryLimitedInformation = 0x1000;

    private static readonly string[] ManagedExecutableNames = new string[]
    {
        "HarborProxy.exe",
        "HarborProxyCore.exe",
        "HarborProxyHelperService.exe"
    };

    private sealed class InstallOptions
    {
        internal string TargetDirectory;
        internal bool CreateShortcut;
        internal bool Silent;
        internal bool ForceClose;
    }

    private sealed class ManagedProcess
    {
        internal int Id;
        internal string Name;
        internal string ExecutablePath;
    }

    private sealed class HelperServiceSnapshot
    {
        internal bool Exists;
        internal string ImagePath;
        internal int StartMode;
        internal bool WasRunning;
    }

    private sealed class InstallDialog : Form
    {
        private readonly TextBox targetBox;
        private readonly CheckBox shortcutBox;

        internal string TargetDirectory { get; private set; }
        internal bool CreateShortcut { get; private set; }

        internal InstallDialog(string defaultTarget)
        {
            Text = "HarborProxy";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            ClientSize = new Size(620, 176);
            AutoScaleMode = AutoScaleMode.Dpi;

            Label targetLabel = new Label();
            targetLabel.AutoSize = true;
            targetLabel.Location = new Point(18, 18);
            targetLabel.Text = "安装目录：";

            targetBox = new TextBox();
            targetBox.Location = new Point(21, 43);
            targetBox.Size = new Size(495, 24);
            targetBox.Text = defaultTarget;

            Button browseButton = new Button();
            browseButton.Location = new Point(524, 41);
            browseButton.Size = new Size(76, 28);
            browseButton.Text = "浏览…";
            browseButton.Click += BrowseTarget;

            shortcutBox = new CheckBox();
            shortcutBox.AutoSize = true;
            shortcutBox.Checked = true;
            shortcutBox.Location = new Point(21, 86);
            shortcutBox.Text = "创建桌面快捷方式";

            Button extractButton = new Button();
            extractButton.Location = new Point(429, 126);
            extractButton.Size = new Size(82, 30);
            extractButton.Text = "安装 / 更新";
            extractButton.Click += ConfirmInstall;

            Button cancelButton = new Button();
            cancelButton.DialogResult = DialogResult.Cancel;
            cancelButton.Location = new Point(518, 126);
            cancelButton.Size = new Size(82, 30);
            cancelButton.Text = "取消";

            Controls.Add(targetLabel);
            Controls.Add(targetBox);
            Controls.Add(browseButton);
            Controls.Add(shortcutBox);
            Controls.Add(extractButton);
            Controls.Add(cancelButton);
            AcceptButton = extractButton;
            CancelButton = cancelButton;
        }

        private void BrowseTarget(object sender, EventArgs args)
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "选择 HarborProxy 安装目录";
                dialog.ShowNewFolderButton = true;
                string current = targetBox.Text.Trim();
                if (Directory.Exists(current))
                {
                    dialog.SelectedPath = current;
                }
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    targetBox.Text = dialog.SelectedPath;
                }
            }
        }

        private void ConfirmInstall(object sender, EventArgs args)
        {
            try
            {
                string value = Environment.ExpandEnvironmentVariables(targetBox.Text.Trim());
                if (String.IsNullOrWhiteSpace(value) || value.IndexOf('"') >= 0)
                {
                    throw new InvalidOperationException("请选择有效的安装目录。");
                }
                TargetDirectory = Path.GetFullPath(value);
                CreateShortcut = shortcutBox.Checked;
                DialogResult = DialogResult.OK;
                Close();
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    this,
                    error.Message,
                    "HarborProxy",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning
                );
            }
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasArgument(args, "--silent");
        try
        {
            string installerPath = Assembly.GetExecutingAssembly().Location;
            string installerDirectory = Path.GetDirectoryName(installerPath);
            if (String.IsNullOrEmpty(installerDirectory))
            {
                throw new InvalidOperationException("Cannot determine installer directory.");
            }

            InstallOptions options;
            if (silent)
            {
                options = ParseSilentOptions(args, installerDirectory);
            }
            else
            {
                if (args.Length != 0)
                {
                    throw new InvalidOperationException("Unknown installer argument.");
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (InstallDialog dialog = new InstallDialog(
                    GetDefaultTargetDirectory(installerDirectory)
                ))
                {
                    if (dialog.ShowDialog() != DialogResult.OK)
                    {
                        return 0;
                    }
                    options = new InstallOptions();
                    options.TargetDirectory = dialog.TargetDirectory;
                    options.CreateShortcut = dialog.CreateShortcut;
                    options.Silent = false;
                    options.ForceClose = false;
                }
            }

            bool installed = InstallOrUpdate(
                options,
                installerPath
            );
            if (!installed)
            {
                return 0;
            }
            string appPath = Path.Combine(options.TargetDirectory, "HarborProxy.exe");
            if (!File.Exists(appPath))
            {
                throw new InvalidDataException("HarborProxy.exe is missing from the package.");
            }

            if (!options.Silent)
            {
                string shortcutResult = options.CreateShortcut
                    ? "，并已创建桌面快捷方式"
                    : String.Empty;
                MessageBox.Show(
                    "HarborProxy 已安装或更新到：\r\n"
                        + options.TargetDirectory + shortcutResult + "。",
                    "HarborProxy",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!silent)
            {
                MessageBox.Show(
                    "安装或更新失败：" + error.Message,
                    "HarborProxy",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
            return 1;
        }
    }

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string argument in args)
        {
            if (String.Equals(argument, expected, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static InstallOptions ParseSilentOptions(string[] args, string installerDirectory)
    {
        InstallOptions options = new InstallOptions();
        options.TargetDirectory = GetDefaultTargetDirectory(installerDirectory);
        options.CreateShortcut = true;
        options.Silent = true;
        options.ForceClose = false;

        for (int index = 0; index < args.Length; index++)
        {
            string argument = args[index];
            if (String.Equals(argument, "--silent", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (String.Equals(argument, "--shortcut", StringComparison.OrdinalIgnoreCase))
            {
                options.CreateShortcut = true;
                continue;
            }
            if (String.Equals(argument, "--no-shortcut", StringComparison.OrdinalIgnoreCase))
            {
                options.CreateShortcut = false;
                continue;
            }
            if (String.Equals(argument, "--force-close", StringComparison.OrdinalIgnoreCase))
            {
                options.ForceClose = true;
                continue;
            }
            if (String.Equals(argument, "--target", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 >= args.Length)
                {
                    throw new InvalidOperationException("--target requires a directory.");
                }
                options.TargetDirectory = Path.GetFullPath(args[++index]);
                continue;
            }
            throw new InvalidOperationException("Unknown installer argument.");
        }
        return options;
    }

    private static string GetDefaultTargetDirectory(string installerDirectory)
    {
        string existing = FindExistingInstallDirectory(installerDirectory);
        if (!String.IsNullOrEmpty(existing))
        {
            return existing;
        }
        string localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData
        );
        if (String.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Cannot determine the local application directory.");
        }
        return Path.Combine(localAppData, "Programs", "HarborProxy");
    }

    private static string FindExistingInstallDirectory(string installerDirectory)
    {
        List<string> candidates = new List<string>();

        foreach (ManagedProcess process in GetRunningManagedProcesses(null))
        {
            AddCandidate(candidates, Path.GetDirectoryName(process.ExecutablePath));
        }

        try
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(InstallerRegistryPath))
            {
                if (key != null)
                {
                    AddCandidate(
                        candidates,
                        Convert.ToString(key.GetValue(InstallLocationValue, String.Empty))
                    );
                }
            }
        }
        catch
        {
            // Continue with shortcuts and bounded conventional locations.
        }

        foreach (string shortcutPath in GetKnownShortcutPaths())
        {
            string target = ReadShortcutTarget(shortcutPath);
            if (!String.IsNullOrEmpty(target) &&
                String.Equals(
                    Path.GetFileName(target),
                    "HarborProxy.exe",
                    StringComparison.OrdinalIgnoreCase
                ))
            {
                AddCandidate(candidates, Path.GetDirectoryName(target));
            }
        }

        string localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData
        );
        if (!String.IsNullOrWhiteSpace(localAppData))
        {
            AddCandidate(candidates, Path.Combine(localAppData, "Programs", "HarborProxy"));
        }
        AddCandidate(candidates, Path.Combine(installerDirectory, "HarborProxy"));

        try
        {
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                if (drive.DriveType != DriveType.Fixed || !drive.IsReady)
                {
                    continue;
                }
                string root = drive.RootDirectory.FullName;
                AddCandidate(candidates, Path.Combine(root, "HarborProxy"));
                AddCandidate(candidates, Path.Combine(root, "Apps", "HarborProxy"));
                AddCandidate(candidates, Path.Combine(root, "Programs", "HarborProxy"));
                AddCandidate(candidates, Path.Combine(root, "PortableApps", "HarborProxy"));
                AddCandidate(candidates, Path.Combine(root, "Program Files", "HarborProxy"));
                AddCandidate(candidates, Path.Combine(root, "Program Files (x86)", "HarborProxy"));
            }
        }
        catch
        {
            // A disconnected drive must not block a per-user installation.
        }

        foreach (string candidate in candidates)
        {
            if (HasInstallIdentity(candidate))
            {
                return Path.GetFullPath(candidate).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                );
            }
        }
        return null;
    }

    private static void AddCandidate(List<string> candidates, string candidate)
    {
        if (String.IsNullOrWhiteSpace(candidate))
        {
            return;
        }
        try
        {
            string resolved = Path.GetFullPath(
                Environment.ExpandEnvironmentVariables(candidate.Trim())
            ).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            foreach (string existing in candidates)
            {
                if (String.Equals(existing, resolved, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
            }
            candidates.Add(resolved);
        }
        catch
        {
            // Ignore malformed stale registry or shortcut values.
        }
    }

    private static string[] GetKnownShortcutPaths()
    {
        return new string[]
        {
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                "HarborProxy.lnk"
            ),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
                "Programs",
                "HarborProxy.lnk"
            ),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
                "Programs",
                "HarborProxy.lnk"
            )
        };
    }

    private static string ReadShortcutTarget(string shortcutPath)
    {
        if (!File.Exists(shortcutPath))
        {
            return null;
        }
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null)
        {
            return null;
        }
        object shell = null;
        object shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                null,
                shell,
                new object[] { shortcutPath }
            );
            object target = shortcut.GetType().InvokeMember(
                "TargetPath",
                BindingFlags.GetProperty,
                null,
                shortcut,
                new object[0]
            );
            return Convert.ToString(target);
        }
        catch
        {
            return null;
        }
        finally
        {
            if (shortcut != null && Marshal.IsComObject(shortcut))
            {
                Marshal.FinalReleaseComObject(shortcut);
            }
            if (shell != null && Marshal.IsComObject(shell))
            {
                Marshal.FinalReleaseComObject(shell);
            }
        }
    }

    private static bool InstallOrUpdate(InstallOptions options, string installerPath)
    {
        string target = ValidateTargetDirectory(options.TargetDirectory, installerPath);
        options.TargetDirectory = target;

        string parent = Path.GetDirectoryName(target);
        if (String.IsNullOrEmpty(parent))
        {
            throw new InvalidOperationException("Cannot determine the installation parent directory.");
        }
        Directory.CreateDirectory(parent);

        string token = Guid.NewGuid().ToString("N");
        string leaf = Path.GetFileName(target);
        string stage = Path.Combine(parent, "." + leaf + ".stage-" + token);
        string backup = Path.Combine(parent, "." + leaf + ".backup-" + token);
        bool oldMoved = false;
        bool newMoved = false;
        bool complete = false;
        HelperServiceSnapshot helperSnapshot = CaptureHelperServiceSnapshot();

        try
        {
            ExtractPayload(stage);
            if (!HasInstallIdentity(stage))
            {
                throw new InvalidDataException("The extracted HarborProxy payload is incomplete.");
            }

            StopHelperServiceForUpdate(helperSnapshot);
            if (!EnsureTargetProcessesClosed(target, options))
            {
                RestoreHelperService(helperSnapshot);
                return false;
            }

            if (Directory.Exists(target))
            {
                Directory.Move(target, backup);
                oldMoved = true;
            }
            Directory.Move(stage, target);
            newMoved = true;

            ConfigureAndVerifyHelperService(target);

            string appPath = Path.Combine(target, "HarborProxy.exe");
            if (options.CreateShortcut)
            {
                CreateDesktopShortcut(appPath, target);
            }
            RecordInstallLocation(target);
            complete = true;
            return true;
        }
        catch (Exception installError)
        {
            Exception rollbackError = null;
            try
            {
                StopHelperServiceIfPresent();
            }
            catch (Exception error)
            {
                rollbackError = error;
            }
            if (newMoved && Directory.Exists(target))
            {
                try
                {
                    Directory.Delete(target, true);
                }
                catch
                {
                    // The original restore below will fail closed if this directory is locked.
                }
            }
            if (oldMoved && Directory.Exists(backup) && !Directory.Exists(target))
            {
                Directory.Move(backup, target);
                oldMoved = false;
            }
            try
            {
                RestoreHelperService(helperSnapshot);
            }
            catch (Exception error)
            {
                rollbackError = rollbackError ?? error;
            }
            if (rollbackError != null)
            {
                throw new InvalidOperationException(
                    installError.Message + " Rollback failed: " + rollbackError.Message,
                    installError
                );
            }
            throw;
        }
        finally
        {
            DeleteDirectoryBestEffort(stage);
            if (complete)
            {
                DeleteDirectoryBestEffort(backup);
            }
        }
    }

    private static string ValidateTargetDirectory(string targetDirectory, string installerPath)
    {
        if (String.IsNullOrWhiteSpace(targetDirectory) || targetDirectory.IndexOf('"') >= 0)
        {
            throw new InvalidOperationException("请选择有效的安装目录。");
        }
        string resolved = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(targetDirectory.Trim())
        ).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string root = Path.GetPathRoot(resolved);
        if (String.IsNullOrEmpty(root) ||
            String.Equals(
                resolved,
                root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase
            ))
        {
            throw new InvalidOperationException("不能把磁盘根目录作为安装目录。");
        }

        foreach (Environment.SpecialFolder folder in new Environment.SpecialFolder[]
        {
            Environment.SpecialFolder.UserProfile,
            Environment.SpecialFolder.Windows,
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolder.DesktopDirectory
        })
        {
            string special = Environment.GetFolderPath(folder);
            if (!String.IsNullOrWhiteSpace(special) &&
                PathsEqual(resolved, special))
            {
                throw new InvalidOperationException("所选目录范围过大，请选择专用的 HarborProxy 目录。");
            }
        }

        if (IsPathInside(installerPath, resolved))
        {
            throw new InvalidOperationException(
                "安装包位于目标目录内，请先把安装包移到下载目录后再更新。"
            );
        }

        if (Directory.Exists(resolved))
        {
            if ((File.GetAttributes(resolved) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("安装目录不能是符号链接或目录联接点。");
            }
            bool hasEntries;
            try
            {
                using (IEnumerator<string> entries =
                    Directory.EnumerateFileSystemEntries(resolved).GetEnumerator())
                {
                    hasEntries = entries.MoveNext();
                }
            }
            catch (Exception error)
            {
                throw new InvalidOperationException("无法检查目标目录：" + error.Message);
            }
            if (hasEntries && !HasInstallIdentity(resolved))
            {
                throw new InvalidOperationException(
                    "目标目录不是可识别的 HarborProxy 安装目录，且并非空目录。"
                );
            }
        }
        return resolved;
    }

    private static bool HasInstallIdentity(string directory)
    {
        if (String.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            return false;
        }
        foreach (string executable in ManagedExecutableNames)
        {
            if (!File.Exists(Path.Combine(directory, executable)))
            {
                return false;
            }
        }
        return Directory.Exists(Path.Combine(directory, "data", "flutter_assets"));
    }

    private static void RecordInstallLocation(string target)
    {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(InstallerRegistryPath))
        {
            if (key == null)
            {
                throw new InvalidOperationException("Cannot record the HarborProxy install location.");
            }
            key.SetValue(InstallLocationValue, target, RegistryValueKind.String);
        }
    }

    private static bool EnsureTargetProcessesClosed(string target, InstallOptions options)
    {
        List<ManagedProcess> running = GetRunningManagedProcesses(target);
        if (running.Count == 0)
        {
            return true;
        }

        if (!options.ForceClose)
        {
            if (options.Silent)
            {
                throw new InvalidOperationException(
                    "HarborProxy is running. Re-run with --force-close after saving your work."
                );
            }
            string processSummary = BuildProcessSummary(running);
            DialogResult answer = MessageBox.Show(
                "检测到安装目录中的 HarborProxy 程序仍在运行：\r\n"
                    + processSummary
                    + "\r\n\r\n继续更新将强制关闭这些程序，是否继续？",
                "HarborProxy 更新",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2
            );
            if (answer != DialogResult.Yes)
            {
                return false;
            }
        }

        running = GetRunningManagedProcesses(target);

        foreach (ManagedProcess managed in running)
        {
            if (String.Equals(
                managed.Name,
                "HarborProxyHelperService.exe",
                StringComparison.OrdinalIgnoreCase
            ))
            {
                continue;
            }
            try
            {
                using (Process process = Process.GetProcessById(managed.Id))
                {
                    if (!ProcessStillBelongsToTarget(process, managed, target))
                    {
                        continue;
                    }
                    process.CloseMainWindow();
                }
            }
            catch
            {
                // Revalidate immediately before the forced termination below.
            }
        }
        WaitForTargetProcesses(target, 1500);

        running = GetRunningManagedProcesses(target);
        foreach (ManagedProcess managed in running)
        {
            try
            {
                using (Process process = Process.GetProcessById(managed.Id))
                {
                    if (!ProcessStillBelongsToTarget(process, managed, target))
                    {
                        continue;
                    }
                    process.Kill();
                }
            }
            catch
            {
                // A final exact-path check below reports anything still locking the payload.
            }
        }
        WaitForTargetProcesses(target, 5000);

        running = GetRunningManagedProcesses(target);
        if (running.Count != 0)
        {
            throw new InvalidOperationException(
                "无法关闭安装目录中的程序：" + BuildProcessSummary(running)
                    + "。请手动退出后重试。"
            );
        }
        return true;
    }

    private static string BuildProcessSummary(List<ManagedProcess> processes)
    {
        List<string> names = new List<string>();
        foreach (ManagedProcess process in processes)
        {
            string label = process.Name + " (PID " + process.Id + ")";
            if (!names.Contains(label))
            {
                names.Add(label);
            }
        }
        return String.Join("、", names.ToArray());
    }

    private static void WaitForTargetProcesses(string target, int milliseconds)
    {
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < milliseconds)
        {
            if (GetRunningManagedProcesses(target).Count == 0)
            {
                return;
            }
            System.Threading.Thread.Sleep(100);
        }
    }

    private static List<ManagedProcess> GetRunningManagedProcesses(string target)
    {
        List<ManagedProcess> result = new List<ManagedProcess>();
        HashSet<int> seen = new HashSet<int>();
        foreach (string executableName in ManagedExecutableNames)
        {
            string processName = Path.GetFileNameWithoutExtension(executableName);
            Process[] processes;
            try
            {
                processes = Process.GetProcessesByName(processName);
            }
            catch
            {
                continue;
            }
            foreach (Process process in processes)
            {
                using (process)
                {
                    if (seen.Contains(process.Id))
                    {
                        continue;
                    }
                    string path = TryGetProcessExecutablePath(process.Id);
                    if (String.IsNullOrEmpty(path) ||
                        !String.Equals(
                            Path.GetFileName(path),
                            executableName,
                            StringComparison.OrdinalIgnoreCase
                        ))
                    {
                        continue;
                    }
                    if (target != null && !PathsEqual(Path.GetDirectoryName(path), target))
                    {
                        continue;
                    }
                    ManagedProcess managed = new ManagedProcess();
                    managed.Id = process.Id;
                    managed.Name = executableName;
                    managed.ExecutablePath = path;
                    result.Add(managed);
                    seen.Add(process.Id);
                }
            }
        }
        return result;
    }

    private static bool ProcessStillBelongsToTarget(
        Process process,
        ManagedProcess expected,
        string target
    )
    {
        string currentPath = TryGetProcessExecutablePath(process.Id);
        return !String.IsNullOrEmpty(currentPath)
            && PathsEqual(currentPath, expected.ExecutablePath)
            && PathsEqual(Path.GetDirectoryName(currentPath), target)
            && String.Equals(
                Path.GetFileName(currentPath),
                expected.Name,
                StringComparison.OrdinalIgnoreCase
            );
    }

    private static string TryGetProcessExecutablePath(int processId)
    {
        IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (handle == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            StringBuilder buffer = new StringBuilder(32768);
            int size = buffer.Capacity;
            if (!QueryFullProcessImageName(handle, 0, buffer, ref size))
            {
                return null;
            }
            return Path.GetFullPath(buffer.ToString());
        }
        catch
        {
            return null;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static HelperServiceSnapshot CaptureHelperServiceSnapshot()
    {
        HelperServiceSnapshot snapshot = new HelperServiceSnapshot();
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
            @"SYSTEM\CurrentControlSet\Services\" + HelperServiceName
        ))
        {
            if (key == null)
            {
                snapshot.Exists = false;
                return snapshot;
            }
            snapshot.Exists = true;
            snapshot.ImagePath = ParseServiceExecutablePath(
                Convert.ToString(key.GetValue("ImagePath", String.Empty))
            );
            snapshot.StartMode = Convert.ToInt32(key.GetValue("Start", 3));
        }
        snapshot.WasRunning = IsHelperServiceRunning();
        return snapshot;
    }

    private static void StopHelperServiceForUpdate(HelperServiceSnapshot snapshot)
    {
        if (!snapshot.Exists || !snapshot.WasRunning)
        {
            return;
        }
        StopHelperServiceIfPresent();
    }

    private static void StopHelperServiceIfPresent()
    {
        if (!ServiceExists() || !IsHelperServiceRunning())
        {
            return;
        }
        int exitCode = RunSc("stop " + HelperServiceName);
        if (exitCode != 0 && IsHelperServiceRunning())
        {
            throw new InvalidOperationException("service_stop_failed");
        }
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < 15000)
        {
            if (!IsHelperServiceRunning())
            {
                return;
            }
            System.Threading.Thread.Sleep(200);
        }
        throw new InvalidOperationException("service_stop_failed");
    }

    private static void ConfigureAndVerifyHelperService(string target)
    {
        string helperPath = Path.Combine(target, "HarborProxyHelperService.exe");
        string corePath = Path.Combine(target, "HarborProxyCore.exe");
        if (!File.Exists(helperPath) || !File.Exists(corePath))
        {
            throw new InvalidDataException("core_hash_mismatch");
        }
        string quotedHelper = QuoteServiceBinaryPathArgument(helperPath);
        int exitCode;
        if (ServiceExists())
        {
            exitCode = RunSc(
                "config " + HelperServiceName + " binPath= "
                    + quotedHelper + " start= demand"
            );
        }
        else
        {
            exitCode = RunSc(
                "create " + HelperServiceName + " binPath= "
                    + quotedHelper
                    + " start= demand DisplayName= "
                    + QuoteArgument("HarborProxy Helper Service")
            );
        }
        if (exitCode != 0)
        {
            throw new InvalidOperationException("service_create_failed");
        }
        if (!PathsEqual(GetHelperServiceBinaryPath(), helperPath))
        {
            throw new InvalidOperationException("imagepath_mismatch");
        }
        exitCode = RunSc("start " + HelperServiceName);
        if (exitCode != 0 && !IsHelperServiceRunning())
        {
            throw new InvalidOperationException("service_start_failed");
        }
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < 15000 && !IsHelperServiceRunning())
        {
            System.Threading.Thread.Sleep(200);
        }
        if (!IsHelperServiceRunning())
        {
            throw new InvalidOperationException("service_start_failed");
        }
        VerifyHelperPing(corePath);
    }

    private static void VerifyHelperPing(string corePath)
    {
        string expectedHash = CalculateSha256(corePath);
        Exception lastError = null;
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < 15000)
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
                    "http://127.0.0.1:47890/ping"
                );
                request.Proxy = null;
                request.Timeout = 1000;
                request.ReadWriteTimeout = 1000;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream()))
                {
                    string actualHash = reader.ReadToEnd();
                    if (String.Equals(
                        actualHash,
                        expectedHash,
                        StringComparison.OrdinalIgnoreCase
                    ))
                    {
                        return;
                    }
                    throw new InvalidOperationException("helper_token_mismatch");
                }
            }
            catch (InvalidOperationException)
            {
                throw;
            }
            catch (Exception error)
            {
                lastError = error;
                System.Threading.Thread.Sleep(250);
            }
        }
        throw new InvalidOperationException(
            "helper_unreachable",
            lastError
        );
    }

    private static string CalculateSha256(string path)
    {
        using (SHA256 algorithm = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] digest = algorithm.ComputeHash(stream);
            StringBuilder output = new StringBuilder(digest.Length * 2);
            foreach (byte value in digest)
            {
                output.Append(value.ToString("x2"));
            }
            return output.ToString();
        }
    }

    private static void RestoreHelperService(HelperServiceSnapshot snapshot)
    {
        StopHelperServiceIfPresent();
        if (!snapshot.Exists)
        {
            if (ServiceExists() && RunSc("delete " + HelperServiceName) != 0)
            {
                throw new InvalidOperationException("service_delete_failed");
            }
            return;
        }
        if (String.IsNullOrWhiteSpace(snapshot.ImagePath))
        {
            throw new InvalidOperationException("imagepath_mismatch");
        }
        string quotedHelper = QuoteServiceBinaryPathArgument(snapshot.ImagePath);
        string startMode = ServiceStartModeArgument(snapshot.StartMode);
        int exitCode;
        if (ServiceExists())
        {
            exitCode = RunSc(
                "config " + HelperServiceName + " binPath= "
                    + quotedHelper + " start= " + startMode
            );
        }
        else
        {
            exitCode = RunSc(
                "create " + HelperServiceName + " binPath= "
                    + quotedHelper + " start= " + startMode
            );
        }
        if (exitCode != 0 ||
            !PathsEqual(GetHelperServiceBinaryPath(), snapshot.ImagePath))
        {
            throw new InvalidOperationException("imagepath_mismatch");
        }
        if (snapshot.WasRunning && RunSc("start " + HelperServiceName) != 0 &&
            !IsHelperServiceRunning())
        {
            throw new InvalidOperationException("service_start_failed");
        }
    }

    private static string ServiceStartModeArgument(int startMode)
    {
        switch (startMode)
        {
            case 2:
                return "auto";
            case 4:
                return "disabled";
            default:
                return "demand";
        }
    }

    private static int RunSc(string arguments)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = "sc.exe";
        start.Arguments = arguments;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using (Process process = Process.Start(start))
        {
            process.StandardOutput.ReadToEnd();
            process.StandardError.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static bool ServiceExists()
    {
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
            @"SYSTEM\CurrentControlSet\Services\" + HelperServiceName
        ))
        {
            return key != null;
        }
    }

    private static bool IsHelperServiceRunning()
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = "sc.exe";
        start.Arguments = "query " + HelperServiceName;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using (Process process = Process.Start(start))
        {
            string output = process.StandardOutput.ReadToEnd();
            process.StandardError.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode == 0 && output.IndexOf(
                "RUNNING",
                StringComparison.OrdinalIgnoreCase
            ) >= 0;
        }
    }

    private static string GetHelperServiceBinaryPath()
    {
        try
        {
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                @"SYSTEM\CurrentControlSet\Services\" + HelperServiceName
            ))
            {
                if (key == null)
                {
                    return null;
                }
                return ParseServiceExecutablePath(
                    Convert.ToString(key.GetValue("ImagePath", String.Empty))
                );
            }
        }
        catch
        {
            return null;
        }
    }

    private static string ParseServiceExecutablePath(string imagePath)
    {
        if (String.IsNullOrWhiteSpace(imagePath))
        {
            return null;
        }
        imagePath = Environment.ExpandEnvironmentVariables(imagePath.Trim());
        string executable;
        if (imagePath.StartsWith("\"", StringComparison.Ordinal))
        {
            int closing = imagePath.IndexOf('"', 1);
            if (closing <= 1)
            {
                return null;
            }
            executable = imagePath.Substring(1, closing - 1);
        }
        else
        {
            int space = imagePath.IndexOf(' ');
            executable = space > 0 ? imagePath.Substring(0, space) : imagePath;
        }
        return Path.GetFullPath(executable);
    }

    private static string QuoteServiceBinaryPathArgument(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || path.IndexOf('"') >= 0)
        {
            throw new InvalidOperationException("imagepath_mismatch");
        }
        return "\"\\\"" + Path.GetFullPath(path) + "\\\"\"";
    }

    private static bool PathsEqual(string left, string right)
    {
        if (String.IsNullOrWhiteSpace(left) || String.IsNullOrWhiteSpace(right))
        {
            return false;
        }
        try
        {
            return String.Equals(
                Path.GetFullPath(left).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                ),
                Path.GetFullPath(right).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                ),
                StringComparison.OrdinalIgnoreCase
            );
        }
        catch
        {
            return false;
        }
    }

    private static bool IsPathInside(string path, string directory)
    {
        string resolvedPath = Path.GetFullPath(path);
        string resolvedDirectory = Path.GetFullPath(directory).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar
        ) + Path.DirectorySeparatorChar;
        return resolvedPath.StartsWith(resolvedDirectory, StringComparison.OrdinalIgnoreCase);
    }

    private static void DeleteDirectoryBestEffort(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch
        {
            // A later run uses a new GUID and never trusts stale staging directories.
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(
        uint desiredAccess,
        bool inheritHandle,
        int processId
    );

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(
        IntPtr process,
        int flags,
        StringBuilder executableName,
        ref int size
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static void ExtractPayload(string targetDirectory)
    {
        string resolvedTarget = Path.GetFullPath(targetDirectory);
        if (resolvedTarget.IndexOf('"') >= 0)
        {
            throw new InvalidOperationException("The extraction path contains an invalid quote.");
        }
        Directory.CreateDirectory(resolvedTarget);

        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            "HarborProxySfx-" + Guid.NewGuid().ToString("N")
        );
        Directory.CreateDirectory(temporaryDirectory);
        try
        {
            string extractorPath = Path.Combine(temporaryDirectory, "7zr.exe");
            string payloadPath = Path.Combine(temporaryDirectory, "payload.7z");
            WriteResource(ExtractorResource, extractorPath);
            WriteResource(PayloadResource, payloadPath);

            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = extractorPath;
            start.Arguments = "x " + QuoteArgument(payloadPath)
                + " -o" + QuoteArgument(resolvedTarget)
                + " -y -aoa -bd -bso0 -bsp0";
            start.WorkingDirectory = temporaryDirectory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardError = true;

            using (Process process = Process.Start(start))
            {
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidDataException(
                        "7z extraction failed with exit code " + process.ExitCode + ". "
                        + error.Trim()
                    );
                }
            }
        }
        finally
        {
            try
            {
                Directory.Delete(temporaryDirectory, true);
            }
            catch
            {
                // The extracted application is complete; stale temporary files are harmless.
            }
        }
    }

    private static void WriteResource(string resourceName, string destination)
    {
        Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName);
        if (resource == null)
        {
            throw new InvalidDataException("Embedded installer resource is missing.");
        }
        using (resource)
        using (FileStream output = new FileStream(
            destination,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None
        ))
        {
            resource.CopyTo(output);
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value.IndexOf('"') >= 0)
        {
            throw new InvalidOperationException("A path contains an invalid quote.");
        }
        return "\"" + value + "\"";
    }

    private static void CreateDesktopShortcut(string appPath, string workingDirectory)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null)
        {
            throw new InvalidOperationException("Windows shortcut service is unavailable.");
        }

        object shell = Activator.CreateInstance(shellType);
        object shortcut = null;
        try
        {
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string shortcutPath = Path.Combine(desktop, "HarborProxy.lnk");
            shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                null,
                shell,
                new object[] { shortcutPath }
            );
            Type shortcutType = shortcut.GetType();
            shortcutType.InvokeMember(
                "TargetPath",
                BindingFlags.SetProperty,
                null,
                shortcut,
                new object[] { appPath }
            );
            shortcutType.InvokeMember(
                "WorkingDirectory",
                BindingFlags.SetProperty,
                null,
                shortcut,
                new object[] { workingDirectory }
            );
            shortcutType.InvokeMember(
                "IconLocation",
                BindingFlags.SetProperty,
                null,
                shortcut,
                new object[] { appPath + ",0" }
            );
            shortcutType.InvokeMember(
                "Save",
                BindingFlags.InvokeMethod,
                null,
                shortcut,
                new object[0]
            );
        }
        finally
        {
            if (shortcut != null && Marshal.IsComObject(shortcut))
            {
                Marshal.FinalReleaseComObject(shortcut);
            }
            if (shell != null && Marshal.IsComObject(shell))
            {
                Marshal.FinalReleaseComObject(shell);
            }
        }
    }
}
