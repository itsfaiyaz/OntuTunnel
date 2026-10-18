# Windows end-to-end check on a throw-away GitHub machine: starts the real
# ontutunnel.exe (app window + tray) and drives it through its dashboard API.
$ErrorActionPreference = 'Stop'
$port = 7790
$base = "http://127.0.0.1:$port"
$env:ONTUTUNNEL_HOME = Join-Path $env:RUNNER_TEMP 'ot'
New-Item -ItemType Directory -Force $env:ONTUTUNNEL_HOME | Out-Null
"{`"web`":{`"port`":$port},`"autoConnect`":false}" | Out-File -Encoding ascii (Join-Path $env:ONTUTUNNEL_HOME 'config.json')
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$results = @()
function Check($name, $ok, $detail = '') {
  $script:results += [pscustomobject]@{ Check = $name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = $detail }
}
function Act($body) {
  Invoke-RestMethod -Method Post -Uri "$base/api/action" -Headers @{ 'X-OntuTunnel' = '1' } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5 -Compress)
}

# GitHub's Windows machines keep port 80 for IIS / HTTP.SYS: free it, as a
# user with that service would (the app says so in its message)
foreach ($svc in 'W3SVC', 'WAS', 'IISADMIN') { Stop-Service $svc -Force -ErrorAction SilentlyContinue }
cmd /c 'net stop http /y' 2>&1 | Out-Null
Write-Host 'Port 80/443 users:'; netstat -ano | Select-String ':(80|443)\s.*LISTENING' | Write-Host

$exe = (Resolve-Path 'dist\windows-amd64\ontutunnel.exe').Path
$p = Start-Process $exe -PassThru
Start-Sleep 10

# 1. app running, version, window
$state = Invoke-RestMethod "$base/api/state"
Check 'App starts and dashboard answers' ($state.version -ne $null) "version $($state.version)"
$proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
Check 'App window "OntuTunnel" opened' ($proc -and $proc.MainWindowTitle -eq 'OntuTunnel') "title '$($proc.MainWindowTitle)'"

# 2. a second start brings the window back instead of a second copy
Start-Process $exe | Out-Null
Start-Sleep 4
$count = (Get-Process ontutunnel -ErrorAction SilentlyContinue | Measure-Object).Count
Check 'Second start does not run a second copy' ($count -eq 1) "$count running"

# 3. other websites can't use the API
$blocked = $false
try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/api/action" -ContentType 'text/plain' -Body '{"action":"refresh"}' -Headers @{ Origin = 'https://evil.example' } | Out-Null }
catch { $blocked = $_.Exception.Response.StatusCode.value__ -eq 403 }
Check 'Other websites are blocked (403)' $blocked

# 4. hosts file page: add, then delete
Act @{ action = 'hostsEdit'; edit = @{ op = 'add'; line = -1; raw = ''; ip = '127.0.0.1'; names = 'ot-ci.test' } } | Out-Null
Start-Sleep 2
$added = Select-String -Path $hosts -Pattern 'ot-ci\.test' -Quiet
$resolved = try { ([System.Net.Dns]::GetHostAddresses('ot-ci.test') | Select-Object -First 1).IPAddressToString } catch { '' }
Check 'Hosts page: add an entry' ($added -and $resolved -eq '127.0.0.1') "resolves to '$resolved'"
$entry = (Invoke-RestMethod "$base/api/state").hosts.entries | Where-Object { $_.names -eq 'ot-ci.test' } | Select-Object -First 1
Act @{ action = 'hostsEdit'; edit = @{ op = 'delete'; line = $entry.line; raw = $entry.raw } } | Out-Null
Start-Sleep 2
Check 'Hosts page: delete the entry' (-not (Select-String -Path $hosts -Pattern 'ot-ci\.test' -Quiet))

# 5. My static IP: sites go into the hosts file by themselves, and leave again
Act @{ action = 'saveService'; service = @{ name = 'CI'; domain = 'meet-ci.test'; localPort = 3000; enabled = $true } } | Out-Null
Act @{ action = 'setMode'; mode = 'staticIP' } | Out-Null
Start-Sleep 8
$text = Get-Content $hosts -Raw
Check 'Static IP: site added to hosts automatically' ($text -match '# BEGIN OntuTunnel' -and $text -match '127\.0\.0\.1\s+meet-ci\.test')
$st = Invoke-RestMethod "$base/api/state"
Check 'Static IP: OntuTunnel serves ports 80/443' ($st.proxy.state -eq 'listening') "$($st.proxy.state) $($st.proxy.detail)"
Act @{ action = 'setMode'; mode = 'relay' } | Out-Null
Start-Sleep 6
Check 'Leaving static IP removes the hosts entries' (-not ((Get-Content $hosts -Raw) -match 'meet-ci\.test'))

# 6. bad domain is refused
$refused = $false
try { $r = Act @{ action = 'saveService'; service = @{ name = 'x'; domain = 'bad;rm -rf'; localPort = 3000; enabled = $true } }; $refused = [bool]$r.error } catch { $refused = $true }
Check 'Unsafe domain is refused' $refused

# 7. SSH key: create one with a user name
Act @{ action = 'createKey'; user = 'ci-user' } | Out-Null
$k = (Invoke-RestMethod "$base/api/state").sshKeyInfos | Where-Object { $_.cloudUser -eq 'ci-user' }
Check 'Create SSH key with user name' ($k -ne $null) "$($k.name)"

# 8. Windows Firewall rule
Act @{ action = 'allowFirewall' } | Out-Null
Start-Sleep 2
$fw = (netsh advfirewall firewall show rule name=OntuTunnel) -join "`n"
Check 'Allow in Windows Firewall' ($fw -match 'OntuTunnel' -and $fw -notmatch 'No rules match')

# screenshot of the screen (the app window) for a human to look at
try {
  Act @{ action = 'refresh' } | Out-Null
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  New-Item -ItemType Directory -Force 'dist\smoke' | Out-Null
  $bmp.Save((Resolve-Path 'dist\smoke').Path + '\windows-app.png')
} catch { Write-Host "screenshot failed: $_" }

Get-Process ontutunnel -ErrorAction SilentlyContinue | Stop-Process -Force
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$results | ConvertTo-Json | Out-File -Encoding utf8 'dist\smoke\results.json'
if ($results.Result -contains 'FAIL') { exit 1 }
