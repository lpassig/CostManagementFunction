<#
.SYNOPSIS
Getting Cost Management related information and send it via e-mail 

.DESCRIPTION
Query multiple Azure APIs to get: Azure Advisor Recommendations (Cost Category only), Current Budget and current Spend. 
Aggregate the data into a HTML report and send it via e-mail. The function uses a Managed Service Identity (MSI) to queries 
the Azure APIs and the Key Vault. 

.PARAMETER Timer
Timer is set to go off every day at 10:00 

.NOTES

## General Advice ##
Be aware that the mail send will most certainly go into your SPAM folder as fist!!! 
Be aware that this is a version 0.1 not following all Powershell best practices!

Function Version: ~2 
PowerShell Version: PowerShell Core 6

## Prerequisites ## 

# Permissions #
The MSI needs "Microsoft.Advisor/generateRecommendations/action" and "Cost Management Reader" permission on Subscription level
The MSI needs "Get" permission on the Key Vault secret (via the Access policy in the Key Vault)

# Resources #
"Azure Key Vault" needs to exist
"Azure Budget" needs to exist 
"Azure Tag" needs to exists and assinged on several resouces (Ideal Tag would be "costcenter")
"Sendgrid Account" needs to exist
"SendGrid API" Key needs to exist and saved as a "Secret" in the "Azure Key Vault"

#>

# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)) {
    Connect-AzAccount -Identity
}
# The 'IsPastDue' porperty is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}
# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

<# Get Bearer Token #>
$currentAzureContext = Get-AzContext
$azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile;
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile);
$token = $profileClient.AcquireAccessToken($currentAzureContext.Subscription.TenantId).AccessToken;

<# Variables #>

