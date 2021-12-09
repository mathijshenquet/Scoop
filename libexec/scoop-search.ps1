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

reset_aliases

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
    [array]$bin = $manifest.bin ?? @()
    $bin | ForEach-Object {
        $exe, $alias, $args = $_;
        $fname = Split-Path -Path $exe -leaf -ea stop
        return $alias ?? (strip_ext $fname)
    }
}

$search_index_path = "$cachedir\search_index.json";
if(!(Test-Path $search_index_path) -or $RebuildCache) {
    ensure $cachedir | Out-Null
    $search_index = make_index;
    ConvertTo-Json $search_index | New-Item -Force $search_index_path
}

$res = Get-Content -Path $search_index_path | ConvertFrom-Json

function bin_match($manifest, $query) {
    if(!$manifest.bin) { return $false }
    foreach($bin in $manifest.bin) {
        $exe, $alias, $args = $bin
        $fname = split-path $exe -leaf -ea stop

        if((strip_ext $fname) -match $query) { return $fname }
        if($alias -match $query) { return $alias }
    }
    $false
}
function download_json($url) {
    $progressPreference = 'silentlycontinue'
    $result = invoke-webrequest $url -UseBasicParsing | Select-Object -exp content | convertfrom-json
    $progressPreference = 'continue'
    $result
}

function github_ratelimit_reached {
    $api_link = "https://api.github.com/rate_limit"
    (download_json $api_link).rate.remaining -eq 0
}

function search_remote($bucket, $query) {
    $repo = known_bucket_repo $bucket

    $uri = [system.uri]($repo)
    if ($uri.absolutepath -match '/([a-zA-Z0-9]*)/([a-zA-Z0-9-]*)(.git|/)?') {
        $user = $matches[1]
        $repo_name = $matches[2]
        $api_link = "https://api.github.com/repos/$user/$repo_name/git/trees/HEAD?recursive=1"
        $result = download_json $api_link | Select-Object -exp tree | Where-Object {
            $_.path -match "(^(.*$query.*).json$)"
        } | ForEach-Object { $matches[2] }
    }

    $result
}

function search_remotes($query) {
    $buckets = known_bucket_repos
    $names = $buckets | get-member -m noteproperty | Select-Object -exp name

    $results = $names | Where-Object { !(test-path $(Find-BucketDirectory $_)) } | ForEach-Object {
        @{"bucket" = $_; "results" = (search_remote $_ $query)}
    } | Where-Object { $_.results }

    if ($results.count -gt 0) {
        "Results from other known buckets..."
        "(add them using 'scoop bucket add <name>')"
        ""
    }

    $results | ForEach-Object {
        "'$($_.bucket)' bucket:"
        $_.results | ForEach-Object { "    $_" }
        ""
    }
}

if($query) {
    try {
        $query = new-object regex $query, 'IgnoreCase'
    } catch {
        abort "Invalid regular expression: $($_.exception.innerexception.message)"
    }

    $res = $res | Where-Object {
        if($_.name -match $query) { return $true }
        $_.bin = $_.bin | Where-Object { $_ -match $query }
        if($_.bin) {
            return $true;
        }
    }
}

if($res) {
    $res | Group-Object -Property bucket | ForEach-Object {
        $bucket = $_.Name;
        $apps = $_.Group;

        Write-Host "'$bucket' bucket:"
        $apps | ForEach-Object {
            $item = "    $($_.name) ($($_.version))"
            if($_.bin) { $item += " --> includes '$($_.bin)'" }
            $item
        }
        ""
    }
}

if (!$res -and !(github_ratelimit_reached)) {
    $remote_results = search_remotes $query
    if(!$remote_results) { [console]::error.writeline("No matches found."); exit 1 }
    $remote_results
}

exit 0
