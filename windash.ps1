# WinDash — локальний сервер: панель, AI-консоль і агент, пресети, драйвери, моніторинг, знімки й автовідкат
param([int]$Port = 8787, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$self = $PSCommandPath
$cfgPath = Join-Path $root 'config.json'
$token = [guid]::NewGuid().ToString('N')
$utf8 = New-Object System.Text.UTF8Encoding $false
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$url = "http://127.0.0.1:$Port/"

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() } catch {
    # Сервер уже працює (напр. з автозапуску) — просто відкриваємо панель
    if (-not $NoBrowser) { Start-Process $url }
    return
}

# ---------- Конфіг ----------
# cpu/ram — % завантаження, disk — % вільного, evt — помилок журналу/год, cooldown — хв між повторами інциденту,
# confirmSec — вікно «Зберегти зміни?» (0 = вимк.), drvAuto — 0 вимк. / 1 щодня шукати драйвери / 2 шукати й ставити
$NUM = 'cpu', 'ram', 'disk', 'evt', 'cooldown', 'autoRollback', 'confirmSec', 'autoRestore', 'notify', 'drvAuto'
function Get-Cfg {
    $d = [ordered]@{ apiKey = ''; model = 'claude-sonnet-5-5'; cpu = 90; ram = 90; disk = 10; evt = 5; cooldown = 15
        autoRollback = 1; confirmSec = 60; autoRestore = 1; notify = 1; drvAuto = 1 }
    if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $d[$_.Name] = $_.Value } }
    [pscustomobject]$d
}

function Send($ctx, $code, $body, $type = 'application/json; charset=utf-8') {
    $bytes = if ($body -is [byte[]]) { $body } else { $utf8.GetBytes([string]$body) }
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }

# ---------- Логи (JSONL/CSV, без БД) ----------
$logDir = Join-Path $root 'logs'
$snapDir = Join-Path $logDir 'snapshots'
$taskDir = Join-Path $logDir 'tasks'
New-Item -ItemType Directory -Force $logDir, $snapDir, $taskDir | Out-Null
Get-ChildItem $logDir -Filter 'metrics-*.csv' | Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Force
Get-ChildItem $snapDir, $taskDir -File | Where-Object LastWriteTime -lt (Get-Date).AddDays(-60) | Remove-Item -Force
foreach ($f in 'incidents.jsonl', 'runs.jsonl') {
    $p = Join-Path $logDir $f
    if ((Test-Path $p) -and (Get-Item $p).Length -gt 2MB) { [IO.File]::WriteAllLines($p, [string[]](Get-Content $p -Tail 2000 -Encoding UTF8), $utf8) }
}
function Write-Log($file, $obj) { [IO.File]::AppendAllText((Join-Path $logDir $file), ($obj | ConvertTo-Json -Depth 8 -Compress) + "`n", $utf8) }
function Read-Jsonl($file, [int]$n) {
    $p = Join-Path $logDir $file
    if (-not (Test-Path $p)) { return , @() }
    # кома — щоб PowerShell не розгорнув масив з одного елемента в обʼєкт
    , @(Get-Content $p -Tail $n -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { "$_" | ConvertFrom-Json })
}
$statePath = Join-Path $logDir 'state.json'
$script:state = if (Test-Path $statePath) { Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ lastDrvCheck = '2000-01-01T00:00:00' } }
function Save-State { [IO.File]::WriteAllText($statePath, (Json $script:state), $utf8) }

# ---------- Сповіщення Windows ----------
function Show-Toast($title, $text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $e = { param($s) [Security.SecurityElement]::Escape("$s") }
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $x.LoadXml("<toast activationType='protocol' launch='$url'><visual><binding template='ToastGeneric'><text>$(& $e $title)</text><text>$(& $e $text)</text></binding></visual></toast>")
        $n = [Windows.UI.Notifications.ToastNotification]::new($x)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($n)
    } catch {}
}

# ---------- Інциденти ----------
$script:lastFired = @{}; $script:cpuHigh = 0; $script:minute = ''; $script:lastEvt = [datetime]::MinValue
$script:queue = New-Object Collections.Generic.List[object]
$INC_TITLE = @{ svc = 'Системні служби'; cpu = 'Процесор'; ram = 'Памʼять'; disk = 'Диск'; evt = 'Журнал подій'; drv = 'Драйвери'; run = 'Скрипт'; rollback = 'Автовідкат' }
# -Quiet: інцидент повертається у відповіді на запит користувача, а не через чергу/сповіщення
function Fire($id, $level, $msg, $data, [switch]$Force, [switch]$Quiet) {
    $c = Get-Cfg
    if (-not $Force -and $script:lastFired[$id] -and ((Get-Date) - $script:lastFired[$id]).TotalMinutes -lt $c.cooldown) { return }
    $script:lastFired[$id] = Get-Date
    $inc = @{ at = (Get-Date).ToString('o'); id = $id; level = $level; msg = $msg; data = $data }
    Write-Log 'incidents.jsonl' $inc
    if (-not $Quiet) {
        $script:queue.Add($inc)
        if ($c.notify -and $level -ne 'info') { Show-Toast "WinDash · $($INC_TITLE[($id -split '-')[0]])" $msg }
    }
    $inc
}

# ---------- Виконання скриптів ----------
function Get-Wrapped([string]$code, [switch]$Stream) {
    $head = "`$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8`n"
    if ($Stream) { $head + "try { & {`n$code`n} 2>&1 | ForEach-Object { if (`$_ -is [string]) { `$_ } else { (`$_ | Out-String -Width 200).TrimEnd() } } } catch { 'ПОМИЛКА: ' + `$_; exit 1 }" }
    else { $head + "try { & {`n$code`n} 2>&1 | Out-String -Width 220 } catch { 'ПОМИЛКА: ' + `$_; exit 1 }" }
}
function Invoke-Script([string]$code, [int]$timeoutSec = 180) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-Wrapped $code)))
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($timeoutSec * 1000)
    if ($timedOut) { try { $p.Kill() } catch {} }
    @{ output = ($o.Result + $e.Result).TrimEnd(); exitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }); ms = $sw.ElapsedMilliseconds; timedOut = $timedOut }
}

