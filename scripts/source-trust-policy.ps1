function Set-SourceTrustProperty {
    param($Item, [string]$Name, $Value)
    if ($Item.PSObject.Properties[$Name]) {
        $Item.$Name = $Value
    }
    else {
        $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-SourceTrustClass {
    param($Item)

    $url = [string]$Item.url
    if (-not $url -and $Item.PSObject.Properties["primarySourceUrl"]) {
        $url = [string]$Item.primarySourceUrl
    }
    $sourceHost = ""
    try { $sourceHost = ([uri]$url).Host.ToLowerInvariant() } catch {}
    $source = ([string]$Item.source).ToLowerInvariant()
    $platform = ([string]$Item.platform).ToLowerInvariant()

    if ($platform -eq "x" -or $sourceHost -in @("x.com", "www.x.com", "twitter.com", "www.twitter.com")) {
        return "social_post"
    }
    if ($source -match '\b(media|press) confirmation\b|\breported by\b') {
        return "general_media"
    }
    if ($sourceHost -match '(^|\.)(trendforce\.com|dramexchange\.com|semianalysis\.com|omdia\.com|techinsights\.com|counterpointresearch\.com)$') {
        return "specialist_research"
    }
    if ($sourceHost -match '(^|\.)(digitimes\.com|digitimes\.com\.tw|tomshardware\.com|theregister\.com|wccftech\.com|techradar\.com|sammyfans\.com|datacenterdynamics\.com|blocksandfiles\.com|lightreading\.com)$') {
        return "trade_press"
    }
    if ($sourceHost -match '(^|\.)(reuters\.com|cnbc\.com|bloomberg\.com|wsj\.com|ft\.com|nytimes\.com|politico\.com|axios\.com|theinformation\.com)$') {
        return "general_media"
    }
    if ($sourceHost -match '(^|\.)(businesswire\.com|globenewswire\.com|prnewswire\.com)$') {
        return "wire_release"
    }
    if ($sourceHost -match '\.gov$|\.gov\.') {
        return "government_primary"
    }
    if ($sourceHost -match '(^|\.)(huggingface\.co|github\.com|arxiv\.org)$' -and [bool]$Item.hasPrimaryEvidence) {
        return "official_repository"
    }
    if ($platform -eq "substack" -or $sourceHost -match '(^|\.)(substack\.com)$') {
        return "newsletter_analysis"
    }
    if ([bool]$Item.hasPrimaryEvidence) {
        return "official_primary"
    }
    return "secondary_analysis"
}

function Limit-SourceTrustScore {
    param($Item, [int]$MaximumScore)

    $score = [int]$Item.significance + [int]$Item.credibility + [int]$Item.timeliness + [int]$Item.depth
    $excess = [Math]::Max(0, $score - $MaximumScore)
    foreach ($field in @("depth", "timeliness", "significance")) {
        if ($excess -le 0) { break }
        $current = [Math]::Max(0, [int]$Item.$field)
        $reduction = [Math]::Min($current, $excess)
        Set-SourceTrustProperty $Item $field ($current - $reduction)
        $excess -= $reduction
    }
    Set-SourceTrustProperty $Item "score" ([int]$Item.significance + [int]$Item.credibility + [int]$Item.timeliness + [int]$Item.depth)
}

function Apply-SourceTrustPolicy {
    param($Item)

    $class = Get-SourceTrustClass $Item
    $independent = [bool]$Item.hasIndependentConfirmation
    $label = "Source classification pending"
    $note = "Source type does not change the underlying claim."
    $credibilityCap = 25
    $scoreCap = 100

    switch ($class) {
        "specialist_research" {
            $label = "Specialist research"
            $note = "Useful channel checks and estimates; not primary evidence of a third party's unannounced plans."
            Set-SourceTrustProperty $Item "hasPrimaryEvidence" $false
            Set-SourceTrustProperty $Item "isBreaking" $false
            Set-SourceTrustProperty $Item "mustInclude" $false
            $credibilityCap = if ($independent) { 20 } else { 16 }
            $isResearchAnalysis = ([string]$Item.eventType).ToLowerInvariant() -in @("research", "commentary")
            $scoreCap = if ($isResearchAnalysis) { 79 } elseif ($independent) { 74 } else { 69 }
        }
        "trade_press" {
            $label = "Trade reporting"
            $note = "Secondary reporting; requires issuer, filing or independent confirmation for breaking status."
            Set-SourceTrustProperty $Item "hasPrimaryEvidence" $false
            Set-SourceTrustProperty $Item "isBreaking" $false
            Set-SourceTrustProperty $Item "mustInclude" $false
            $credibilityCap = if ($independent) { 18 } else { 14 }
            $scoreCap = if ($independent) { 74 } else { 69 }
        }
        "general_media" {
            $label = "Media reporting"
            $note = "Secondary reporting; a background document does not verify a newly reported event."
            Set-SourceTrustProperty $Item "hasPrimaryEvidence" $false
            Set-SourceTrustProperty $Item "isBreaking" $false
            Set-SourceTrustProperty $Item "mustInclude" $false
            $credibilityCap = if ($independent) { 18 } else { 13 }
            $scoreCap = if ($independent) { 74 } else { 69 }
        }
        "newsletter_analysis" {
            $label = "Newsletter analysis"
            $note = "Analysis is scored for evidence and depth, but is not issuer confirmation."
            if (-not [bool]$Item.hasPrimaryEvidence) {
                Set-SourceTrustProperty $Item "isBreaking" $false
                Set-SourceTrustProperty $Item "mustInclude" $false
                $credibilityCap = if ($independent) { 20 } else { 16 }
                $scoreCap = 79
            }
        }
        "wire_release" {
            $label = "Issuer release via distribution wire"
            $note = "Primary only when the release is explicitly attributable to the issuer; the wire itself is not independent corroboration."
            $credibilityCap = if ($independent) { 25 } else { 22 }
        }
        "government_primary" {
            $label = "Official government source"
            $note = "Primary evidence for the action documented on the page."
            $credibilityCap = if ($independent) { 25 } else { 22 }
        }
        "official_repository" {
            $label = "Official repository or paper"
            $note = "Primary evidence for the artifact published at this URL."
            $credibilityCap = if ($independent) { 25 } else { 22 }
        }
        "official_primary" {
            $label = "Official issuer source"
            $note = "Primary evidence for the issuer's own announcement; single-source claims are not independently corroborated."
            $credibilityCap = if ($independent) { 25 } else { 22 }
        }
        "social_post" {
            $label = "X post"
            $note = "Scored under the account and evidence policy for X commentary."
        }
        default {
            $label = "Secondary analysis"
            $note = "Not primary evidence of the underlying event."
            if (([string]$Item.platform).ToLowerInvariant() -eq "web") {
                Set-SourceTrustProperty $Item "isBreaking" $false
                Set-SourceTrustProperty $Item "mustInclude" $false
                $credibilityCap = if ($independent) { 18 } else { 14 }
                $scoreCap = if ($independent) { 74 } else { 69 }
            }
        }
    }

    if ([int]$Item.credibility -gt $credibilityCap) {
        Set-SourceTrustProperty $Item "credibility" $credibilityCap
    }
    Set-SourceTrustProperty $Item "sourceTrustClass" $class
    Set-SourceTrustProperty $Item "sourceTrustLabel" $label
    Set-SourceTrustProperty $Item "sourceTrustNote" $note
    Limit-SourceTrustScore $Item $scoreCap
    return $Item
}
