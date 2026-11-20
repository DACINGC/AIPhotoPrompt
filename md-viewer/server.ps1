<#
 ============================================================
  提示词资料查看器 - 本地服务器 (零依赖, 基于 Windows PowerShell)
  用法:  双击项目根目录的「启动查看器.bat」
  参数:  -Port 8377       监听端口(被占用时自动 +1 重试)
         -DocRoot <路径>  文档根目录(默认: 脚本所在目录的上一级)
         -NoOpen          启动后不自动打开浏览器(测试用)
 ============================================================
#>
param(
    [int]$Port = 8377,
    [string]$DocRoot = "",
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

$ViewerDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DocRoot)) {
    $DocRoot = (Resolve-Path (Join-Path $ViewerDir '..')).Path
}
$IndexHtmlPath = Join-Path $ViewerDir 'index.html'
$ExcludeDirs = @('md-viewer', '.git', '.vscode', '.cursor', 'node_modules', '__pycache__')

# ---------- 文本读取(自适应编码: BOM / UTF-8 / GBK) ----------
function Get-SmartFileText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $strictUtf8.GetString($bytes) }
    catch { return [System.Text.Encoding]::GetEncoding(936).GetString($bytes) }
}

# ---------- 取文档标题(首个 Markdown 标题行) ----------
function Get-MdTitle {
    param([string]$Path, [string]$Fallback)
    try {
        $text = Get-SmartFileText $Path
        foreach ($line in ($text -split '\r?\n')) {
            if ($line -match '^(#{1,6})\s+(.+?)\s*$') { return $Matches[2].Trim() }
        }
    } catch { }
    return $Fallback
}

# ---------- 递归遍历文档目录下所有 md 文件 ----------
function Get-AllMdFiles {
    $files = @()
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $DocRoot))
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        foreach ($child in (Get-ChildItem -LiteralPath $cur.FullName -Force)) {
            if ($child.PSIsContainer) {
                if ($ExcludeDirs -notcontains $child.Name -and -not $child.Name.StartsWith('.')) {
                    $stack.Push($child)
                }
            }
            elseif ($child.Extension -ieq '.md' -or $child.Extension -ieq '.markdown') {
                $files += $child
            }
        }
    }
    return , $files
}