# Фонові задачі: довгі скрипти (драйвери) не блокують сервер; вивід пишеться у файл і читається наживо
$script:tasks = @{}
function Start-Task($name, $kind, [string]$code, $meta) {
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $out = Join-Path $taskDir "$id.out"; $err = Join-Path $taskDir "$id.err"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-Wrapped $code -Stream)))
    $p = Start-Process powershell.exe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc" -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle  # щоб ExitCode був доступний після завершення
    $script:tasks[$id] = @{ id = $id; name = $name; kind = $kind; meta = $meta; p = $p; out = $out; err = $err; started = Get-Date; done = $false; exit = $null; result = $null }
    $id
}
function Read-Shared($path) {
    if (-not (Test-Path $path)) { return '' }
    $fs = New-Object IO.FileStream($path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($fs, $utf8)).ReadToEnd() } finally { $fs.Dispose() }
}
function Get-TaskView($t) {
    $text = ((Read-Shared $t.out) + (Read-Shared $t.err)) -replace '##RESULT##.*', ''
    @{ id = $t.id; name = $t.name; kind = $t.kind; done = $t.done; exit = $t.exit; result = $t.result; output = $text.TrimEnd(); sec = [int]((Get-Date) - $t.started).TotalSeconds }
}
function Update-Tasks {
    foreach ($t in @($script:tasks.Values | Where-Object { -not $_.done })) {
        if (((Get-Date) - $t.started).TotalMinutes -gt 30) { try { $t.p.Kill() } catch {} }
        if (-not $t.p.HasExited) { continue }
        $t.done = $true; $t.exit = $t.p.ExitCode
        $m = [regex]::Match((Read-Shared $t.out), '##RESULT##(.+)')
        if ($m.Success) { try { $t.result = $m.Groups[1].Value.Trim() | ConvertFrom-Json } catch {} }
        Write-Log 'runs.jsonl' @{ at = (Get-Date).ToString('o'); src = $t.kind; name = $t.name; exit = $t.exit; ms = [int]((Get-Date) - $t.started).TotalMilliseconds; admin = $isAdmin; line = 'фонова задача' }
        if ($t.kind -eq 'drivers') { Complete-DriverTask $t }
    }
}

# ---------- Статичний аналіз безпеки скрипта (AST) ----------
$DANGER = @(
    @('^(format-volume|clear-disk|initialize-disk|remove-partition|set-partition|resize-partition|diskpart|format|bcdedit|bcdboot|vssadmin|wbadmin|cipher|reagentc)$', 'high', 'Диски, завантаження або резервні копії — можлива втрата даних'),
    @('^(invoke-expression|iex|add-type)$', 'high', 'Виконання довільного коду'),
    @('^(set-executionpolicy|set-mppreference|add-mppreference|set-netfirewallprofile|disable-netadapter|remove-netadapter|takeown|icacls)$', 'high', 'Безпека, права доступу або мережа'),
    @('^(remove-item|rm|del|erase|rd|rmdir|clear-recyclebin)$', 'medium', 'Видалення файлів'),
    @('^(stop-computer|restart-computer|shutdown|logoff)$', 'medium', 'Вимкнення або перезавантаження'),
    @('^(invoke-webrequest|iwr|curl|wget|invoke-restmethod|irm|start-bitstransfer)$', 'medium', 'Звернення до інтернету'),
    @('^(remove-itemproperty|remove-service|uninstall-package|remove-appxpackage|remove-appxprovisionedpackage|disable-windowsoptionalfeature)$', 'medium', 'Видалення налаштувань або компонентів'),
    @('^(stop-process|kill|taskkill)$', 'medium', 'Завершення процесів'),
    @('^(clear-eventlog|wevtutil)$', 'medium', 'Очищення журналів')
)
$RO_VERBS = 'Get', 'Test', 'Measure', 'Select', 'Format', 'Where', 'Sort', 'Group', 'ForEach', 'ConvertTo', 'ConvertFrom', 'Compare', 'Find', 'Resolve', 'Join', 'Split', 'Search', 'Show', 'Read'
$RO_NAMES = 'Out-String', 'Out-Host', 'Out-Null', 'Out-Default', 'Write-Output', 'Write-Host', 'Write-Verbose', 'Write-Warning', 'Write-Information', 'Write-Progress', 'New-Object', 'New-TimeSpan', 'Start-Sleep', 'Import-Module'
# Нативні утиліти: команда «лише читання», якщо її аргументи відповідають шаблону ('' — будь-які)
$RO_NATIVE = @{ ipconfig = '^(\s*/(all|displaydns))*\s*$'; systeminfo = ''; whoami = ''; hostname = ''; netstat = ''; driverquery = ''; tasklist = ''; nslookup = ''; ping = ''
    tracert = ''; pathping = ''; getmac = ''; quser = ''; arp = '^\s*-a'; route = '^\s*print'; powercfg = '^\s*/(l|list|q|query|a|availablesleepstates|getactivescheme)\b'
    pnputil = '^\s*/enum-'; sc = '^\s*(query|qc|queryex|qdescription)\b'; reg = '^\s*query\b'; netsh = '\bshow\b'; dism = '(?i)/(checkhealth|scanhealth|get-)'
    sfc = '(?i)^\s*/verifyonly'; chkdsk = '^(\s*[A-Za-z]:)*\s*$'; 'manage-bde' = '-status'; w32tm = '/query'
}
$RANK = @{ low = 0; medium = 1; high = 2 }
function ConvertTo-RegPath([string]$s) {
    $s = $s -replace '^(?i)Registry::', ''
    foreach ($kv in @(@('HKLM', 'HKEY_LOCAL_MACHINE'), @('HKCU', 'HKEY_CURRENT_USER'), @('HKCR', 'HKEY_CLASSES_ROOT'), @('HKU', 'HKEY_USERS'))) {
        $s = $s -replace "^(?i)$($kv[0]):?\\", "$($kv[1])\"
    }
    'Registry::' + $s.TrimEnd('\')
}
function Test-ScriptSafety([string]$script) {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput("$script", [ref]$tok, [ref]$err)
    $findings = New-Object Collections.Generic.List[object]
    $readOnly = $true
    $defs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $raw = $c.GetCommandName(); $line = $c.Extent.StartLineNumber
        if (-not $raw) { $readOnly = $false; $findings.Add(@{ lvl = 'medium'; cmd = $c.Extent.Text.Substring(0, [math]::Min(60, $c.Extent.Text.Length)); why = 'Динамічний виклик команди'; line = $line }); continue }
        if ($raw -in $defs) { continue }
        $name = $raw
        if ($raw -notmatch '\.exe$') { $al = Get-Alias -Name $raw -ErrorAction SilentlyContinue; if ($al) { $name = $al.Definition } }
        foreach ($d in $DANGER) {
            if ($raw.ToLower() -replace '\.exe$', '' -match $d[0] -or $name.ToLower() -match $d[0]) { $findings.Add(@{ lvl = $d[1]; cmd = $raw; why = $d[2]; line = $line }) }
        }
        if ($name -eq 'Remove-Item' -and $c.Extent.Text -match '(?i)-r(ecurse)?\b' -and $c.Extent.Text -match '(?i)(c:\\windows|\$env:(windir|systemroot)|system32|program files|[''"\s]c:\\?[''"]?(\s|$))') {
            $findings.Add(@{ lvl = 'high'; cmd = $raw; why = 'Рекурсивне видалення в системній папці'; line = $line })
        }
        $verb = ($name -split '-')[0]
        $native = $RO_NATIVE[($raw.ToLower() -replace '\.exe$', '')]
        $cmdlet = Get-Command $name -CommandType Cmdlet, Function -ErrorAction SilentlyContinue
        if ($cmdlet -and ($name -in $RO_NAMES -or ($verb -in $RO_VERBS -and $name -ne 'Get-Credential'))) { continue }
        if (-not $cmdlet -and $null -ne $native) {
            $argText = ($c.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' '
            if ($native -eq '' -or $argText -match $native) { continue }
        }
        $readOnly = $false
    }
    foreach ($m in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ("$($m.Member)" -match '(?i)^(delete|kill|remove|uninstall|install|format|setvalue|deletevalue|deletesubkey\w*|create|terminate|stopservice|startservice|change|setpowerstate|acceptEula|download|commit)$') {
            $readOnly = $false; $findings.Add(@{ lvl = 'medium'; cmd = ".$($m.Member)()"; why = 'Метод, що змінює систему'; line = $m.Extent.StartLineNumber })
        }
    }
    if ($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FileRedirectionAst] }, $true).Count) { $readOnly = $false }
    if ($script -match '(?i)DownloadString|DownloadFile|FromBase64String|-enc(odedcommand)?\s') { $findings.Add(@{ lvl = 'high'; cmd = 'завантаження/декодування'; why = 'Завантаження або приховування коду'; line = 0 }) }
    $level = 'low'; foreach ($f in $findings) { if ($RANK[$f.lvl] -gt $RANK[$level]) { $level = $f.lvl } }
    if ($err.Count -and $level -eq 'low') { $level = 'medium' }

    # Що скрипт може змінити: імена служб і шляхи реєстру серед рядків скрипта
    $strs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | ForEach-Object { "$($_.Value)" } | Where-Object { $_ -and $_ -notmatch '\$' } | Select-Object -Unique)
    $svcSet = @{}; foreach ($n in (Get-Service).Name) { $svcSet[$n] = 1 }
    $services = @($strs | Where-Object { $svcSet.ContainsKey($_) } | Select-Object -First 40)
    $registry = @($strs | Where-Object { $_ -match '^(?i)(Registry::)?(HKLM|HKCU|HKCR|HKU|HKEY_[A-Z_]+)(:|\\)' } | ForEach-Object { ConvertTo-RegPath $_ } | Select-Object -Unique -First 20)
    @{ level = $level; readOnly = $readOnly; findings = $findings.ToArray(); errors = @($err | ForEach-Object { "рядок $($_.Extent.StartLineNumber): $($_.Message)" }); touches = @{ services = $services; registry = $registry } }
}

