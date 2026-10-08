// Win11Migrator portable launcher.
// Carries the application as an embedded zip, unpacks it once per version under
// %LOCALAPPDATA%\Win11Migrator\portable\<version>, and starts the PowerShell GUI elevated in a
// normal, visible window. Nothing is hidden and no security settings are touched.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

static class PortableLauncher
{
    const int ErrorCancelled = 1223;

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string root = Unpack();
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(root, "Win11Migrator.ps1");
            ProcessStartInfo info = new ProcessStartInfo(powershell,
                "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script) + PassThrough(args))
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = root
            };
            Process.Start(info);
            return 0;
        }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == ErrorCancelled) return ErrorCancelled;
            Show(ex);
            return 1;
        }
        catch (Exception ex)
        {
            Show(ex);
            return 1;
        }
    }

    static string Unpack()
    {
        Assembly self = Assembly.GetExecutingAssembly();
        string version = FileVersionInfo.GetVersionInfo(self.Location).FileVersion;
        string root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Path.Combine("Win11Migrator", Path.Combine("portable", version)));
        string marker = Path.Combine(root, ".unpacked");
        if (File.Exists(marker)) return root;

        // A half-finished earlier unpack is discarded rather than trusted
        if (Directory.Exists(root)) Directory.Delete(root, true);
        Directory.CreateDirectory(root);
        using (Stream payload = self.GetManifestResourceStream("payload.zip"))
        using (ZipArchive zip = new ZipArchive(payload, ZipArchiveMode.Read))
        {
            zip.ExtractToDirectory(root);
        }
        File.WriteAllText(marker, version);
        return root;
    }

    static string PassThrough(string[] args)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string a in args) sb.Append(' ').Append(Quote(a));
        return sb.ToString();
    }

    static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    static void Show(Exception ex)
    {
        MessageBox.Show("Win11Migrator could not start.\r\n\r\n" + ex.Message, "Win11Migrator",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
