# WinGet Toolpack cho Windows 10/11 IoT Enterprise LTSC

Bộ script PowerShell để cài **WinGet (App Installer)** trên Windows không có Microsoft Store — đặc biệt dành cho **Windows 10/11 IoT Enterprise LTSC** và **Enterprise LTSC**.

> Đây là dự án **không chính thức**, không liên kết với Microsoft. WinGet và App Installer là sản phẩm của Microsoft. Mọi gói cài đều được tải từ release chính thức tại [microsoft/winget-cli](https://github.com/microsoft/winget-cli/releases) và được kiểm tra SHA256 cùng chữ ký Authenticode trước khi cài.

## Vì sao cần tool-pack này

LTSC và IoT LTSC không kèm Microsoft Store nên không có sẵn App Installer/WinGet. Cài thủ công bằng file `.msixbundle` thường vướng thiếu framework (VCLibs, UI.Xaml, WindowsAppRuntime) hoặc bị chặn sideload. Tool-pack tự xử lý các bước đó và ghi lại mọi thay đổi để có thể hoàn tác.

## Tính năng

- **Khảo sát read-only** bằng `check-status.ps1`: gói đã cài, provision, framework phụ thuộc, alias `winget`, policy sideload, phiên bản.
- **Cài đặt có kiểm chứng**: tải release mới nhất từ `microsoft/winget-cli`, đối chiếu SHA256 với file hash Microsoft công bố, kiểm tra chữ ký Authenticode `CN=Microsoft Corporation`.
- **Phát hiện WinGet đã có**: so phiên bản, hỏi cài lại hay bỏ qua; `-Reinstall` để cài đè.
- **Cài framework đúng kiến trúc** (x64 / ARM64 / x86) từ `DesktopAppInstaller_Dependencies.zip`.
- **Cài per-user + provision cho mọi user** (mặc định); `-Scope CurrentUser` nếu chỉ muốn user hiện tại.
- **Backup trước khi sửa**: registry, PATH, danh sách AppX; `undo.json` cho từng giá trị registry bị thay đổi.
- **Nhật ký thay đổi** `thay_doi_sys.md` (tự tạo trên máy chạy, không có trong repo).
- **`-DryRun`** cho mọi thao tác; gỡ/khôi phục bằng menu `uninstall_restore.bat`.
- **Tương thích console cũ**: UTF-8 và tự chuyển font Consolas để hiển thị đúng tiếng Việt.

## Yêu cầu

- Windows 10 1809+ hoặc Windows 11 (Enterprise / IoT Enterprise LTSC đều được).
- PowerShell 5.1 (có sẵn trên Windows).
- Quyền Administrator — script tự hiện hộp thoại UAC.
- Internet cho lần cài đầu (khoảng 207 MB cho bundle và dependencies). Có thể đặt sẵn file vào `cache\` để dùng lại.

## Bắt đầu nhanh

1. Tải repo: **Code → Download ZIP**, hoặc `git clone`.
2. Giải nén và mở PowerShell tại thư mục tool-pack.
3. Khảo sát trước (không sửa gì):

   ```powershell
   .\check-status.ps1 -Elevate
   ```

4. Diễn tập để xem chính xác những gì sẽ thay đổi:

   ```powershell
   .\install-winget.ps1 -DryRun
   ```

5. Cài thật:

   ```powershell
   .\install.bat
   ```

6. Mở cửa sổ PowerShell **mới** rồi kiểm tra:

   ```powershell
   winget --version
   ```

Nếu máy đã có WinGet, script sẽ so phiên bản và hỏi bạn muốn cài lại hay bỏ qua.

## Thay đổi trên hệ thống và hoàn tác

Một lần cài thật có thể:

- `Add-AppxPackage` gói `Microsoft.DesktopAppInstaller` cho user hiện tại.
- `Add-AppxProvisionedPackage -Online` để user tạo sau này cũng có WinGet.
- Cài các framework còn thiếu từ dependencies chính thức của Microsoft.
- Chỉ khi Windows chặn sideload: bật `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowAllTrustedApps = 1`. Script **không** bật Developer Mode; giá trị cũ được ghi vào `backup\<tag>\undo.json`.

Trước mọi thay đổi, script tạo `backup\<tag>\` gồm export registry, PATH máy/user, `state-before.json`, danh sách AppX và `undo.json`. Mỗi lần chạy cũng được ghi vào `thay_doi_sys.md`.

Gỡ hoặc khôi phục:

```bat
uninstall_restore.bat                                        :: menu gỡ / khôi phục
uninstall_restore.bat -BackupTag <tag> -DryRun                :: xem trước
uninstall_restore.bat -BackupTag <tag>                        :: khôi phục thật
uninstall_restore.bat -BackupTag <tag> -KeepPackage           :: chỉ khôi phục registry, giữ WinGet
```

Trên một số image, gói App Installer là gói hệ thống `NonRemovable` và Windows sẽ từ chối gỡ; khi đó tool-pack vẫn khôi phục registry và báo rõ. Xem chi tiết ở [hướng dẫn](huongdan_tool-pack.md).

## Kiểm chứng nguồn và file

- Release chính thức: <https://github.com/microsoft/winget-cli/releases>
- Mỗi release có file hash SHA256 do Microsoft công bố; script so khớp trước khi cài.
- Script kiểm tra thêm chữ ký số: `Get-AuthenticodeSignature` phải `Valid` và subject chứa `CN=Microsoft Corporation`.
- Có thể tự kiểm tra lại từng bước bằng các lệnh trong [mục 7 của hướng dẫn](huongdan_tool-pack.md#7-tự-kiểm-chứng-không-cần-tin-tài-liệu-này).

`-SkipHashCheck` chỉ dành cho chẩn đoán và không được khuyến nghị.

## Cấu trúc

| File | Vai trò |
|---|---|
| `install.bat` / `install-winget.ps1` | Cài đặt, có kiểm tra bản đã cài và `-Reinstall` |
| `uninstall_restore.bat` / `uninstall_restore.ps1` | Gỡ WinGet / khôi phục registry, có menu |
| `check-status.ps1` | Khảo sát read-only |
| `lib.ps1` | Thư viện chung: log, backup, tải file, hash, so phiên bản, font console |
| `huongdan_tool-pack.md` | Hướng dẫn đầy đủ bằng tiếng Việt |

Chỉ cần 6 file `.ps1`/`.bat` ở trên là đủ để chạy; `lib.ps1` phải nằm cùng thư mục với các script còn lại.

## Ghi chú

- `cache\`, `backup\`, `logs\` và `thay_doi_sys.md` là dữ liệu của từng máy, đã được `.gitignore` loại trừ và không bao giờ được commit.
- Khi chép tool-pack sang máy khác, chỉ chép 6 file script và hướng dẫn; không chép `backup\` hay `thay_doi_sys.md` của máy cũ.

## Giấy phép

[MIT](LICENSE) © 2026 bbkien2312

---

## English

Unofficial PowerShell toolpack to sideload **WinGet (App Installer)** on Windows 10/11 IoT Enterprise LTSC machines that ship without Microsoft Store. It downloads packages only from official `microsoft/winget-cli` releases, verifies SHA256 and the Microsoft Authenticode signature, installs the required frameworks, backs up registry and package state, logs every change, and provides an uninstall/restore path. Not affiliated with Microsoft. MIT licensed.