# ---------- Знімки стану та відкат ----------
function New-Snapshot($name, $touch, $drivers) {
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $svc = @(foreach ($n in @($touch.services)) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        $k = if ($s) { Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.Name)" -ErrorAction SilentlyContinue }
        if (-not $k -or $null -eq $k.Start) { continue }
        @{ n = $s.Name; status = "$($s.Status)"; start = [int]$k.Start; delayed = [int]$k.DelayedAutostart }
    })
    $reg = @(foreach ($p in @($touch.registry)) {
        if (Test-Path -LiteralPath $p) {
            $k = Get-Item -LiteralPath $p
            @{ p = $p; exists = $true; values = @(foreach ($v in $k.GetValueNames()) { @{ n = $v; kind = "$($k.GetValueKind($v))"; v = $k.GetValue($v, $null, 'DoNotExpandEnvironmentNames') } }) }
        } else { @{ p = $p; exists = $false } }
    })
    if (-not ($svc.Count + $reg.Count + @($drivers).Count)) { return $null }
    $snap = @{ id = $id; at = (Get-Date).ToString('o'); name = $name; services = $svc; registry = $reg; drivers = @($drivers) }
    [IO.File]::WriteAllText((Join-Path $snapDir "$id.json"), (Json $snap), $utf8)
    $id
}
function Set-SnapFlag($id, $flag) {
    $f = Join-Path $snapDir "$id.json"
    if (-not (Test-Path $f)) { return }
    $s = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $s | Add-Member $flag (Get-Date).ToString('o') -Force
    [IO.File]::WriteAllText($f, (Json $s), $utf8)
}
function Invoke-Rollback($id) {
    $f = Join-Path $snapDir "$id.json"
    if (-not (Test-Path $f)) { throw "Знімок $id не знайдено" }
    $s = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $log = New-Object Collections.Generic.List[string]
    $START = @{ 2 = 'auto'; 3 = 'demand'; 4 = 'disabled' }
    foreach ($v in @($s.services)) {
        try {
            $mode = $START[[int]$v.start]
            if ($mode) {
                if ($mode -eq 'auto' -and [int]$v.delayed -eq 1) { $mode = 'delayed-auto' }
                $null = & sc.exe config $v.n start= $mode
                if ($LASTEXITCODE) { throw "sc.exe повернув код $LASTEXITCODE" }
            }
            if ($v.status -eq 'Running') { Start-Service -Name $v.n } elseif ($v.status -eq 'Stopped') { Stop-Service -Name $v.n -Force -ErrorAction SilentlyContinue }
            $log.Add("✓ служба $($v.n): $mode, $($v.status)")
        } catch { $log.Add("✗ служба $($v.n): $($_.Exception.Message)") }
    }
    foreach ($r in @($s.registry)) {
        try {
            if (-not $r.exists) {
                if (Test-Path -LiteralPath $r.p) { Remove-Item -LiteralPath $r.p -Recurse -Force; $log.Add("✓ видалено створений ключ $($r.p)") }
                continue
            }
            if (-not (Test-Path -LiteralPath $r.p)) { New-Item -Path $r.p -Force | Out-Null }
            $was = @{}
            foreach ($v in @($r.values)) {
                $was["$($v.n)"] = 1
                $nm = if ("$($v.n)" -eq '') { '(default)' } else { $v.n }
                if ($v.kind -eq 'Binary') { $val = [byte[]]@($v.v) }
                elseif ($v.kind -eq 'MultiString') { $val = [string[]]@($v.v) }
                elseif ($v.kind -eq 'DWord') { $val = [int]$v.v }
                elseif ($v.kind -eq 'QWord') { $val = [long]$v.v }
                else { $val = [string]$v.v }
                if ($v.kind -in 'String', 'ExpandString', 'Binary', 'DWord', 'QWord', 'MultiString') { New-ItemProperty -LiteralPath $r.p -Name $nm -Value $val -PropertyType $v.kind -Force | Out-Null }
            }
            foreach ($n in (Get-Item -LiteralPath $r.p).GetValueNames()) {
                if (-not $was.ContainsKey($n)) { Remove-ItemProperty -LiteralPath $r.p -Name $(if ($n -eq '') { '(default)' } else { $n }) -Force }
            }
            $log.Add("✓ реєстр $($r.p -replace '^Registry::', '')")
        } catch { $log.Add("✗ реєстр $($r.p): $($_.Exception.Message)") }
    }
    foreach ($inf in @($s.drivers)) {
        if (-not $inf) { continue }
        $o = (& pnputil.exe /delete-driver $inf /uninstall /force 2>&1 | Out-String).Trim()
        $log.Add($(if ($LASTEXITCODE) { "✗ драйвер ${inf}: $o" } else { "✓ драйвер $inf видалено" }))
    }
    Set-SnapFlag $id 'rolledBack'
    , $log.ToArray()
}

