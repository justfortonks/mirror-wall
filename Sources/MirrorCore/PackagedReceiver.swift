/// A uxplay that ships with its own GStreamer, as `scripts/bundle-receiver.py` lays it out:
///
///     receiver/bin/uxplay
///     receiver/lib/*.dylib
///     receiver/lib/gstreamer-1.0/*.dylib      (plugins)
///     receiver/libexec/gst-plugin-scanner
///
/// MirrorWall.app carries one in `Contents/Resources`, so it runs on a Mac with nothing else
/// installed.
public enum PackagedReceiver {
    /// Where the receiver sits inside the app's resources folder.
    public static let executablePathInResources = "receiver/bin/uxplay"

    /// The environment for running a packaged uxplay: GStreamer is told to use only the plugins
    /// that came with it, and to keep its plugin registry in the app's own cache file rather than
    /// the one a Homebrew GStreamer on the same Mac uses.
    ///
    /// Returns nil for any other uxplay (e.g. one built against Homebrew), which should simply
    /// inherit the app's environment.
    public static func environment(
        forExecutableAt path: String,
        inheriting inherited: [String: String],
        registryPath: String,
        fileExists: (String) -> Bool
    ) -> [String: String]? {
        let suffix = "/bin/uxplay"
        guard path.hasSuffix(suffix) else { return nil }
        let root = String(path.dropLast(suffix.count))
        let plugins = root + "/lib/gstreamer-1.0"
        guard fileExists(plugins) else { return nil }

        var environment = inherited
        environment["GST_PLUGIN_SYSTEM_PATH"] = plugins
        environment["GST_PLUGIN_PATH"] = nil
        environment["GST_PLUGIN_SCANNER"] = root + "/libexec/gst-plugin-scanner"
        environment["GST_REGISTRY"] = registryPath
        return environment
    }
}
