$starttime = Get-Date
Write-Host -ForegroundColor Green "Deployment Started $starttime"

$signedInUser = (az ad signed-in-user show --query userPrincipalName --output tsv).Trim()
$upnsuffix = $signedInUser.Split('@')[1]

$password = Read-Host "Please enter a password"
$securepassword = ConvertTo-SecureString -String $password -AsPlainText -Force

$user = "contributoruser@$upnsuffix"
$displayname = "contributoruser"

Write-Host -ForegroundColor Green "###########################################################################"
Write-Host -ForegroundColor Green "# Creating new admin user $user in Entra ID #"
Write-Host -ForegroundColor Green "###########################################################################"

$newUser = New-AzADUser -DisplayName $displayname -UserPrincipalName $user -Password $securepassword -MailNickname $displayname -AccountEnabled $true

$userObjectId = $newUser.Id
if (-not $userObjectId) {
    Start-Sleep -Seconds 5
    $userObjectId = (Get-AzADUser -UserPrincipalName $user).Id
}

# Obtain subscription details
$subid = (az account show --query id --output tsv).Trim()

Write-Host -ForegroundColor Green "#########################################################################"
Write-Host -ForegroundColor Green "# Assigning the Contributor role to $user #"
Write-Host -ForegroundColor Green "#########################################################################"

Write-Host "Waiting a moment for directory synchronization..."
Start-Sleep -Seconds 10
az role assignment create --role "Contributor" --assignee-object-id $userObjectId --assignee-principal-type "User" --scope "/subscriptions/$subid"

# Set variables and create resource group
$group = "contributortest"
$location = "eastus"
$vm1name = "winvm01"
$vm2name = "linuxvm01"
az group create --name $group --location $location

az vm create -g $group -n $vm1name --image Win2019Datacenter --admin-username azureuser --admin-password $password --size Standard_B2als_v2
az vm create -g $group -n $vm2name --image Ubuntu2204 --admin-username azureuser --admin-password $password --size Standard_B2als_v2    

az vm open-port --port 3389 --resource-group $group --name $vm1name
az vm open-port --port 22 --resource-group $group --name $vm2name

az vm identity assign -g $group -n $vm1name --role Contributor --scope /subscriptions/$subid
az vm identity assign -g $group -n $vm2name --role Owner --scope /subscriptions/$subid

# Script Output
Start-Transcript -Path contributor-iaas-scenario-output.txt
Write-Host -ForegroundColor Green "#################################"
Write-Host -ForegroundColor Green "# Script Output #"
Write-Host -ForegroundColor Green "#################################"
Write-Host -ForegroundColor Green "Azure Contributor Admin User:" $user
Write-Host -ForegroundColor Green "Azure Contributor Admin User Password:" $password
Write-Host -ForegroundColor Green " "
Stop-Transcript
$endtime = Get-Date
Write-Host -ForegroundColor Green "Deployment Ended $endtime"