# Вікно «Зберегти зміни?»: якщо не підтвердити вчасно — сервер відкочує сам (переживає й перезавантаження)
$pendPath = Join-Path $logDir 'pending.json'
$script:pending = @{}
if (Test-Path $pendPath) {
    (Get-Content $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $script:pending[$_.Name] = @{ name = $_.Value.name; deadline = [datetime]$_.Value.deadline } }
}
function Save-Pending {
    $o = @{}; foreach ($k in $script:pending.Keys) { $o[$k] = @{ name = $script:pending[$k].name; deadline = $script:pending[$k].deadline.ToString('o') } }
    [IO.File]::WriteAllText($pendPath, (Json $o), $utf8)
}
function Get-PendingView { , @($script:pending.Keys | ForEach-Object { @{ id = $_; name = $script:pending[$_].name; left = [int]($script:pending[$_].deadline - (Get-Date)).TotalSeconds } }) }

# ---------- Системна інформація ----------
function Get-SysStatic {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $board = Get-CimInstance Win32_BaseBoard
    @{
        host = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; isAdmin = $isAdmin
        os = $os.Caption; build = "$($os.Version) (build $($os.BuildNumber))"; arch = $os.OSArchitecture
        installed = $os.InstallDate.ToString('yyyy-MM-dd'); boot = $os.LastBootUpTime.ToString('o')
        maker = $cs.Manufacturer; model = $cs.Model; board = "$($board.Manufacturer) $($board.Product)"
        bios = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('yyyy-MM-dd')))"
        cpu = $cpu.Name.Trim(); cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors; mhz = $cpu.MaxClockSpeed
        ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { @{ n = $_.Name; vram = [math]::Round([uint64]$_.AdapterRAM / 1GB, 1); drv = $_.DriverVersion } })
        net = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { @{ n = $_.Description; ip = ($_.IPAddress -join ', '); mac = $_.MACAddress; gw = ($_.DefaultIPGateway -join ', ') } })
        ps = $PSVersionTable.PSVersion.ToString()
    }
}
function Get-SysLive {
    $os = Get-CimInstance Win32_OperatingSystem
    $load = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $svc = Get-Service
    @{
        cpu = [int]$load
        ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        ramFree = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        uptime = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { @{ n = $_.DeviceID; label = $_.VolumeName; size = [math]::Round($_.Size / 1GB, 1); free = [math]::Round($_.FreeSpace / 1GB, 1) } })
        procs = @(Get-Process | Sort-Object WS -Descending | Select-Object -First 8 | ForEach-Object { @{ n = $_.ProcessName; id = $_.Id; mem = [math]::Round($_.WS / 1MB) } })
        battery = $(if ($bat) { @{ pct = $bat.EstimatedChargeRemaining; status = $bat.BatteryStatus } } else { $null })
        svcRunning = @($svc | Where-Object Status -eq 'Running').Count; svcTotal = $svc.Count
        procCount = @(Get-Process).Count
    }
}
function Get-SvcStatus([string[]]$names) {
    , @($names | ForEach-Object {
        $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($s) { @{ n = $_; d = $s.DisplayName; status = "$($s.Status)"; start = "$($s.StartType)" } } else { @{ n = $_; d = ''; status = 'Missing'; start = '' } }
    })
}

# ---------- Тригери (фоновий монітор раз на хвилину) ----------
function Get-TopCpu {
    @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total', 'Idle' } |
        Sort-Object PercentProcessorTime -Descending | Select-Object -First 5 | ForEach-Object { @{ n = $_.Name; cpu = [math]::Round($_.PercentProcessorTime / [Environment]::ProcessorCount) } })
}
function Test-Triggers($lv) {
    $c = Get-Cfg
    $ramPct = [math]::Round(($lv.ramTotal - $lv.ramFree) / $lv.ramTotal * 100)
    $m = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    if ($m -ne $script:minute) {
        $script:minute = $m
        [IO.File]::AppendAllText((Join-Path $logDir "metrics-$((Get-Date).ToString('yyyyMMdd')).csv"), "$m,$($lv.cpu),$ramPct`n", $utf8)
    }
    if ($lv.cpu -ge $c.cpu) { $script:cpuHigh++ } else { $script:cpuHigh = 0 }
    if ($script:cpuHigh -ge 3) { try { $top = Get-TopCpu } catch { $top = @() }; Fire 'cpu' 'warn' "Процесор завантажений на $($lv.cpu)% (поріг $($c.cpu)%) кілька хвилин поспіль" @{ top = $top } | Out-Null }
    if ($ramPct -ge $c.ram) { Fire 'ram' 'warn' "Памʼять заповнена на $ramPct% (поріг $($c.ram)%)" @{ top = $lv.procs } | Out-Null }
    foreach ($d in $lv.disks) {
        $fp = if ($d.size) { [math]::Round($d.free / $d.size * 100) } else { 100 }
        if ($fp -lt $c.disk) { Fire "disk-$($d.n)" 'crit' "На диску $($d.n) вільно лише $fp% ($($d.free) ГБ)" @{ disk = $d } | Out-Null }
    }
    if (((Get-Date) - $script:lastEvt).TotalMinutes -ge 5) {
        $script:lastEvt = Get-Date
        # кожна перевірка окремо: збій журналу чи WMI не має ламати монітор
        try { Test-EventLog $c | Out-Null } catch { Write-Host "evt: $($_.Exception.Message)" -ForegroundColor DarkYellow }
        try { Test-Devices | Out-Null } catch { Write-Host "drv: $($_.Exception.Message)" -ForegroundColor DarkYellow }
        try { Test-CoreServices | Out-Null } catch { Write-Host "svc: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
}
# Служби, без яких ламаються Windows Update, журнали й встановлення драйверів (часто їх вимикають «оптимізатори»)
$CORE_SVC = @{ EventLog = 'Журнал подій'; wuauserv = 'Windows Update'; BITS = 'фонова передача (BITS)'; CryptSvc = 'криптографія'; TrustedInstaller = 'встановлювач модулів'; RpcSs = 'RPC' }
function Test-CoreServices {
    $off = @(foreach ($n in $CORE_SVC.Keys) { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s -and "$($s.StartType)" -eq 'Disabled') { @{ n = $n; d = $CORE_SVC[$n] } } })
    if ($off.Count) { Fire 'svc' 'crit' "Вимкнено системні служби: $(($off | ForEach-Object { $_.d }) -join ', ') — ламаються оновлення й драйвери. Пресет «Відновити системні служби»." @{ services = $off } }
}
function Test-EventLog($c) {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-1) } -MaxEvents 100 -ErrorAction SilentlyContinue)
    if ($ev.Count -ge $c.evt) {
        $groups = @($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
            @{ src = $_.Name; count = $_.Count; id = $_.Group[0].Id; text = ("$($_.Group[0].Message)" -split "`n")[0] } })
        Fire 'evt' 'crit' "$($ev.Count) помилок у журналі System за останню годину" @{ groups = $groups }
    }
}
function Test-Devices {
    # 22 = пристрій вимкнено вручну — це не проблема
    $pd = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0 AND ConfigManagerErrorCode<>22')
    if ($pd.Count) {
        $grp = @($pd | Group-Object Name | ForEach-Object { @{ n = $_.Name; count = $_.Count; code = $_.Group[0].ConfigManagerErrorCode } })
        Fire 'drv' 'warn' "$($pd.Count) пристр. з проблемою драйвера" @{ devices = $grp }
    }
}

