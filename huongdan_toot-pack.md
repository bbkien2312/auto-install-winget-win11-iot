# Hướng dẫn tool-pack cài WinGet

Tài liệu này mô tả **cách chạy** bộ script và **liệt kê đầy đủ những gì script tải về / cài lên máy**, kèm theo **nguồn gốc và mức độ tin cậy** của từng thành phần.

Mọi con số trong đây (SHA256, dung lượng, phiên bản, publisher) là **số liệu thật đọc từ máy này và từ GitHub API**, không phải mô tả phỏng chừng.

---

## 1. Máy áp dụng

| Mục | Giá trị |
|---|---|
| Hệ điều hành | Microsoft Windows 11 IoT Enterprise LTSC Evaluation |
| Version / Build | 10.0.26100 / 26100.9711 |
| EditionID | `IoTEnterpriseSEval` |
| PowerShell | 5.1.26100.9444 (không có `pwsh`) |
| Microsoft Store | **Không có** — bản LTSC/IoT cắt bỏ Store |
| App Installer | **Có sẵn trong image** tại `C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe`, `NonRemovable=True`. Tool-pack **đăng ký + provision** gói có sẵn này; Windows **không cho gỡ** nó (xem §4.6) |

---

## 2. Cách thực hiện

### 2.1 Chạy bằng file .bat (khuyên dùng, double-click được)

| File | Tác dụng |
|---|---|
| `install.bat` | Gọi `install-winget.ps1`. Nếu WinGet đã cài, script hỏi bỏ qua / cài lại / thoát trước khi làm gì |
| `uninstall_restore.bat` | Gọi `uninstall_restore.ps1`. Không tham số = menu: gỡ WinGet / gỡ + khôi phục registry / chỉ khôi phục registry |

```bat
install.bat                                   :: cài thật (all-users + provisioned)
install.bat -DryRun                           :: xem trước, KHÔNG sửa gì
install.bat -Reinstall                        :: cài lại bản mới nhất, không hỏi (gỡ bản cũ nếu Windows cho phép)
install.bat -Scope CurrentUser                :: chỉ user hiện tại, không provision
install.bat -DryRun -SkipHashCheck            :: xem trước, bỏ qua đối chiếu SHA256

uninstall_restore.bat                         :: menu gỡ / khôi phục
uninstall_restore.bat -DryRun                 :: xem trước sẽ gỡ những gì
uninstall_restore.bat -BackupTag 20261024-074650        :: khôi phục từ một bản backup cụ thể
uninstall_restore.bat -BackupTag 20261024-074650 -Force :: không hỏi xác nhận
uninstall_restore.bat -KeepPackage -BackupTag 20261024-074650 :: chỉ khôi phục registry, giữ WinGet
uninstall_restore.bat -CleanCache             :: gỡ xong thì xoá cache\ (không đụng backup\)
```

Tham số sau dấu `.bat` được chuyển **nguyên văn** xuống script PowerShell. File `.bat` chỉ là lớp vỏ: nó **không tự sửa gì trên hệ thống**, không tự elevate (script `.ps1` bên dưới tự làm).

### 2.2 Chạy trực tiếp bằng PowerShell

```powershell
cd E:\Qcoder\winget-toolpack   # hoặc thư mục bạn đã chép tool-pack vào

.\check-status.ps1 -Elevate      # khảo sát read-only, 9 mục, không sửa gì
.\install-winget.ps1 -DryRun     # diễn tập
.\install-winget.ps1             # cài thật (hỏi nếu đã có WinGet)
.\install-winget.ps1 -Reinstall  # cài lại bản mới nhất (gỡ nếu Windows cho phép)
.\uninstall_restore.ps1          # menu gỡ / khôi phục
.\uninstall_restore.ps1 -DryRun  # diễn tập gỡ
```

### 2.3 Trình tự khuyến nghị

1. `check-status.ps1` — xem máy đang có gì, có policy nào chặn không.
2. `install.bat -DryRun` — đọc kỹ những gì sắp đổi.
3. `install.bat` — bấm **Yes** ở hộp thoại UAC.
4. Mở **PowerShell mới** rồi chạy `winget --version`.
5. Nếu có sự cố: `uninstall_restore.bat -BackupTag <tag>`.

> Luôn mở cửa sổ PowerShell **mới** sau khi cài: PATH của phiên cũ không tự cập nhật nên `winget` sẽ báo không tìm thấy.

### 2.4 Script làm gì, theo thứ tự

`install-winget.ps1` chạy các bước sau, mỗi bước đều ghi log:

