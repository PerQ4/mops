; Установщик mOps для Windows.
;
; Собирается в конвейере после сборки приложения: Inno Setup берёт готовую
; папку сборки и делает обычный установщик с ярлыком в меню «Пуск».
; Версию передаём ключом /DAppVersion=<тег>; значение ниже — только запасное,
; для ручной сборки без ключа, и его надо держать тем же, что в pubspec.yaml.
#ifndef AppVersion
  #define AppVersion "0.2.12"
#endif

[Setup]
AppName=mOps
AppVersion={#AppVersion}
AppPublisher=mOps
DefaultDirName={autopf}\mOps
DefaultGroupName=mOps
OutputDir=Output
OutputBaseFilename=mops-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 64-битное приложение: ставим в Program Files, а не в x86.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
; Папка сборки Flutter: exe, DLL (включая libmpv) и data.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\mOps"; Filename: "{app}\mops.exe"
Name: "{group}\Удалить mOps"; Filename: "{uninstallexe}"
Name: "{autodesktop}\mOps"; Filename: "{app}\mops.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительно:"

[Run]
Filename: "{app}\mops.exe"; Description: "Запустить mOps"; Flags: nowait postinstall skipifsilent