# ---------- Драйвери: автоматичний пошук і встановлення ----------
function Get-Drivers {
    @{
        problems = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' | ForEach-Object { @{ n = $_.Name; id = $_.PNPDeviceID; code = $_.ConfigManagerErrorCode; cls = $_.PNPClass; hw = "$(@($_.HardwareID)[0])" } })
        drivers = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -and $_.DriverVersion } | ForEach-Object {
            @{ n = $_.DeviceName; v = $_.DriverVersion; date = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }); mf = $_.Manufacturer; cls = $_.DeviceClass; inf = $_.InfName } })
        task = $(if ($script:drvTask) { Get-TaskView $script:tasks[$script:drvTask] } else { $null })
        lastCheck = $script:state.lastDrvCheck
    }
}
# Джерела по черзі: 1) Windows Update — швидко, але неповно; 2) Microsoft Update Catalog за Hardware ID кожного
# проблемного пристрою — значно ширша база; 3) що не знайшлось — UI підкаже сайт виробника за Vendor ID
$DRV_SCRIPT = @'
$MODE = '__MODE__'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$res = @{ mode = $MODE; found = @(); installed = @(); skipped = @(); catalog = @(); reboot = $false; before = @(); after = @(); problemsBefore = 0; problems = @() }
function Get-Oem { @(& pnputil.exe /enum-drivers | Select-String '(oem\d+\.inf)' | ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() } | Select-Object -Unique) }
function Get-Problems { @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0 AND ConfigManagerErrorCode<>22') }
$CAT = 'https://www.catalog.update.microsoft.com'
function Find-Catalog([string]$hw) {
    $q = $hw -replace '(&SUBSYS.*|&REV.*|&CC.*)$', ''
    $h = (Invoke-WebRequest "$CAT/Search.aspx?q=$([uri]::EscapeDataString($q))" -UseBasicParsing -TimeoutSec 40).Content
    $rows = foreach ($m in [regex]::Matches($h, "id=['""]([0-9a-f-]{36})_link['""][^>]*>\s*([^<]+?)\s*</a>")) {
        $g = $m.Groups[1].Value
        $cell = { param($c) [regex]::Match($h, "id=['""]${g}_${c}_R\d+['""]>\s*([^<]*?)\s*<").Groups[1].Value }
        $dt = [datetime]::MinValue
        [void][datetime]::TryParse((& $cell 'C4'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)
        [pscustomobject]@{ g = $g; t = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value) -replace "$([char]0xC2)", '' -replace '\s+', ' '; prod = (& $cell 'C2'); date = $dt }
    }
    # лише пакети для клієнтських Windows 10/11, найсвіжіший
    $rows | Where-Object { $_.prod -match 'Windows 1[01]|Windows 10 and later' } | Sort-Object date -Descending | Select-Object -First 1
}
function Install-Catalog($row) {
    $body = 'updateIDs=' + [uri]::EscapeDataString("[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$($row.g)`",`"updateID`":`"$($row.g)`"}]")
    $dlg = (Invoke-WebRequest "$CAT/DownloadDialog.aspx" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 40).Content
    $urls = @([regex]::Matches($dlg, "files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if (-not $urls.Count) { throw 'каталог не дав посилання на завантаження' }
    $dir = Join-Path $env:TEMP "windash-drv\$($row.g)"
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($u in $urls) {
        $f = Join-Path $dir ([IO.Path]::GetFileName(([uri]$u).AbsolutePath))
        Invoke-WebRequest $u -OutFile $f -UseBasicParsing -TimeoutSec 600
        if ($f -match '\.cab$') { & expand.exe -F:* $f $dir | Out-Null }
    }
    $o = & pnputil.exe /add-driver "$dir\*.inf" /subdirs /install 2>&1 | Out-String
    # 0 — встановлено, 3010 — потрібне перезавантаження
    @{ code = $LASTEXITCODE; out = $o.Trim() }
}

$res.before = Get-Oem
$res.problemsBefore = @(Get-Problems).Count
"🔎 Пристроїв із проблемами: $($res.problemsBefore). Крок 1: Windows Update (1–3 хв)…"
$session = New-Object -ComObject Microsoft.Update.Session
$sr = $null
# спершу саме Windows Update (а не корпоративний WSUS), якщо так не можна — джерело за замовчуванням
foreach ($sel in 2, 0) {
    try { $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = $sel; $sr = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0"); break }
    catch { $wuErr = $_.Exception.Message }
}
if (-not $sr) {
    "⚠️ Windows Update недоступний ($wuErr) — переходжу до каталогу"
    $off = @('EventLog', 'wuauserv', 'BITS', 'CryptSvc' | Where-Object { "$((Get-Service $_ -ErrorAction SilentlyContinue).StartType)" -eq 'Disabled' })
    if ($off) { "   💡 Причина: вимкнені служби $($off -join ', '). Пресет «Відновити системні служби» це виправить." }
    $sr = @{ Updates = @() }
}
foreach ($u in $sr.Updates) { $res.found += @{ t = $u.Title; cls = "$($u.DriverClass)"; date = $(try { $u.DriverVerDate.ToString('yyyy-MM-dd') } catch { '' }); hw = "$($u.DriverHardwareID)"; mb = [math]::Round($u.MaxDownloadSize / 1MB, 1) } }
"📦 Windows Update: $(@($sr.Updates).Count)"
$res.found | ForEach-Object { "   • $($_.t)" }
if ($MODE -eq 'install' -and @($sr.Updates).Count) {
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $sr.Updates) { if ($u.EulaAccepted) { [void]$coll.Add($u) } else { $res.skipped += $u.Title; "⏭ Пропущено (потрібна згода з ліцензією): $($u.Title)" } }
    if ($coll.Count) {
        Checkpoint-Computer -Description 'WinDash: авто-драйвери' -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        "🛟 Точка відновлення (Windows дозволяє одну на 24 год)"
        "⬇️ Завантажую $($coll.Count)…"
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        "⚙️ Встановлюю…"
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $ir = $inst.Install()
        $codes = @{ 2 = 'ok'; 3 = 'partial'; 4 = 'fail'; 5 = 'aborted' }
        for ($i = 0; $i -lt $coll.Count; $i++) {
            $rc = $codes[[int]$ir.GetUpdateResult($i).ResultCode]
            $res.installed += @{ t = $coll.Item($i).Title; rc = $rc }
            "$(@{ok='✅';partial='⚠️';fail='❌';aborted='⛔'}[$rc]) $($coll.Item($i).Title)"
        }
        $res.reboot = [bool]$ir.RebootRequired
    }
}

$left = @(Get-Problems | ForEach-Object { [pscustomobject]@{ n = $_.Name; hw = "$(@($_.HardwareID)[0])" } } | Where-Object hw)
"🗂 Крок 2: Microsoft Update Catalog для $($left.Count) пристр. без драйвера…"
$seen = @{}
foreach ($d in $left) {
    $key = $d.hw -replace '(&SUBSYS.*|&REV.*|&CC.*)$', ''
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    try { $row = Find-Catalog $d.hw } catch { "   ⚠️ $key : каталог недоступний ($($_.Exception.Message))"; continue }
    if (-not $row) { $res.catalog += @{ n = $d.n; hw = $key; rc = 'none' }; "   ∅ $key — у каталозі немає"; continue }
    if ($seen.ContainsKey($row.g)) { $res.catalog += @{ n = $d.n; hw = $key; t = $row.t; rc = 'dup' }; continue }
    $seen[$row.g] = 1
    $item = @{ n = $d.n; hw = $key; t = $row.t; date = $row.date.ToString('yyyy-MM-dd'); g = $row.g; rc = 'found' }
    if ($MODE -eq 'install') {
        try {
            $ir = Install-Catalog $row
            $item.rc = if ($ir.code -in 0, 3010) { 'ok' } else { 'fail' }
            if ($ir.code -eq 3010) { $res.reboot = $true }
            if ($item.rc -eq 'fail') { $item.err = ($ir.out -split "`n" | Select-Object -Last 2) -join ' ' }
        } catch { $item.rc = 'fail'; $item.err = $_.Exception.Message }
        "   $(@{ok='✅';fail='❌'}[$item.rc]) $key → $($row.t)"
    } else { "   📦 $key → $($row.t) ($($item.date))" }
    $res.catalog += $item
}