1. Khảo sát read-only. Nếu WinGet đã cài, so sánh với release mới nhất và hỏi bỏ qua / cài lại / thoát (xem §2.5). Gói đã đăng ký nhưng `winget --version` không chạy thì được coi là hỏng và tự sửa.
2. **Backup**: export registry, snapshot toàn bộ gói appx của mọi user, danh sách gói đã provision, PATH machine + user → `backup\<timestamp>\`.
3. Hỏi GitHub API lấy release ổn định mới nhất của `microsoft/winget-cli`.
4. Tải `.msixbundle` + `License1.xml` về `cache\` (giữ lại để đỡ tải lại nếu release không đổi — **không** cài offline được, xem §8.4).
5. Đối chiếu SHA256 của bundle với hash Microsoft công bố, rồi kiểm chữ ký Authenticode (phải do Microsoft Corporation ký).
6. Đọc `DesktopAppInstaller_Dependencies.json` của **đúng release đó** để biết cần framework nào, thiếu thì tải `Dependencies.zip` và đối chiếu hash.
7. Nếu chọn cài lại: gỡ gói cũ **nếu Windows cho phép** (provisioned + all-users, hoặc chỉ user hiện tại với `-Scope CurrentUser`). Gói inbox `NonRemovable=True` bị Windows bảo vệ nên bước gỡ được bỏ qua và script chỉ đăng ký/cập nhật đè.
8. `Add-AppxPackage` cho user hiện tại, rồi `Add-AppxProvisionedPackage -Online` cho mọi user tạo sau này.
9. Verify `winget --version` chạy được, rồi ghi toàn bộ vào `thay_doi_sys.md`.

### 2.5 Chạy lại khi máy đã có WinGet

Không cần gỡ trước. `install-winget.ps1` phát hiện bản đang cài, gọi GitHub API để biết bản mới nhất, rồi hỏi:

| Trạng thái | Lựa chọn |
|---|---|
| Đã cài đủ (user + provisioned) và `winget` chạy được | `[S]` bỏ qua (mặc định) / `[R]` gỡ rồi cài lại bản mới nhất / `[Q]` thoát |
| `winget` chạy được nhưng chưa provision | `[P]` chỉ provision (mặc định) / `[R]` cài lại rồi provision / `[S]` bỏ qua |
| Gói có nhưng `winget` không chạy | tự động gỡ và cài lại, không hỏi; nếu là gói hệ thống thì đăng ký lại |
| Chưa cài | cài mới bình thường |

- `-Reinstall` bỏ qua câu hỏi và luôn cài lại. Trên gói thường, bước này gỡ bản cũ trước; trên gói hệ thống `NonRemovable=True`, Windows từ chối gỡ nên script bỏ qua bước gỡ và chỉ đăng ký/cập nhật đè.
- `-DryRun` chỉ in ra so sánh phiên bản và kế hoạch, không hỏi và không sửa gì. `-DryRun -Reinstall` in trước toàn bộ quy trình cài lại.
- Thứ tự an toàn trên gói thường: **backup → tải + kiểm SHA256/Authenticode → gỡ bản cũ → cài bản mới**. Nếu bước cài sau khi gỡ thất bại, máy sẽ **tạm thời không có winget**; chạy lại `install.bat` để cài tiếp. Script luôn ghi rõ cảnh báo này trước khi gỡ. Gói hệ thống không bị gỡ nên không có khoảng trống này.
- So sánh phiên bản chỉ dùng `major.minor.patch`: package `1.29.380.0` và tag `v1.29.380` được coi là **bằng nhau**, không bị coi là cũ chỉ vì khác thành phần revision.

---

## 3. Những gì script tải về — nguồn gốc và độ tin cậy

### 3.1 Thang đánh giá dùng trong tài liệu này

| Mức | Ý nghĩa |
|---|---|
| **A** | Chính chủ Microsoft, tải qua HTTPS từ release chính thức, **có SHA256 do Microsoft công bố** và script có đối chiếu |
| **B** | Chính chủ Microsoft, tải qua HTTPS từ release chính thức, **không có hash công bố** — chỉ tin vào kênh truyền + chữ ký số |
| **C** | Bên thứ ba, hoặc nguồn không xác minh được |

**Kết luận ngắn: toàn bộ tool-pack này là mức A hoặc B. Không có thành phần nào mức C.**

### 3.2 Nguồn duy nhất

Mọi file đều lấy từ **một** nơi:

```
https://github.com/microsoft/winget-cli/releases
```

- Repo thuộc organization **`microsoft`** trên GitHub — đây là mỏ neo tin cậy thật sự.
- Release dùng ở lần cài trên máy này: **`v1.29.380`**, xuất bản `2026-09-21T18:45:34Z`, `prerelease = False`.
- Người bấm publish là tài khoản `JohnMcPMS` (PM của nhóm WinGet). Tài khoản cá nhân **không** phải cơ sở tin cậy; cơ sở là repo `microsoft/` và chữ ký Microsoft Corporation bên trong từng gói.
- Script **không** tải từ bất kỳ mirror, blog, forum hay trang bên thứ ba nào.

### 3.3 Bảng file có thể được tải (số liệu thật của release v1.29.380)

| # | File | Dung lượng | SHA256 | Hash Microsoft công bố? | Script kiểm? | Mức |
|---|---|---|---|---|---|---|
| 1 | `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` | 217.276.577 B (207,2 MB) | `65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E` | Có — `...8wekyb3d8bbwe.txt` | **Có** — hash + Authenticode | **A** |
| 2 | `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt` | 64 B | — | (chính là file hash) | — | **A** |
| 3 | `DesktopAppInstaller_Dependencies.zip` (chỉ tải khi thiếu framework) | 97.760.717 B (93,2 MB) | `BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1` | Có — `DesktopAppInstaller_Dependencies.txt` | **Có** — hash zip + Authenticode từng `.appx` | **A** |
| 4 | `DesktopAppInstaller_Dependencies.json` | 322 B | — | Không | Đọc trong bộ nhớ, không lưu | **B** |
| 5 | `e53e159d00e04f729cc2180cffd1c02e_License1.xml` | 2.686 B | `BCB15118EC47DF24E3E6013A7006147C3A15B3A8104ED660FE87C8B4ED01F485` | **Không** | **Không** | **B** |

Cả hai hash ở dòng 1 và 3 đã được đối chiếu và **KHỚP CHÍNH XÁC** với file `.txt` Microsoft đăng cạnh bundle. Ngoài hash, script còn gọi `Get-AuthenticodeSignature` cho bundle và **từng `.appx`** trong zip phụ thuộc; chữ ký phải `Valid` và do `CN=Microsoft Corporation` ký, nếu không script dừng trước khi cài.

Lần chạy thật ngày **2026-10-24 07:40** không tải `Dependencies.zip`: máy đã có đủ 3 framework (xem §4.1), nên `cache\` chỉ còn bundle + file hash + license (~207 MB). Dòng 3 vẫn giữ số liệu thật của release để tham chiếu khi máy thiếu framework.

**File có trong release nhưng script cố ý KHÔNG dùng:** `DesktopAppInstallerPolicies.zip` (41 KB) — là mẫu policy cho doanh nghiệp, không cần cho việc cài.

### 3.4 Về `License1.xml` (mức B — điểm yếu nhất của tool-pack)

File này bắt buộc phải có cho `Add-AppxProvisionedPackage -Online`. Microsoft **không công bố hash** cho nó, nên script không có gì để đối chiếu. Bù lại:

- Nó chỉ là license XML, **không phải code thực thi**.
- Nếu license không hợp lệ, Windows sẽ **từ chối provision** chứ không âm thầm chấp nhận.
- Lấy qua HTTPS trực tiếp từ release `microsoft/winget-cli`.

Rủi ro thực tế thấp, nhưng ghi rõ để bạn biết đây là chỗ duy nhất không kiểm được bằng hash.

---

## 4. Những gì script CÀI LÊN MÁY

### 4.1 Danh sách phụ thuộc theo manifest chính chủ của v1.29.380

`DesktopAppInstaller_Dependencies.json` của release này liệt kê **đúng 3 gói**:

| Gói | Version yêu cầu | Trên máy này (kiểm tra 2026-10-24) | Script có cài? |
|---|---|---|---|
| `Microsoft.VCLibs.140.00` | 14.0.33519.0 | Đã có sẵn 14.0.33519.0 | Không — đã đủ |
| `Microsoft.VCLibs.140.00.UWPDesktop` | 14.0.33728.0 | Đã có sẵn 14.0.33728.0 | Không — đã đủ |
| `Microsoft.WindowsAppRuntime.1.8` | >= 8000.616.304.0 | Đã có 8000.994.2142.0 | Không — đã đủ (bản mới hơn yêu cầu) |

> **Lưu ý quan trọng về tài liệu Microsoft:** bài *Using WinGet to Install Apps on Windows IoT Enterprise* trên Microsoft Learn bảo tải `VCLibs` từ `aka.ms` và `UI.Xaml` từ **NuGet** (đổi tên `.nupkg` thành `.zip` bằng tay). Bài đó viết cho WinGet 1.4.x và **đã lỗi thời**: bản 1.29 cần `Microsoft.WindowsAppRuntime.1.8` (bài không nhắc tới) và **không còn** liệt kê `UI.Xaml`.
>
> Script này **cố ý làm khác bài viết**: lấy tất cả phụ thuộc từ `DesktopAppInstaller_Dependencies.zip` của **cùng một release GitHub**, vì đó là asset chính chủ có version khớp chắc chắn với bundle sắp cài. Tránh được NuGet (nơi package do cộng đồng đăng, khó đảm bảo đúng bản) và tránh hardcode tên gói sẽ cũ dần.
>
> Đây chính là nguyên nhân lần cài đầu tiên lúc 16:30 thất bại với lỗi `0x80073CF3`.

### 4.2 Gói chính đã cài

| Gói | Version | Phạm vi | Publisher |
|---|---|---|---|
| `Microsoft.DesktopAppInstaller` | 1.29.380.0 | per-user (user hiện tại) | `CN=Microsoft Corporation` |
| `Microsoft.DesktopAppInstaller` | 1.29.380.0 | all-users (`-AllUsers`) | `CN=Microsoft Corporation` |
| `Microsoft.DesktopAppInstaller` | 2026.917.151.0 | provisioned (mọi user tạo sau) | `CN=Microsoft Corporation` |

Version provisioned hiển thị khác (`2026.917.151.0`) là **bình thường** — đó là cách Windows báo version của gói đã provision, không phải hai gói khác nhau.

> **Phát hiện ngày 2026-10-24:** gói này **không phải do tool-pack mang tới từ đầu**. `Get-AppxPackage Microsoft.DesktopAppInstaller` trả về `NonRemovable=True`; thư mục package trong `C:\Program Files\WindowsApps` có ngày tạo **2026-09-22 07:32**, trùng thời điểm image Windows. Nói cách khác, image LTSC/IoT 24H2 đã có sẵn App Installer ở dạng gói inbox; tool-pack chỉ **đăng ký cho user + provision**. Windows coi đây là thành phần hệ thống và **từ chối mọi lệnh gỡ** — xem §4.6.

### 4.3 Gói có trên máy nhưng script KHÔNG cài

`Microsoft.UI.Xaml.2.8` (thấy 2 bản: 8.2511.26001.0 và 8.2501.31001.0) **đã có sẵn từ trước**, do ứng dụng khác mang vào. Manifest v1.29.380 không yêu cầu nó nên script không đụng tới.

### 4.4 Registry

Lần cài thành công lúc 16:42 **không sửa registry nào**. `AllowAllTrustedApps` hiện là *(chưa đặt)* — gói do Microsoft ký cài được mà không cần bật sideload tường minh.

Script **chỉ** bật `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowAllTrustedApps` nếu Windows trả lỗi `0x80073CFF` / `0x800B0100` (chặn sideload thật sự). Khi đó nó sẽ:
- ghi log rõ ràng,
- lưu vào `backup\<tag>\undo.json` để hoàn tác được,
- ghi vào `thay_doi_sys.md`.

Lỗi `0x80073CF3` (thiếu framework) được nhận diện **riêng** và script **từ chối** bật sideload, vì bật lúc đó là nới lỏng chính sách bảo mật mà chẳng giải quyết được gì.

### 4.5 Chữ ký số — bằng chứng mạnh nhất

Kiểm tra trực tiếp trên máy này:

```
Get-AuthenticodeSignature cache\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
  Status : Valid
  Signer : CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US

