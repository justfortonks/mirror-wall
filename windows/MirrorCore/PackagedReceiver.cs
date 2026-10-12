namespace MirrorWall.Core;

/// <summary>
/// The uxplay that ships with Mirror Wall, with its own GStreamer, as
/// windows/receiver/build-uxplay.sh lays it out next to the app:
/// <code>
///     receiver\uxplay.exe, receiver\gst-plugin-scanner.exe, receiver\*.dll
///     receiver\lib\gstreamer-1.0\*.dll      (plugins)
/// </code>
/// </summary>
public static class PackagedReceiver
{
    public const string ExecutableName = "uxplay.exe";

    /// <summary>
    /// The environment for running a packaged uxplay: GStreamer is told to use only the plugins
    /// that came with it, and to keep its plugin registry in the app's own file rather than one
    /// another GStreamer on the same PC uses. With MIRROR_WALL_QUIT_ON_EOF, closing uxplay's input
    /// stops it cleanly (windows/receiver/uxplay-windows.patch).
    ///
    /// Returns null for any other uxplay (one with no plugins folder beside it), which simply
    /// inherits the app's environment.
    /// </summary>
    public static Dictionary<string, string>? Environment(
        string executablePath, IReadOnlyDictionary<string, string> inherited, string registryPath, Func<string, bool> directoryExists)
    {
        string? folder = Path.GetDirectoryName(executablePath);
        if (folder == null) return null;
        string plugins = Path.Combine(folder, "lib", "gstreamer-1.0");
        if (!directoryExists(plugins)) return null;

        var environment = new Dictionary<string, string>(inherited, StringComparer.OrdinalIgnoreCase);
        environment["GST_PLUGIN_SYSTEM_PATH"] = plugins;
        environment.Remove("GST_PLUGIN_PATH");
        environment["GST_PLUGIN_SCANNER"] = Path.Combine(folder, "gst-plugin-scanner.exe");
        environment["GST_REGISTRY"] = registryPath;
        environment["MIRROR_WALL_QUIT_ON_EOF"] = "1";
        return environment;
    }
}