"🔄 Пересканування обладнання…"
& pnputil.exe /scan-devices | Out-Null
Start-Sleep 3
$res.after = Get-Oem
$res.problems = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0 AND ConfigManagerErrorCode<>22' | ForEach-Object { @{ n = $_.Name; code = $_.ConfigManagerErrorCode; hw = "$(@($_.HardwareID)[0])"; id = $_.PNPDeviceID } })
"🏁 Готово. Пристроїв із проблемами: $($res.problemsBefore) → $($res.problems.Count)$(if ($res.reboot) { '. Потрібне перезавантаження.' })"
'##RESULT##' + ($res | ConvertTo-Json -Depth 5 -Compress)
'@
$script:drvTask = $null
function Start-DriverTask([string]$mode, [switch]$Auto) {
    if ($script:drvTask -and -not $script:tasks[$script:drvTask].done) { return $script:drvTask }
    $name = if ($mode -eq 'install') { 'Драйвери: пошук і встановлення' } else { 'Драйвери: пошук' }
    if ($Auto) { $name += ' (авто)' }
    $script:drvTask = Start-Task $name 'drivers' ($DRV_SCRIPT.Replace('__MODE__', $mode)) @{ auto = [bool]$Auto }
    $script:state.lastDrvCheck = (Get-Date).ToString('o'); Save-State
    $script:drvTask
}
function Complete-DriverTask($t) {
    $r = $t.result
    if (-not $r) { Fire 'drv' 'warn' "$($t.name): завершено з помилкою (код $($t.exit))" @{ task = $t.id } -Force -Quiet:(-not $t.meta.auto) | Out-Null; return }
    $new = @(@($r.after) | Where-Object { $_ -notin @($r.before) })
    if ($new.Count) { $t.snap = New-Snapshot $t.name @{ services = @(); registry = @() } $new; $r | Add-Member snap $t.snap -Force }
    $ok = @(@($r.installed) + @($r.catalog) | Where-Object { $_.rc -eq 'ok' }).Count
    $cat = @(@($r.catalog) | Where-Object { $_.rc -eq 'found' }).Count
    $msg = if ($r.mode -eq 'install') { "Драйвери: встановлено $ok, проблемних пристроїв $($r.problemsBefore) → $(@($r.problems).Count)$(if ($r.reboot) { ', потрібне перезавантаження' })" }
           else { "Драйвери: Windows Update — $(@($r.found).Count), каталог — $cat; проблемних пристроїв $(@($r.problems).Count)" }
    $lvl = if (@($r.found).Count -or $cat -or @($r.problems).Count) { 'warn' } else { 'info' }
    Fire 'drv' $lvl $msg @{ task = $t.id; found = @($r.found).Count; problems = @($r.problems).Count; snap = $t.snap } -Force -Quiet:(-not $t.meta.auto) | Out-Null
}