Get-AuthenticodeSignature cache\deps\x64\Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx
  Status : Valid
  Signer : CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US
```

**Toàn bộ 11 gói appx** liên quan trên máy (DesktopAppInstaller, VCLibs, UI.Xaml, WindowsAppRuntime) đều có Publisher là `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US`. Không có gói nào của bên thứ ba.

Từ **2026-10-24**, đây không còn là kiểm tra thủ công: `Assert-MicrosoftSigned` trong `lib.ps1` tự chạy trước mỗi lần `Add-AppxPackage`, yêu cầu `Status = Valid` và signer chứa `CN=Microsoft Corporation`. Đây là kiểm tra **độc lập với SHA256** — hash chỉ chứng minh file khớp với hash cùng nguồn, còn chữ ký chứng minh ai đã ký gói.

### 4.6 Giới hạn quan trọng: Windows không cho gỡ gói này

Kiểm tra thật trên máy này (2026-10-24):

```
Get-AppxPackage Microsoft.DesktopAppInstaller | Select Name, NonRemovable, SignatureKind, InstallLocation

Name                          NonRemovable SignatureKind InstallLocation
----                          ------------ ------------- ---------------
Microsoft.DesktopAppInstaller         True         Store C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe
```

Lần chạy `-Reinstall` thật và lần gỡ thật đều nhận cùng một lỗi từ Windows:

```
error 0x80070032: AppX Deployment Remove operation on package
Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe ... failed.
This app is part of Windows and cannot be uninstalled on a per-user basis.
An administrator can attempt to remove the app from the computer using
Turn Windows Features on or off. However, it may not be possible to uninstall the app.
```

Hệ quả chính xác:

| Thao tác | Kết quả trên máy này |
|---|---|
| `install-winget.ps1` (chưa cài) | Đăng ký gói có sẵn + provision → `winget` chạy được |
| `install-winget.ps1 -Reinstall` | Không gỡ được gói cũ; bỏ qua bước gỡ, gọi `Add-AppxPackage` để đăng ký/cập nhật đè → exit 0 |
| `uninstall_restore.ps1` chế độ gỡ (menu 1/2) | **Từ chối**, in rõ `NonRemovable=True` / `0x80070032`, **không sửa gì**, exit 1 |
| `uninstall_restore.ps1 -KeepPackage` (menu 3) | Khôi phục registry, giữ WinGet → exit 0 nếu WinGet vẫn chạy |

Đây là **giới hạn của Windows**, không phải lỗi script. Việc gỡ App Installer khỏi image LTSC (nếu làm được) phải dùng *Turn Windows Features on or off* / DISM và có thể không khả thi; tool-pack **cố ý không** can thiệp vào thành phần hệ thống.

---

## 5. Sau khi cài, WinGet nói chuyện với ai

Đây là phần nhiều người bỏ sót: **bản thân WinGet là của Microsoft, nhưng phần mềm nó cài cho bạn thì tải từ máy chủ của từng hãng.**

### 5.1 Nguồn (source) mà WinGet dùng — đều là `microsoft.com`

```
Name        Argument                                        Explicit
msstore     https://storeedgefd.dsx.mp.microsoft.com/v9.0   false
winget      https://cdn.winget.microsoft.com/cache          false
winget-font https://cdn.winget.microsoft.com/fonts          true
```

Cả 3 đều thuộc tên miền `microsoft.com`. Không có nguồn bên thứ ba nào được thêm sẵn.

### 5.2 Rủi ro còn lại khi DÙNG winget (ngoài phạm vi tool-pack này)

- Repo cộng đồng `microsoft/winget-pkgs` chứa manifest do **người dùng đóng góp**, được Microsoft duyệt tự động + thủ công. Đây là quy trình công khai nhưng vẫn là nội dung cộng đồng.
- URL tải installer thật sự trong mỗi manifest trỏ tới **máy chủ của hãng phát hành** (github.com, CDN riêng của hãng...). Microsoft không host file cài của hãng thứ ba.
- ⇒ Khi bạn `winget install <app>`, độ tin cậy là **độ tin cậy của hãng đó**, không phải của Microsoft.

Tool-pack này chỉ chịu trách nhiệm tới việc cài WinGet. Việc bạn dùng WinGet để cài gì tiếp là quyết định riêng, nên kiểm `winget show <app>` để xem URL nguồn trước khi cài.

---

## 6. Thay đổi trong script liên quan tới độ tin cậy

**2026-10-24 — thêm kiểm tra trước khi cài lại và công cụ `uninstall_restore`.**

- `install-winget.ps1` phát hiện WinGet đã cài, so sánh với release mới nhất rồi hỏi bỏ qua / cài lại / thoát. Gói đã đăng ký nhưng `winget` không chạy được sẽ được tự động sửa. `-Reinstall` bỏ qua câu hỏi và ép cài lại; `-DryRun` chỉ xem trước.
- **Phát hiện gói hệ thống:** image LTSC/IoT 24H2 có sẵn `Microsoft.DesktopAppInstaller` với `NonRemovable=True`; Windows từ chối `Remove-AppxPackage` (`0x80070032`, "part of Windows"). `install-winget.ps1 -Reinstall` nhận diện và **bỏ qua bước gỡ**, chỉ đăng ký/cập nhật đè. `uninstall_restore.ps1` **từ chối gỡ**, không sửa gì, exit 1; menu tự chuyển sang chế độ chỉ khôi phục registry. Đây là giới hạn của Windows, không phải lỗi script.
- Thêm `ConvertTo-WingetVersion` / `Compare-WingetVersion` trong `lib.ps1`: chỉ so sánh `major.minor.patch`, nên package `1.29.380.0` và tag `v1.29.380` được coi là bằng nhau.
- Đổi tên `restore-winget.ps1` → `uninstall_restore.ps1`, `restore.bat` → `uninstall_restore.bat`. Thêm menu 1/2/3/0, `-KeepPackage` (chỉ khôi phục registry, giữ WinGet), `-CleanCache` (xoá `cache\` sau khi xong), thống kê cache/backup lúc khởi động, cảnh báo khi máy có Microsoft Store hoặc không có backup do tool-pack tạo.
- `Get-WingetState` giờ ghi cả `NonRemovable` vào `state-before.json` / `appx-allusers.json`, để biết gói nào Windows bảo vệ.
- `backup\` **không bao giờ** bị xoá. Framework dùng chung (VCLibs/UI.Xaml/WindowsAppRuntime) vẫn được giữ mặc định.
- **Kết quả test thật 2026-10-24:** `-DryRun`, `-DryRun -Reinstall` và `-Reinstall` đều exit 0; gỡ thật bị Windows chặn (exit 1, không thay đổi); `-KeepPackage` exit 0 và winget vẫn chạy; chi tiết ở §8.3.

**2026-10-24 — thêm kiểm chữ ký Authenticode, sửa lỗi restore và `-SkipHashCheck`.**

- `install-winget.ps1` gọi `Assert-MicrosoftSigned` cho bundle và từng `.appx` phụ thuộc; `Status` phải `Valid` và signer phải chứa `CN=Microsoft Corporation`, nếu không thì dừng. `-SkipHashCheck` **không** bỏ qua bước này.
- Sửa lỗi `-SkipHashCheck`: trước đây khi hash lệch, file vẫn bị xoá rồi script tiếp tục (dẫn tới lỗi cài); giờ chỉ xoá khi thực sự dừng.
- `restore-winget.ps1` (nay là `uninstall_restore.ps1`) không còn crash khi `backup\` rỗng, và bỏ qua các thư mục `snapshot-*` khi chọn backup mới nhất.
- Đồng bộ tài liệu: bỏ các câu nói `cache\` cài offline được; `check-status.ps1` không còn coi `UI.Xaml` là gói bắt buộc.

Các thay đổi này **chỉ sửa script**, không sửa hệ thống, nên không có mục mới trong `thay_doi_sys.md`.

**2026-10-23 — thêm kiểm tra SHA256 cho `DesktopAppInstaller_Dependencies.zip`.**

Trước đó script chỉ đối chiếu hash của `.msixbundle`, còn file zip 93 MB chứa các `.appx` phụ thuộc thì **tải về là cài thẳng** mà không kiểm hash — dù Microsoft **có** công bố `DesktopAppInstaller_Dependencies.txt`. Đây là lỗ hổng thật: file zip đó có thể bị hỏng khi tải hoặc bị thay thế trong `cache\`.

Đã sửa: script giờ tải `.txt`, đối chiếu, và **xoá + dừng** nếu lệch. Việc kiểm tra chạy **cả khi dùng lại zip trong cache**, vì file nằm sẵn trên đĩa chưa chắc còn nguyên vẹn.

Đối chiếu thủ công đã xác nhận zip trong cache khớp hash chính chủ:

```
công bố : BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1
thực tế : BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1   → KHỚP
```

Thay đổi này **chỉ sửa script, không sửa hệ thống**, nên không có mục mới trong `thay_doi_sys.md`.

---

## 7. Tự kiểm chứng (không cần tin tài liệu này)

Chạy trong PowerShell, từ thư mục tool-pack (ví dụ `E:\Qcoder\winget-toolpack`):

```powershell
# 1. Gói đã cài và publisher của nó
Get-AppxPackage Microsoft.DesktopAppInstaller |
    Select-Object Name, Version, Publisher, PackageFullName | Format-List

