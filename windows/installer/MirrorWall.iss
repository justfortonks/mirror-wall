; Mirror Wall's installer: the app, its receiver (uxplay with GStreamer and FFmpeg), and a
; Windows Firewall rule so iPhones on the network can reach the receiver.
; Built by the Windows workflow: ISCC /DAppVersion=0.N MirrorWall.iss

#ifndef AppVersion
  #define AppVersion "0.0"
#endif

[Setup]
AppId={{6C1A8E7B-3F2D-4B8E-9A51-0D7E2C4F9B13}
AppName=Mirror Wall
AppVersion={#AppVersion}
AppVerName=Mirror Wall {#AppVersion}
AppPublisher=Mirror Wall
DefaultDirName={autopf}\Mirror Wall
DefaultGroupName=Mirror Wall
DisableProgramGroupPage=yes
; Adding the firewall rule needs an administrator.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=MirrorWall-Setup
SetupIconFile=..\MirrorWall\AppIcon.ico
UninstallDisplayIcon={app}\MirrorWall.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Put Mirror Wall on the desktop"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\dist\MirrorWall\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Mirror Wall"; Filename: "{app}\MirrorWall.exe"
Name: "{autodesktop}\Mirror Wall"; Filename: "{app}\MirrorWall.exe"; Tasks: desktopicon

[Run]
; Replaces any rule from an earlier install, then lets the receiver accept connections on home
; and work networks (Private and Domain), not public Wi-Fi.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall receiver"" dir=in action=allow program=""{app}\receiver\uxplay.exe"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\MirrorWall.exe"; Description: "Open Mirror Wall"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
; The GStreamer plugin list the app keeps beside its logs.
Type: files; Name: "{localappdata}\Mirror Wall\gstreamer-registry.bin"