# ---------- Claude: консоль і агент ----------
function Invoke-Claude([string]$system, [string]$text, [int]$max = 4000) {
    $cfg = Get-Cfg
    $key = if ($cfg.apiKey) { $cfg.apiKey } else { $env:ANTHROPIC_API_KEY }
    if (-not $key) { throw 'Немає API-ключа. Додайте його в «Налаштуваннях» або в змінну ANTHROPIC_API_KEY.' }
    $body = Json @{ model = $cfg.model; max_tokens = $max; system = $system; messages = @(@{ role = 'user'; content = $text }) }
    try {
        $r = Invoke-WebRequest 'https://api.anthropic.com/v1/messages' -Method Post -UseBasicParsing `
            -Headers @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' } `
            -ContentType 'application/json; charset=utf-8' -Body $utf8.GetBytes($body)
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ((New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), $utf8)).ReadToEnd() | ConvertFrom-Json).error.message } catch {}
        throw "Claude API: $msg"
    }
    $txt = ($utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json).content[0].text
    $txt.Substring($txt.IndexOf('{'), $txt.LastIndexOf('}') - $txt.IndexOf('{') + 1)
}
function Get-MachineLine($sys) { "Machine: $($sys.os) $($sys.build), $($sys.model), CPU $($sys.cpu), RAM $($sys.ramGb) GB, PowerShell $($sys.ps), admin=$isAdmin." }
function Invoke-AI([string]$prompt, $sys) {
    $system = @"
You are a Windows PowerShell expert inside a local admin tool. The user describes a task (often in Ukrainian).
$(Get-MachineLine $sys)
Write a PowerShell 5.1-compatible script that does exactly what is asked. Prefer safe, idempotent, reversible commands. Print readable results.
Reply ONLY with JSON: {"script":"...","explanation":"short explanation in Ukrainian","risk":"low|medium|high","needsAdmin":true|false,"revert":"script that undoes the change or empty string"}
"@
    Invoke-Claude $system $prompt
}
function Invoke-Agent($goal, $steps, $sys) {
    $system = @"
You are a careful Windows troubleshooting agent inside WinDash, a local admin tool. $(Get-MachineLine $sys)
Work in small steps. First diagnose with READ-ONLY commands (Get-*, Test-*, ipconfig, etc.). Only when the cause is clear, propose a minimal, reversible fix as a separate step.
Never repeat a step that was already run. If the user skipped a step, choose another approach or finish. Stop when the goal is reached, when a decision is needed from the user, or after at most 8 steps.
PowerShell 5.1. Keep each script short; print concise readable output (use Select-Object -First, avoid huge dumps).
Reply ONLY with JSON: {"thought":"what you learned and why this next step (Ukrainian, 1-3 sentences)","done":false,"script":"...","risk":"low|medium|high","summary":""}
When finished: {"thought":"...","done":true,"script":"","risk":"low","summary":"diagnosis, what was changed and what remains, in Ukrainian plain text"}
"@
    $txt = "Ціль: $goal`n"
    $i = 0
    foreach ($s in @($steps)) {
        $i++; $o = "$($s.output)"
        if ($o.Length -gt 3000) { $o = $o.Substring(0, 1500) + "`n…`n" + $o.Substring($o.Length - 1500) }
        $txt += "`n--- Крок $i ---`nДумка: $($s.thought)`nСкрипт:`n$($s.script)`nСтатус: $($s.status) (код $($s.exit))`nВивід:`n$o`n"
    }
    $txt += "`nЯкий наступний крок?"
    $j = Invoke-Claude $system $txt 3000 | ConvertFrom-Json
    if ($j.script) { $j | Add-Member analysis (Test-ScriptSafety $j.script) -Force }
    $j
}

# ---------- Автозапуск і фоновий тік ----------
$taskName = 'WinDash'
function Get-Autostart { [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) }
function Set-Autostart([bool]$on) {
    if ($on) {
        $u = "$env:USERDOMAIN\$env:USERNAME"
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -NoBrowser"
        $t = New-ScheduledTaskTrigger -AtLogOn -User $u
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask $taskName -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    } else { Unregister-ScheduledTask $taskName -Confirm:$false }
}
$script:lastMon = [datetime]::MinValue
function Invoke-Tick {
    $now = Get-Date
    foreach ($id in @($script:pending.Keys)) {
        if ($now -gt $script:pending[$id].deadline) {
            $p = $script:pending[$id]; $script:pending.Remove($id); Save-Pending
            try { $log = Invoke-Rollback $id } catch { $log = @("✗ $($_.Exception.Message)") }
            Fire 'rollback' 'warn' "Автовідкат «$($p.name)»: зміни не підтверджено вчасно" @{ snap = $id; log = $log } -Force | Out-Null
        }
    }
    Update-Tasks
    if (($now - $script:lastMon).TotalSeconds -ge 60) {
        $script:lastMon = $now
        try { Test-Triggers (Get-SysLive) } catch { Write-Host "monitor: $($_.Exception.Message)" -ForegroundColor DarkYellow }
        $c = Get-Cfg
        if ($c.drvAuto -and $isAdmin -and ($now - [datetime]$script:state.lastDrvCheck).TotalHours -ge 24) {
            Start-DriverTask $(if ($c.drvAuto -ge 2) { 'install' } else { 'scan' }) -Auto | Out-Null
        }
    }
}

# ---------- HTTP ----------
Write-Host "WinDash працює: $url  (адмін: $isAdmin). Ctrl+C — зупинити." -ForegroundColor Magenta
if (-not $NoBrowser) { Start-Process $url }
$static = $null