# Subscription ID of the Subscription that shoud be queried
$sub = 'xxxxxxxx-yyyy-zzzz-xxxx-yyyyyyyyyyyy'
#  Name of the budget that exists on teh subscription (Must exist) 
$budgetname = "testbudget"
#  Name of the Resource Tag that can be used to group costs (CostCenter Tag would be ideal; Tag must exist)
$costCenterTag = "costcenter"
#  Abbreviation of the currency the Enterprise Agreement has been created under (for most German Customers it will be "EUR" instead of "USD")
$currency = "USD"
# Name of the Key Vault in which the API Key for SendGrid has been created (MUST EXIST)
$VaultName = 'company-core-001-kv'
# Name of the Secret that has the value saved for the API Key for SendGrid (MUST EXIST)
$SecretName = 'SendGridAPIKey'
# Mail Address of the mail recipient  
$ToAddress = "my@mail.com"
# Display Name of the recipient  
$ToName = "My - Mail"
# Time out for the Advisor Reccommendations (60 is Default)
$timeout = 60
# Headers for Authorization and Content-Type to be able to query and get a result for all APIs corrececly
$headers = @{'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }

<#
# Advisor Generate Recommendations on the fly 
#>
function New-AdvisorRecommendations($sub, $headers, $timeout) {
    $uri = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Advisor/generateRecommendations?api-version=2017-03-31"
    Write-Debug ("POST {0}" -f $uri)
    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers
    $statusuri = New-Object System.Uri($response.Headers.Location)
    Write-Debug ("GET {0}" -f $statusUri)
    $secondsElapsed = 0
    while ($secondsElapsed -lt $timeout) {
        $response = Invoke-WebRequest -Uri $statusUri -Method Get -Headers $headers
        if ($response.StatusCode -eq 204) { break }
        Write-Host ("Waiting for generation to complete for subscription {0}..." -f $sub)
        Start-Sleep -Seconds 1
        $secondsElapsed++
    }
    $result = New-Object PSObject -Property @{"SubscriptionId" = $sub; "Status" = "Success"; "SecondsElapsed" = $secondsElapsed }
    if ($secondsElapsed -ge $timeout) {
        $result.Status = "Timed out"
    }
}     
<#
# Advisor Get updated or created Recommendations
#>
function Get-Advisor($sub, $headers) {
    $AdvisorRecommendationsUri = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Advisor/recommendations?api-version=2017-04-19"
    $result = "letscheck"
    try {
        $AdvisorRecommendationsResult = Invoke-WebRequest -Uri $AdvisorRecommendationsUri -Method Get -Headers $headers
    }   
    catch {
        $result = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code
    }

    $AdvisorRecommendationsResultjson = $AdvisorRecommendationsResult.Content | ConvertFrom-Json 
    $null = $AdvisorRecommendationsResultjson.value.properties 
    $AdvisorRecommendationsResultdata = $AdvisorRecommendationsResultjson.value.properties | Where-Object category -like Cost | Select-Object -ExcludeProperty lastUpdated, recommendationTypeId, resourceMetadata
    
    if ([string]::IsNullOrEmpty($AdvisorRecommendationsResultdata)) {
        $AdvisorRecommendationsResultdata = "You are following all of our cost recommendations for the selected subscriptions and resources."
        
    }
    
    return $AdvisorRecommendationsResultdata
}
<#
# Get and Create Cost Management Report
#>
function Get-CostManagement($sub, $headers, $budgetname, $costCenterTag, $currency, $timeout) {
    $costManagementBody = @"
{
    "properties": {
        "currency": "$currency",
        "dateRange": "ThisMonth",
        "query": {
            "type": "ActualCost",
            "dataSet": {
                "granularity": "Daily",
                "aggregation": {
                    "totalCost": {
                        "name": "PreTaxCost",
                        "function": "Sum"
                    },
                    "totalCost$currency": {
                        "name": "PreTaxCost$currency",
                        "function": "Sum"
                    }
                },
                "sorting": [
                    {
                        "direction": "ascending",
                        "name": "UsageDate"
                    }
                ]
            },
            "timeframe": "None"
        },
        "chart": "Area",
        "accumulated": "true",
        "pivots": [
            {
                "type": "Dimension",
                "name": "ServiceName"
            },
            {
                "type": "TagKey",
                "name": "$costCenterTag"
            },
            {
                "type": "Dimension",
                "name": "ResourceGroupName"
            }
        ],
        "scope": "subscriptions/$sub",
        "kpis": [
            {
                "type": "Budget",
                "id": "subscriptions/$sub/providers/Microsoft.Consumption/budgets/$budgetname",
                "enabled": true
            },
            {
                "type": "Forecast",
                "enabled": false
            }
        ],
        "displayName": "Spending"
    }
}
"@
    $uriCostManagement = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CostManagement/views/render?api-version=2019-11-01"
    $response = Invoke-WebRequest -Uri $uriCostManagement -Method Post -Headers $headers -Body $costManagementBody -TimeoutSec $timeout
    $data = $Response.Content | ConvertFrom-Json
    $UrlDownloadpicture = $data.properties.imageUrl
    $webclient = New-Object System.Net.WebClient
    $imageBytes = $webClient.DownloadData($UrlDownloadpicture);

    $ImageBits = [System.Convert]::ToBase64String($imageBytes)
    $costreport = "<p><center><h2>Current Azure Spend and Azure Budget</h2></center></p><center><img src=data:image/png;base64,$($ImageBits) alt='CostReport'/></center>"

    return $costreport
}
<#
# Create HTML Report accordingly
#>
function New-HtmlReport($AdvisorRecommendationsResultdata, $costreport) {
    $head = "
    <style>
    h1 {font-family: Arial, Helvetica, sans-serif; color: #007bd4; font-size: 28px;}
    h2 {font-family: Arial, Helvetica, sans-serif; color: #007bd4; font-size: 22px;}
    h3 {font-family: Arial, Helvetica, sans-serif; color: black; font-size: 18px;}
    td {padding: 4px; margin: 0px; border: 0; background-color: #ebebeb; font-family: Arial, Helvetica, sans-serif;}
    table {width: 100%; font-family: Arial, Helvetica, sans-serif;}
    th {padding: 4px; margin: 0px; border: 0; font-size: 14pt; background-color: #75757a; font-family: Arial, Helvetica, sans-serif;}
    </style>
    <title>Azure Cost Management Report</title>"

    if ($AdvisorRecommendationsResultdata -ne "You are following all of our cost recommendations for the selected subscriptions and resources.") {

        # Create Additional Infos for VMs explaining the evaluation model of Azure Advisor for VM Cost reccomendations. 
        $additionalinfo = '<p>The recommended actions are <b>shut down</b> or <b>resize</b>, specific to the resource being evaluated. Advisor shows the estimated cost savings for either recommended action.</p> 
        <p><h3>Shut Down VM</h3></p>
        <p>The advanced evaluation model in Advisor considers shutting down virtual machines when both of these statements are true:</p>
        <ul>
        <li>P95th of the maximum of maximum value of CPU utilization is less than 3%.</li>
        <li>Network utilization is less than 2% over a seven-day period.</li>
        <li>Memory pressure is lower than the threshold values</li>
        </ul>
        <p><h3>Resize VM</h3></p>
        <p>Advisor considers resizing virtual machines when it is possible to fit the current load in a smaller SKU (within the same SKU family) or a smaller number of instances such that:</p>
        <ul>
        <li>The current load does not go above 80% utilization for workloads that are not user facing.</li>
        <li>The load does not go above 40% for user-facing workloads.</li>
        </ul>
        <p>Here, Advisor determines the type of workload by analyzing the CPU utilization characteristics of the workload. For resize, Advisor provides current and target SKU information.</p>
        <p><a href="https://docs.microsoft.com/en-us/azure/advisor/advisor-cost-recommendations" data-linktype="external">Learn more</a></p>'

        $AdvisorRecommendationsResulthtml = $AdvisorRecommendationsResultdata | Sort-Object -Property $_.category | Select-Object -property @{Name = 'Advisor Category'; Expression = { $_.category } }, `
        @{Name = 'Business Impact'; Expression = { $_.impact } }, `
        @{Name = 'Resource Type'; Expression = { $_.impactedField } }, `
        @{Name = 'Resource Name'; Expression = { $_.impactedValue } }, `
        @{Name = 'Advice'; Expression = { $_.shortDescription[0].problem } } `
        | ConvertTo-Html -Fragment -As Table

        $htmlreport = ConvertTo-Html -Head $head -PreContent "<p><center><h1>Azure Cost Management Report</h1></center></p>" -PostContent "$costreport<p><center><h2>Azure Advisor Cost Recommendations</h2></center></p><p>$AdvisorRecommendationsResulthtml</p>$additionalinfo<p><center>Browse the Advisor Portal: aka.ms/azureadvisordashboard for more detailes!</center></p>"

    }
    if ($AdvisorRecommendationsResultdata -eq "You are following all of our cost recommendations for the selected subscriptions and resources.") {
        
        $AdvisorRecommendationsResulthtml = $AdvisorRecommendationsResultdata 
        $htmlreport = ConvertTo-Html -Head $head -PreContent "<p><center><h1>Azure Cost Management Report</h1></center></p>" -PostContent "$costreport<p><center><h2>Azure Advisor Cost Recommendations</h2></center></p><p><center><h3>$AdvisorRecommendationsResulthtml</h3></center></p><p><center>Browse the Advisor Portal: aka.ms/azureadvisordashboard for more detailes!</center></p>"

    }    

    return $htmlreport     
}
<#
# Send Mail via SendGrid 
#>
Function Send-SendGridMail {
    param (
        [cmdletbinding()]
        [parameter()]
        [string]$ToAddress,
        [parameter()]
        [string]$ToName,
        [parameter()]
        [string]$FromAddress,
        [parameter()]
        [string]$FromName,
        [parameter()]
        [string]$Subject,
        [parameter()]
        [string]$BodyAsHTML,
        [parameter()]
        [string]$Token
    )

    $MailbodyType = 'text/HTML'
    $MailbodyValue = $BodyAsHTML
    
    # Create a body for sendgrid
    $SendGridBody = @{
        "personalizations" = @(
            @{
                "to"      = @(
                    @{
                        "email" = $ToAddress
                        "name"  = $ToName
                    }
                )
                "subject" = $Subject
            }
        )
        "content"          = @(
            @{
                "type"  = $mailbodyType
                "value" = $MailBodyValue
            }
        )
        "from"             = @{
            "email" = $FromAddress
            "name"  = $FromName
        }
    }

    $BodyJson = $SendGridBody | ConvertTo-Json -Depth 4

    #Create the header
    $Header = @{
        "authorization" = "Bearer $token"
    }
    #send the mail through Sendgrid
    $Parameters = @{
        Method      = "POST"
        Uri         = "https://api.sendgrid.com/v3/mail/send"
        Headers     = $Header
        ContentType = "application/json"
        Body        = $BodyJson
    }
    Invoke-RestMethod @Parameters
}

# Generate Azure Advisor Recommendations
New-AdvisorRecommendations -sub $sub -headers $headers -timeout $timeout
# Get Azure Advisor Recommendations after Generation is done
$AdvisorRecommendationsResultdata = Get-Advisor -sub $sub -headers $headers
# Get Custom Cost Report
$costreport = Get-CostManagement -sub $sub -headers $headers -budgetname $budgetname -costCenterTag $costCenterTag -currency $currency -timeout $timeout
# Generate HTML Report
$htmlbody = New-HtmlReport -AdvisorRecommendationsResultdata $AdvisorRecommendationsResultdata -costreport $costreport 
# Get SendGrid Key From KeyVault 
$apiKey = (Get-AzKeyVaultSecret –VaultName $VaultName -Name $SecretName).SecretValueText
# Define Mail Parameters
$MailParameters = @{
    ToAddress   = $ToAddress
    ToName      = $ToName
    FromAddress = "Xq0OdMAqR-6xaTMkLJFS0Q@ismtpd0006p1lon1.sendgrid.net"
    FromName    = "Lennart's Azure Function"
    Subject     = "Azure Cost Management"
    BodyAsHTML  = "$htmlbody"
    Token       = $apiKey

}
# Send Mail via Sendgrid (Check Spam Folder!!!)
Send-SendGridMail @MailParameters

Write-Host "Mail successfully sent to: $ToAddress"