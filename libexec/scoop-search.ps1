# Usage: scoop search <query>
# Summary: Search available apps
# Help: Searches for apps that are available to install.
#
# If used with [query], shows app names that match the query.
# Without [query], shows all the available apps.
param(
    $query,
    [Switch]$RebuildCache
)
. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\buckets.ps1"
. "$psscriptroot\..\lib\manifest.ps1"
. "$psscriptroot\..\lib\versions.ps1"

try {
    $query = New-Object Regex $query, 'IgnoreCase'
} catch {
    abort "Invalid regular expression: $($_.Exception.InnerException.Message)"
}

$RebuildCache = $false

function make_index(){
    Get-LocalBucket | ForEach-Object {
        $bucket = $_;
        apps_in_bucket (Find-BucketDirectory $bucket) | ForEach-Object {
            $manifest = manifest $_ $bucket;
            [array]$bin = extract_bin $manifest;
            [PSCustomObject]@{
                name = $_
                bin = $bin
                bucket = $bucket
                version = $manifest.version
            }
        }
    }
}

function extract_bin($manifest) {
    [array]$bin = if (!$manifest.bin) {
        $bin = @()
    }else {
        $manifest.bin
    }
    $bin | ForEach-Object {
        $exe, $alias, $args = $_;
        $fname = Split-Path $exe -Leaf -ErrorAction Stop
        return $alias ?? (strip_ext $fname)
    }
}

$search_index_path = "$cachedir\search_index.json";
if(!(Test-Path $search_index_path) -or $RebuildCache) {
    ensure $cachedir | Out-Null
    $search_index = make_index
    ConvertTo-Json $search_index | New-Item -Force $search_index_path | Out-Null
}

$search_index = Get-Content -Path $search_index_path | ConvertFrom-Json

function bin_match($manifest, $query) {
    if (!$manifest.bin) { return $false }
    $bins = foreach ($bin in $manifest.bin) {
        $exe, $alias, $args = $bin
        $fname = Split-Path $exe -Leaf -ErrorAction Stop

        if ((strip_ext $fname) -match $query) { $fname }
        elseif ($alias -match $query) { $alias }
    }
    if ($bins) { return $bins }
    else { return $false }
}
function download_json($url) {
    $ProgressPreference = 'SilentlyContinue'
    $result = Invoke-WebRequest $url -UseBasicParsing | Select-Object -ExpandProperty content | ConvertFrom-Json
    $ProgressPreference = 'Continue'
    $result
}

function github_ratelimit_reached {
    $api_link = "https://api.github.com/rate_limit"
    (download_json $api_link).rate.remaining -eq 0
}

function search_remote($bucket, $query) {
    $uri = [System.Uri](known_bucket_repo $bucket)
    if ($uri.AbsolutePath -match '/([a-zA-Z0-9]*)/([a-zA-Z0-9-]*)(?:.git|/)?') {
        $user = $Matches[1]
        $repo_name = $Matches[2]
        $api_link = "https://api.github.com/repos/$user/$repo_name/git/trees/HEAD?recursive=1"
        $result = download_json $api_link | Select-Object -ExpandProperty tree |
            Where-Object { $_.path -match "(^(.*$query.*).json$)" } |
            ForEach-Object { $Matches[2] }
    }

    $result
}

function search_remotes($query) {
    $buckets = known_bucket_repos
    $names = $buckets | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty name

    $results = $names | Where-Object { !(Test-Path $(Find-BucketDirectory $_)) } | ForEach-Object {
        @{ "bucket" = $_; "results" = (search_remote $_ $query) }
    } | Where-Object { $_.results }

    if ($results.count -gt 0) {
        Write-Host "Results from other known buckets...
(add them using 'scoop bucket add <bucket name>')"
    }

    $results | ForEach-Object {
        "'$($_.bucket)' bucket:"
        $_.results | ForEach-Object { "    $_" }
        ""
    }
}

$res = $search_index |
    Where-Object {
    if($_.name -match $query) { return $true }
    $_.bin = $_.bin | Where-Object { $_ -match $query }
    if($_.bin) {
        return $true;
    }
} | ForEach-Object {
    $item = [ordered]@{}
    $item.Name = $_.name
    $item.Version = $_.version
    $item.Source = $_.bucket
    $item.Binaries = ""
    if ($_.bin) { $item.Binaries = $_.bin -join ' | ' }
    [PSCustomObject]$item
}

if($res) {
    $res
    # $res | Group-Object -Property bucket | ForEach-Object {
    #     $bucket = $_.Name;
    #     $apps = $_.Group;

    #     Write-Host "'$bucket' bucket:"
    #     $apps | ForEach-Object {
    #         $item = "    $($_.name) ($($_.version))"
    #         if($_.bin) { $item += " --> includes '$($_.bin)'" }
    #         $item
    #     }
    #     ""
    # }
}

if (!$res -and !(github_ratelimit_reached)) {
    $remote_results = search_remotes $query
    if(!$remote_results) { [console]::error.writeline("No matches found."); exit 1 }
    $remote_results
}

exit 0