# ---------- 相对路径(统一用 / 分隔) ----------
function Get-RelPath {
    param([string]$FullPath)
    $rel = $FullPath.Substring($DocRoot.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

# ---------- 手动解析 URL 查询参数(强制 UTF-8 解码, 修复中文乱码) ----------
function Get-QueryParam {
    param($Request, [string]$Name)
    $raw = $Request.Url.Query
    if (-not $raw) { return $null }
    $raw = $raw.TrimStart('?')
    if (-not $raw) { return $null }
    foreach ($pair in ($raw -split '&')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -lt 2) { continue }
        $k = [System.Uri]::UnescapeDataString($kv[0])
        if ($k -eq $Name) { return [System.Uri]::UnescapeDataString($kv[1]) }
    }
    return $null
}

# ---------- 安全路径解析(限制在文档根目录内, 防目录穿越) ----------
function Resolve-SafePath {
    param([string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $null }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($DocRoot).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($RelPath -replace '/', '\')))
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $full }
    } catch { }
    return $null
}

# ---------- HTTP 响应 ----------
function Send-Bytes {
    param($Context, [byte[]]$Data, [string]$ContentType, [int]$Status = 200)
    $resp = $Context.Response
    try {
        $resp.StatusCode = $Status
        $resp.ContentType = $ContentType
        $resp.AddHeader('Cache-Control', 'no-store')
        $resp.ContentLength64 = $Data.Length
        $resp.OutputStream.Write($Data, 0, $Data.Length)
    }
    finally {
        try { $resp.OutputStream.Close() } catch { }
    }
}

function Send-Text {
    param($Context, [string]$Text, [string]$ContentType, [int]$Status = 200)
    Send-Bytes $Context ([System.Text.Encoding]::UTF8.GetBytes($Text)) $ContentType $Status
}

function Send-Json {
    param($Context, $Data, [int]$Status = 200)
    Send-Text $Context (ConvertTo-Json -InputObject $Data -Depth 8 -Compress) 'application/json; charset=utf-8' $Status
}

# ---------- 各类请求处理 ----------
function Handle-Request {
    param($Context)
    $req = $Context.Request
    $path = $req.Url.AbsolutePath

    # 主页面
    if ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/viewer') {
        Send-Text $Context ([System.IO.File]::ReadAllText($IndexHtmlPath)) 'text/html; charset=utf-8'
        return
    }

    # 文档列表
    if ($path -eq '/api/list') {
        $items = @()
        foreach ($f in (Get-AllMdFiles)) {
            $rel = Get-RelPath $f.FullName
            $dir = ''
            $ni = $rel.LastIndexOf('/')
            if ($ni -ge 0) { $dir = $rel.Substring(0, $ni) }
            $items += [ordered]@{
                path  = $rel
                name  = $f.Name
                dir   = $dir
                title = (Get-MdTitle -Path $f.FullName -Fallback $f.BaseName)
                mtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                size  = $f.Length
            }
        }
        $sorted = @($items | Sort-Object -Property @{ e = 'dir' }, @{ e = 'name' })
        Send-Json $Context @{ data = $sorted; count = $sorted.Count }
        return
    }

    # 单个文档内容
    if ($path -eq '/api/file') {
        $rel = [string](Get-QueryParam $req 'p')
        $full = Resolve-SafePath $rel
        if (-not $full) { Send-Json $Context @{ error = '非法路径' } 400; return }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Send-Json $Context @{ error = '文件不存在' } 404; return }
        $fi = Get-Item -LiteralPath $full
        Send-Json $Context @{ data = [ordered]@{
                path    = $rel
                title   = (Get-MdTitle -Path $full -Fallback $fi.BaseName)
                mtime   = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                size    = $fi.Length
                content = (Get-SmartFileText $full)
            } }
        return
    }

    # 全文搜索
    if ($path -eq '/api/search') {
        $keyword = [string](Get-QueryParam $req 'q')
        if ([string]::IsNullOrWhiteSpace($keyword)) { Send-Json $Context @{ data = @() }; return }
        $results = @()
        foreach ($f in (Get-AllMdFiles)) {
            if ($results.Count -ge 50) { break }
            $text = Get-SmartFileText $f.FullName
            $relPath = Get-RelPath $f.FullName
            $hits = @()
            $hIdx = -1; $hText = ''
            $inCode = $false; $inComment = $false
            foreach ($line in ($text -split '\r?\n')) {
                if ($inComment) {
                    if ($line -match '-->') { $inComment = $false }
                    continue
                }
                if ($line -match '<!--') {
                    if ($line -notmatch '-->') { $inComment = $true }
                    continue
                }
                $t = $line.Trim()
                if ($t -match '^(```|~~~)') { $inCode = -not $inCode; continue }
                if (-not $inCode -and $t -match '^(#{1,6})\s+(.+?)\s*$') {
                    $hIdx++
                    $hText = $Matches[2].Trim()
                    # 标题行本身也可被搜索命中
                    if ($hits.Count -lt 20 -and $t.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $hits += [ordered]@{ hi = $hIdx; h = $hText; text = $t }
                    }
                    continue
                }
                if ($hits.Count -ge 20) { continue }
                if ($line.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $sn = $t
                    if ($sn.Length -gt 280) { $sn = $sn.Substring(0, 280) + '...' }
                    $hits += [ordered]@{ hi = $hIdx; h = $hText; text = $sn }
                }
            }
            if ($hits.Count -gt 0) {
                $results += [ordered]@{
                    path    = $relPath
                    title   = (Get-MdTitle -Path $f.FullName -Fallback $f.BaseName)
                    matches = @($hits)
                }
            }
        }
        Send-Json $Context @{ data = @($results) }
        return
    }

    # 静态图片(md 中引用的本地图片)
    if ($path -eq '/files') {
        $rel = [string](Get-QueryParam $req 'p')
        $full = Resolve-SafePath $rel
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Send-Text $Context 'Not Found' 'text/plain; charset=utf-8' 404; return
        }
        $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
        $mimeMap = @{
            '.png'  = 'image/png';  '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
            '.gif'  = 'image/gif';  '.webp' = 'image/webp'; '.bmp' = 'image/bmp'
            '.svg'  = 'image/svg+xml'; '.ico' = 'image/x-icon'
        }
        if (-not $mimeMap.ContainsKey($ext)) {
            Send-Text $Context 'Forbidden' 'text/plain; charset=utf-8' 403; return
        }
        Send-Bytes $Context ([System.IO.File]::ReadAllBytes($full)) $mimeMap[$ext]
        return
    }

    Send-Json $Context @{ error = 'not found' } 404
}

# ---------- 选择可用端口 ----------
$listener = $null
$chosenPort = 0
$p = $Port
while ($p -lt ($Port + 20)) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $chosenPort = $p; break }
    catch { try { $l.Close() } catch { }; $p++ }
}
if (-not $listener) {
    Write-Host "[错误] 端口 $Port ~ $($Port + 19) 均被占用, 无法启动服务。" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  ================================================"
Write-Host "    提示词资料查看器 已启动"
Write-Host "  ================================================"
Write-Host "    文档目录 : $DocRoot"
Write-Host "    服务地址 : http://localhost:$chosenPort/"
Write-Host "    停止服务 : 关闭本窗口, 或按 Ctrl+C"
Write-Host ""
Write-Host "    (保持本窗口开启即可; 修改/新增 md 后在页面点「刷新」)"
Write-Host ""

if (-not $NoOpen) { Start-Process "http://localhost:$chosenPort/" }

# ---------- 请求主循环 ----------
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        Handle-Request $ctx
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "[请求出错] $msg" -ForegroundColor Yellow
        try { Send-Json $ctx @{ error = $msg } 500 } catch { }
    }
}