# 2. Hash file đã tải — so với bảng ở mục 3.3
Get-FileHash "cache\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -Algorithm SHA256

# 3. Hash Microsoft công bố — phải trùng khít với dòng trên
Get-Content "cache\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt"

# 4. Chữ ký số của bundle
Get-AuthenticodeSignature "cache\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" |
    Format-List Status, @{n='Signer';e={$_.SignerCertificate.Subject}}

# 5. Mọi gói appx KHÔNG do Microsoft ký (kết quả nên là rỗng)
Get-AppxPackage | Where-Object { $_.Publisher -notmatch 'Microsoft Corporation' } |
    Select-Object Name, Publisher

# 6. Sideload có bị script bật lén không (nên ra rỗng / không tồn tại)
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /s

# 7. WinGet hoạt động chưa
winget --version
winget source list
```

Kiểm tra chéo với nguồn công khai: mở `https://github.com/microsoft/winget-cli/releases/tag/v1.29.380` và so hash đăng ở đó với hash trên máy.

---

## 8. Backup và khôi phục

### 8.1 Backup hiện có trên máy này

| Thư mục | Của lần chạy | Ghi chú |
|---|---|---|
| `backup\20261024-074039\` | lần **cài lại thật** 2026-10-24 07:40 (`-Reinstall`) | có `state-before.json`, `appx-allusers.json`, `appx-provisioned.json`, `reg_*.reg`; `state-after-restore.json` được ghi lúc 07:41 khi chạy thử gỡ |
| `backup\20261024-074650\` | lần **cài lại thật** 2026-10-24 07:46 (`-Reinstall`, bài test cuối) | đầy đủ như trên; dùng cho các bước `-KeepPackage` của bài test cuối |

Mỗi thư mục chứa: `reg_*.reg` (registry export), `*.reg.absent.txt` (đánh dấu khoá không tồn tại lúc backup), `path-machine.txt`, `path-user.txt`, `state-before.json`, `appx-allusers.json`, `appx-provisioned.json`, và `undo.json` nếu có sửa registry.

> Các thư mục `20261023-*` trong bản tài liệu trước thuộc bản tool-pack đặt tại `C:\Users\Ryzen9\AppData\Local\Programs\Qoder`, **không** nằm trong repo này. Bản ở `E:\Qcoder\winget-toolpack` hiện có `20261024-074039` và `20261024-074650`.

### 8.2 Gỡ / khôi phục

```bat
uninstall_restore.bat                                       :: menu gỡ / khôi phục
uninstall_restore.bat -BackupTag 20261024-074650 -DryRun    :: xem trước
uninstall_restore.bat -BackupTag 20261024-074650            :: làm thật
uninstall_restore.bat -BackupTag 20261024-074650 -KeepPackage :: chỉ khôi phục registry
```

Menu (khi chạy không tham số):

| Chọn | Việc sẽ làm |
|---|---|
| **1** | Gỡ WinGet, **không** đụng registry |
| **2** (mặc định) | Gỡ WinGet + khôi phục registry từ backup. Có thể chọn backup theo số thứ tự hoặc tag; Enter = bản mới nhất |
| **3** | Chỉ khôi phục registry, **giữ** WinGet (`-KeepPackage`) |
| **0** | Hủy, không làm gì |

**Riêng máy này:** gói là `NonRemovable=True` nên menu tự phát hiện và **chỉ hiện lựa chọn khôi phục registry (1/0)**, không cho chọn gỡ. Nếu gọi thẳng chế độ gỡ (không `-KeepPackage`), script in lỗi `0x80070032`, **không sửa gì** và exit 1.

Trước khi gỡ (với gói gỡ được), script in danh sách gói/provisioned sẽ bị xoá, thống kê `cache\` / `backup\` / `logs\`, và cảnh báo nếu máy có Microsoft Store hoặc không có backup do tool-pack tạo. Gỡ gói cần gõ **YES** (trừ khi `-Force`).

Với gói **gỡ được**, `uninstall_restore.ps1` sẽ:
1. Gỡ gói đã provision (`Remove-AppxProvisionedPackage -Online -AllUsers`).
2. Gỡ gói của mọi user (`Remove-AppxPackage -AllUsers`).
3. **Hoàn tác registry theo `undo.json`** — đây là đường chính xác, vì `reg import` chỉ **GỘP** giá trị chứ **không xoá được** một giá trị chưa từng tồn tại lúc backup.
4. Import lại `.reg` làm lưới an toàn phụ.
5. Đối chiếu với `state-before.json`, ghi `state-after-restore.json`. Với `-KeepPackage`, kiểm tra WinGet vẫn chạy thay vì coi gói còn lại là sót.
6. Hỏi có xoá `cache\` không (mặc định **không**), hoặc xoá ngay nếu có `-CleanCache`. `backup\` không bị đụng tới.
7. Ghi vào `thay_doi_sys.md`.

Với gói **hệ thống** (`NonRemovable=True`), chỉ bước 3–7 chạy khi có `-KeepPackage`; chế độ gỡ dừng trước khi làm bất cứ điều gì.

### 8.3 Những gì **cố ý giữ lại**

| Thứ được giữ | Lý do |
|---|---|
| `Microsoft.DesktopAppInstaller` | Trên máy này: **luôn được giữ** vì là thành phần hệ thống `NonRemovable=True` — Windows không cho gỡ. Với gói gỡ được, chỉ giữ khi chọn **3** / `-KeepPackage`. |
| `Microsoft.VCLibs.140.00`, `.UWPDesktop`, `Microsoft.UI.Xaml.2.8`, `Microsoft.WindowsAppRuntime.1.8` | Gói **framework dùng chung** — ứng dụng khác trên máy đang dùng. Gỡ có thể làm hỏng chúng. Thêm `-RemoveDependencies` nếu bạn chắc chắn muốn gỡ. |
| File đã tải trong `cache\` (~207 MB trên máy này; tối đa ~300 MB nếu phải tải cả `Dependencies.zip`) | Giữ để **lần cài sau không phải tải lại** bundle/zip cùng version. **Lưu ý: đây KHÔNG phải chế độ offline** — xem mục 8.4. Chỉ xoá khi có `-CleanCache` hoặc trả lời `y`. |
| Toàn bộ `backup\` | Giữ làm lịch sử. **Script không bao giờ xoá backup.** |

Kết quả chạy thật ngày **2026-10-24** (bài test elevated, đủ 5 bước):

| Bước | Lệnh | Exit | Sau bước đó |
|---|---|---|---|
| Xem trước cài mới | `install-winget.ps1 -DryRun` | 0 | không đổi |
| Xem trước cài lại | `install-winget.ps1 -DryRun -Reinstall` | 0 | không đổi |
| Cài lại thật | `install-winget.ps1 -Reinstall` | **0** | winget v1.29.380 chạy, gói vẫn `NonRemovable=True` |
| Gỡ thật | `uninstall_restore.ps1 -BackupTag <tag> -Force` | **1** (đúng thiết kế) | từ chối trước khi sửa gì; winget vẫn chạy, gói còn nguyên |
| Khôi phục registry, giữ WinGet | `uninstall_restore.ps1 -BackupTag <tag> -KeepPackage -Force` | **0** | registry hoàn tác, winget vẫn chạy, gói còn nguyên |

Tổng kết: `fail-count = 0`. Log chi tiết nằm trong `logs\` (không commit).

### 8.4 `cache\` KHÔNG cho phép cài offline (đính chính)

Tài liệu này trước đó ghi "giữ để có thể cài lại offline". **Điều đó sai.** Kiểm tra lại code:

- Bước 2 luôn gọi GitHub API để lấy release mới nhất. Không gọi được → script **dừng ngay**, không bao giờ đụng tới `cache\`.
- Tên file trong cache được lấy từ **kết quả API** (`$rel.Bundle.name`). Nên kể cả khi có mạng, nếu Microsoft đã ra bản mới hơn thì tên file khác đi và script **tải bản mới**, không dùng lại file cũ.

⇒ `cache\` chỉ giúp **đỡ tải lại** khi release mới nhất vẫn đúng là bản đã tải. Muốn cài thật sự offline thì phải sửa script (xem mục 11.5).

---

## 9. Tóm tắt mức độ tin cậy

| Thành phần | Nguồn | Mức | Kiểm chứng được |
|---|---|---|---|
| WinGet `.msixbundle` | `github.com/microsoft/winget-cli` | **A** | SHA256 công bố + Authenticode Valid (script tự kiểm) |
| `Dependencies.zip` (framework) | cùng release | **A** | SHA256 công bố + Authenticode từng `.appx` (script tự kiểm) |
| `Dependencies.json` (manifest) | cùng release | **B** | HTTPS, chỉ là danh sách tên gói |
| `License1.xml` | cùng release | **B** | HTTPS; **không có hash công bố** |
| 4 gói framework đã cài | cùng release | **A** | Publisher `CN=Microsoft Corporation` |
| `Microsoft.DesktopAppInstaller` (gói inbox của image) | Windows LTSC/IoT 24H2 | **A** | `NonRemovable=True`, `SignatureKind=Store`, tạo cùng thời điểm image; **Windows không cho gỡ** |
| Nguồn `msstore` / `winget` / `winget-font` | `*.microsoft.com` | **A** | Tên miền Microsoft |
| **Ứng dụng bạn cài bằng winget sau này** | **máy chủ của từng hãng** | **tuỳ hãng** | `winget show <app>` để xem URL |

**Không có thành phần nào trong tool-pack này đến từ bên thứ ba.** Nguồn duy nhất là `github.com/microsoft/winget-cli`, và mọi gói thực thi đều mang chữ ký hợp lệ `Microsoft Corporation`.

---

## 10. File liên quan

| File | Vai trò |
|---|---|
| `install.bat` / `uninstall_restore.bat` | lớp vỏ click-chạy được |
| `install-winget.ps1` | trình cài đặt, có kiểm tra bản đã cài và `-Reinstall` |
| `uninstall_restore.ps1` | gỡ WinGet / khôi phục registry, có menu và `-KeepPackage` |
| `check-status.ps1` | khảo sát read-only 9 mục |
| `lib.ps1` | thư viện chung (log, backup, tải file, hash, so sánh phiên bản) |
| `thay_doi_sys.md` | **nhật ký bắt buộc** — mọi thay đổi trên hệ thống, kèm đường dẫn backup và lệnh restore |
| `huongdan_toot-pack.md` | tài liệu này |
| `winget-toolpack.zip` | **bản đóng gói để mang sang máy khác** — xem mục 11 |
| `cache\` | file cài đã tải (~207 MB trên máy này; ~300 MB nếu có `Dependencies.zip`) |
| `backup\` | các bản backup |
| `logs\` | log từng lần chạy |

---

## 11. Mang sang máy khác

### 11.1 File tối thiểu cần chép

Chỉ cần **6 file, đặt trong cùng một thư mục**:

```
lib.ps1              check-status.ps1       install.bat
install-winget.ps1   uninstall_restore.ps1  uninstall_restore.bat
```

`lib.ps1` được dot-source từ `$PSScriptRoot`, nên **bắt buộc phải nằm cùng thư mục** với 3 file `.ps1` kia. Không có đường dẫn tuyệt đối nào hardcoded trong script (đã kiểm tra: không có `D:\`, không có tên máy, không có tên user) — chép sang ổ nào, thư mục nào cũng chạy.

Script **tự tạo** những thứ còn thiếu: `cache\`, `logs\`, `backup\`, và `thay_doi_sys.md` (kèm header).

Nên chép dưới dạng **`.zip`** — một số công cụ chép file có thể làm **mất BOM UTF-8**, khi đó PowerShell 5.1 đọc tiếng Việt trong script thành mojibake.

### 11.2 KHÔNG chép sang máy khác

| Thứ | Lý do |
|---|---|
| `backup\` | Backup là **của riêng máy đó**. Chép backup máy A sang máy B rồi chạy `uninstall_restore.bat` trên máy B sẽ áp trạng thái registry/snapshot **sai máy**. |
| `thay_doi_sys.md` | Là lịch sử của máy này. Chép sang sẽ khiến máy mới ghi tiếp thay đổi của nó vào lịch sử máy cũ → nhật ký sai sự thật. Để script tự tạo file mới. |
| `logs\` | Log cũ của máy này, vô nghĩa trên máy mới. |
| `cache\` | Chép được, nhưng **không** giúp cài offline (mục 8.4). Chỉ đỡ tải lại nếu release vẫn là bản đó. |

### 11.3 Điều kiện trên máy đích

| Điều kiện | Chi tiết |
|---|---|
| **Kiến trúc CPU: x64, x86 hoặc ARM64** | Script **tự nhận diện** kiến trúc trước khi cài và lấy đúng bản `.appx` phụ thuộc. Kiến trúc lạ (ví dụ IA64) → **dừng ngay ở bước preflight**, không cài dở dang. Xem mục 11.4. |
| **Có mạng tới `github.com`** | Bắt buộc — xem mục 8.4. `check-status.ps1` mục 7 sẽ test trước. |
| **PowerShell ≥ 5.1** | Có sẵn trên Windows 10/11. Không cần `pwsh`. |
| **Quyền Administrator** | `.bat`/`.ps1` tự elevate, sẽ hiện UAC. |
| **Execution policy** | Máy này đang để `Restricted`. `.bat` đã truyền `-ExecutionPolicy Bypass` nên chạy được; chạy `.ps1` trực tiếp bằng double-click sẽ bị chặn — **hãy dùng `.bat`**. |

Bản Win cùng edition (`IoTEnterpriseSEval`) là đúng trường hợp script xử lý. Nếu máy đích **có** Microsoft Store thì thường đã sẵn DesktopAppInstaller; script vẫn chạy được và sẽ báo trạng thái trước/sau.

### 11.4 Hỗ trợ x64 / x86 / ARM64

Cả hai nguồn đều có đủ ba kiến trúc — đã kiểm tra bằng cách mở nội dung file thật:

**`Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`** chứa:

| Gói bên trong bundle | Dung lượng |
|---|---|
| `AppInstaller_x64.msix` | 62.556.620 B |
| `AppInstaller_x86.msix` | 58.760.135 B |
| `AppInstaller_arm64.msix` | 61.973.708 B |

Vì là **bundle** đa kiến trúc nên `Add-AppxPackage` tự chọn bản đúng với hệ điều hành — phần này không cần script can thiệp.

**`DesktopAppInstaller_Dependencies.zip`** có ba thư mục `x64\`, `x86\`, `arm64\`, mỗi thư mục đủ 3 gói framework. Script chọn thư mục theo kiến trúc máy:

| Kiến trúc máy | Phát hiện qua | Thư mục / đuôi file | `Get-AppxPackage .Architecture` |
|---|---|---|---|
| x64 | `PROCESSOR_ARCHITECTURE = AMD64` | `x64` / `_x64.appx` | `X64` |
| ARM64 | `PROCESSOR_ARCHITECTURE = ARM64` | `arm64` / `_arm64.appx` | `Arm64` |
| x86 (32-bit) | `PROCESSOR_ARCHITECTURE = x86` | `x86` / `_x86.appx` | `X86` |

Nếu script chạy trong tiến trình 32-bit trên Windows 64-bit, `PROCESSOR_ARCHITECTURE` sẽ báo `x86` sai lệch — code có đọc thêm `PROCESSOR_ARCHITEW6432` để lấy đúng kiến trúc thật.

**Lưu ý về ARM64:** phải cài framework bản `arm64`, **không** dùng bản `x64` thay thế. Trên ARM64, gói x64 chỉ phục vụ ứng dụng chạy giả lập, còn WinGet bản arm64 native cần framework arm64. Code lọc theo đúng `.Architecture` của hệ điều hành nên không nhận nhầm.

Đã kiểm thử: với cả ba kiến trúc, logic chọn file tìm đúng **9/9** gói trong `Dependencies.zip`; với các tổ hợp biến môi trường (kể cả IA64 và biến rỗng) hàm nhận diện trả về đúng giá trị hoặc `null` để script từ chối chạy.

### 11.5 Điểm cố ý không làm

**Không có chế độ offline.** WinGet bản thân nó cũng phải có mạng mới dùng được (kéo danh sách gói từ `cdn.winget.microsoft.com`), nên cài offline cho một công cụ vốn cần online là vô nghĩa.

### 11.6 Chép xong thì chạy gì

```bat
:: 1. mo PowerShell trong thu muc do, chay khao sat (read-only, khong sua gi)
powershell -ExecutionPolicy Bypass -File check-status.ps1 -Elevate
::    doc dong "Kien truc dich" - phai la x64 / ARM64 / x86, khong duoc bao
::    "khong nhan dien duoc"

:: 2. dien tap
install.bat -DryRun

:: 3. cai that
install.bat

:: 4. mo PowerShell MOI roi kiem tra
winget --version
```
