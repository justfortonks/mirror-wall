; Mirror Wall's installer: the app, its receiver (uxplay with GStreamer and FFmpeg), and Windows
; Firewall rules so iPhones on the network can reach the receiver and Android phones the app, on
; Private and Domain networks and, unless unticked, on Public ones too.
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
; Adding the firewall rules needs an administrator.
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
; Windows marks most new Wi-Fi networks Public, and then blocks every phone unless an app has a
; rule for Public networks too. That rule only lets in devices on the PC's own subnet, as Windows'
; own Cast to Device and mDNS rules do.
Name: "publicnetworks"; Description: "Also allow phones on Public networks (devices on the same Wi-Fi only)"; GroupDescription: "Network:"

[Files]
Source: "..\dist\MirrorWall\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Mirror Wall"; Filename: "{app}\MirrorWall.exe"
Name: "{autodesktop}\Mirror Wall"; Filename: "{app}\MirrorWall.exe"; Tasks: desktopicon

[Run]
; Clears every rule for the receiver and the app first: rules from an earlier install, and the
; Block rules Windows adds by itself if someone cancels its "Allow access?" prompt, which would
; win over any Allow rule.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\receiver\uxplay.exe"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\MirrorWall.exe"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall Android phones"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver (Public)"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall Android phones (Public)"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall phone discovery (Public)"""; Flags: runhidden
; The receiver (AirPlay and its own mDNS listing) on home and work networks.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall receiver"" dir=in action=allow program=""{app}\receiver\uxplay.exe"" enable=yes profile=private,domain"; Flags: runhidden
; Android phones (Mirror Wall Cast) connect to the app itself, on each slot's cast port: 7350 for
; slot 1, 7450 for slot 2, ... up to slot 8 (SlotStore.MaxSlots). Same networks as above.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall Android phones"" dir=in action=allow program=""{app}\MirrorWall.exe"" protocol=TCP localport=7350,7450,7550,7650,7750,7850,7950,8050 enable=yes profile=private,domain"; Flags: runhidden
; The same two on Public networks, from the local subnet only. The app lists its slots for Android
; phones with Windows' own mDNS (the DNS Client service), so its replies need UDP 5353 open too;
; Windows usually has that open already, and this makes sure.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall receiver (Public)"" dir=in action=allow program=""{app}\receiver\uxplay.exe"" remoteip=localsubnet enable=yes profile=public"; Flags: runhidden; Tasks: publicnetworks
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall Android phones (Public)"" dir=in action=allow program=""{app}\MirrorWall.exe"" protocol=TCP localport=7350,7450,7550,7650,7750,7850,7950,8050 remoteip=localsubnet enable=yes profile=public"; Flags: runhidden; Tasks: publicnetworks
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Mirror Wall phone discovery (Public)"" dir=in action=allow program=""{sys}\svchost.exe"" service=dnscache protocol=UDP localport=5353 remoteip=localsubnet enable=yes profile=public"; Flags: runhidden; Tasks: publicnetworks
Filename: "{app}\MirrorWall.exe"; Description: "Open Mirror Wall"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall Android phones"""; Flags: runhidden; RunOnceId: "RemoveCastFirewallRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall receiver (Public)"""; Flags: runhidden; RunOnceId: "RemovePublicFirewallRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall Android phones (Public)"""; Flags: runhidden; RunOnceId: "RemovePublicCastFirewallRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Mirror Wall phone discovery (Public)"""; Flags: runhidden; RunOnceId: "RemovePublicDiscoveryRule"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\receiver\uxplay.exe"""; Flags: runhidden; RunOnceId: "RemoveReceiverRules"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\MirrorWall.exe"""; Flags: runhidden; RunOnceId: "RemoveAppRules"

[UninstallDelete]
; The GStreamer plugin list the app keeps beside its logs.
Type: files; Name: "{localappdata}\Mirror Wall\gstreamer-registry.bin"