try {
    while ($listener.IsListening) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(1000)) { try { Invoke-Tick } catch { Write-Host "tick: $($_.Exception.Message)" -ForegroundColor DarkYellow } }
        $ctx = $listener.EndGetContext($ar)
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath
        try {
            if ($path -eq '/') {
                $html = [IO.File]::ReadAllText((Join-Path $root 'index.html'), $utf8).Replace('__TOKEN__', $token)
                Send $ctx 200 $html 'text/html; charset=utf-8'; continue
            }
            # Захист від CSRF: токен вбудовано лише у сторінку, інші сайти його не прочитають
            if ($req.Headers['X-Token'] -ne $token) { Send $ctx 403 (Json @{ error = 'forbidden' }); continue }
            $in = if ($req.HasEntityBody) { (New-Object IO.StreamReader($req.InputStream, $utf8)).ReadToEnd() | ConvertFrom-Json } else { $null }
            if (-not $static -and $path -in '/api/static', '/api/ai', '/api/agent') { $static = Get-SysStatic }
            switch ($path) {
                '/api/static' { Send $ctx 200 (Json $static) }
                '/api/live' {
                    $lv = Get-SysLive
                    $lv.incidents = @($script:queue.ToArray()); $script:queue.Clear()
                    $lv.pending = Get-PendingView
                    $lv.tasks = @($script:tasks.Values | Where-Object { -not $_.done } | ForEach-Object { @{ id = $_.id; name = $_.name } })
                    Send $ctx 200 (Json $lv)
                }
                '/api/services' { Send $ctx 200 (Json @{ items = (Get-SvcStatus @($in.names)) }) }
                '/api/analyze' { Send $ctx 200 (Json (Test-ScriptSafety $in.script)) }
                '/api/run' {
                    $c = Get-Cfg
                    $name = if ($in.name) { "$($in.name)" } else { 'скрипт' }
                    $an = Test-ScriptSafety $in.script
                    if ($in.readOnly -and -not $an.readOnly) {
                        $why = ($an.findings | ForEach-Object { "• $($_.why): $($_.cmd)" }) -join "`n"
                        Send $ctx 200 (Json @{ output = "🔒 Заблоковано режимом «лише читання»: скрипт може змінити систему.`n$why"; exitCode = -2; ms = 0; analysis = $an; blocked = $true })
                    } else {
                        $pre = @(); $snap = $null
                        if (-not $an.readOnly) {
                            $snap = New-Snapshot $name $an.touches @()
                            if ($an.level -eq 'high' -and $c.autoRestore -and $isAdmin) {
                                try { Checkpoint-Computer -Description "WinDash: $name" -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue; $pre += '🛟 Точку відновлення створено (Windows дозволяє одну на 24 год)' }
                                catch { $pre += "🛟 Точку відновлення не створено: $($_.Exception.Message)" }
                            }
                        }
                        $r = Invoke-Script $in.script $(if ($in.timeout) { [math]::Min(1800, [int]$in.timeout) } else { 180 })
                        if ($pre.Count) { $r.output = ($pre -join "`n") + "`n" + $r.output }
                        $r.analysis = $an; $r.snap = $snap; $r.incidents = @()
                        if ($r.exitCode -ne 0) { $r.incidents += Fire 'run' 'info' "Скрипт «$name» завершився з кодом $($r.exitCode)" @{ tail = $r.output.Substring([math]::Max(0, $r.output.Length - 600)) } -Force -Quiet }
                        if ($snap) {
                            if ($r.exitCode -ne 0 -and $c.autoRollback) {
                                $r.rolledBack = Invoke-Rollback $snap
                                $r.incidents += Fire 'rollback' 'warn' "Автовідкат «$name»: скрипт завершився з помилкою" @{ snap = $snap; log = $r.rolledBack } -Force -Quiet
                            } elseif ($c.confirmSec -gt 0) {
                                $script:pending[$snap] = @{ name = $name; deadline = (Get-Date).AddSeconds($c.confirmSec) }; Save-Pending
                                $r.pending = @{ id = $snap; name = $name; left = [int]$c.confirmSec }
                            }
                        }
                        Write-Log 'runs.jsonl' @{ at = (Get-Date).ToString('o'); src = "$($in.src)"; name = $name; exit = $r.exitCode; ms = $r.ms; admin = $isAdmin; level = $an.level; ro = $an.readOnly; snap = $snap; rolledBack = [bool]$r.rolledBack
                            line = "$((("$($in.script)" -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1))".Substring(0, [math]::Min(100, "$((("$($in.script)" -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1))".Length)) }
                        Send $ctx 200 (Json $r)
                    }
                }
                '/api/confirm' { $script:pending.Remove("$($in.id)"); Save-Pending; Set-SnapFlag $in.id 'confirmed'; Send $ctx 200 (Json @{ ok = $true }) }
                '/api/rollback' {
                    $script:pending.Remove("$($in.id)"); Save-Pending
                    $log = Invoke-Rollback "$($in.id)"
                    Fire 'rollback' 'info' "Відкат вручну: $($in.id)" @{ snap = $in.id; log = $log } -Force -Quiet | Out-Null
                    Send $ctx 200 (Json @{ log = $log })
                }
                '/api/snapshots' {
                    $list = @(Get-ChildItem $snapDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -First 40 | ForEach-Object {
                        $s = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        @{ id = $s.id; at = $s.at; name = $s.name; svc = @($s.services).Count; reg = @($s.registry).Count; drv = @($s.drivers | Where-Object { $_ }).Count; rolledBack = $s.rolledBack; confirmed = $s.confirmed; pending = $script:pending.ContainsKey($s.id) } })
                    Send $ctx 200 (Json @{ items = $list })
                }
                '/api/task' { $t = $script:tasks["$($in.id)"]; if ($t) { Send $ctx 200 (Json (Get-TaskView $t)) } else { Send $ctx 404 (Json @{ error = 'Задачу не знайдено' }) } }
                '/api/drivers' { Send $ctx 200 (Json (Get-Drivers)) }
                '/api/drivers/auto' {
                    if (-not $isAdmin) { throw 'Потрібні права адміністратора — запустіть start.cmd.' }
                    Send $ctx 200 (Json @{ id = (Start-DriverTask $(if ($in.mode -eq 'install') { 'install' } else { 'scan' })) })
                }
                '/api/ai' { Send $ctx 200 (Invoke-AI $in.prompt $static) }
                '/api/agent' { Send $ctx 200 (Json (Invoke-Agent $in.goal $in.steps $static)) }
                '/api/analytics' {
                    $metrics = @(foreach ($d in (Get-Date).AddDays(-1), (Get-Date)) {
                        $p = Join-Path $logDir "metrics-$($d.ToString('yyyyMMdd')).csv"
                        if (Test-Path $p) { [IO.File]::ReadAllLines($p, $utf8) }
                    })
                    Send $ctx 200 (Json @{ incidents = (Read-Jsonl 'incidents.jsonl' 300); runs = (Read-Jsonl 'runs.jsonl' 500); metrics = @($metrics | Select-Object -Last 1440) })
                }
                '/api/clearlogs' { Get-ChildItem $logDir -File | Where-Object Name -notin 'pending.json', 'state.json' | Remove-Item -Force; Send $ctx 200 (Json @{ ok = $true }) }
                '/api/autostart' {
                    if ($in) { if (-not $isAdmin) { throw 'Потрібні права адміністратора — запустіть start.cmd.' }; Set-Autostart ([bool]$in.on) }
                    Send $ctx 200 (Json @{ on = (Get-Autostart) })
                }
                '/api/config' {
                    $cfg = Get-Cfg
                    if ($in) {
                        if ($null -ne $in.apiKey -and $in.apiKey -ne '') { $cfg.apiKey = $in.apiKey }
                        if ($in.model) { $cfg.model = $in.model }
                        foreach ($k in $NUM) { if ($null -ne $in.$k) { $cfg.$k = [int]$in.$k } }
                        [IO.File]::WriteAllText($cfgPath, (Json $cfg), $utf8)
                    }
                    $o = @{ hasKey = [bool]($cfg.apiKey -or $env:ANTHROPIC_API_KEY); model = $cfg.model; isAdmin = $isAdmin }
                    foreach ($k in $NUM) { $o[$k] = $cfg.$k }
                    Send $ctx 200 (Json $o)
                }
                default { Send $ctx 404 (Json @{ error = 'not found' }) }
            }
        } catch {
            try { Send $ctx 500 (Json @{ error = "$($_.Exception.Message)" }) } catch {}
        }
    }
} finally { $listener.Stop() }
