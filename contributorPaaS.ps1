$starttime = Get-Date
Write-Host -ForegroundColor Green "Deployment Started $starttime"

# Ensure you are logged into both Az and Azure CLI if running locally

## Check and Register Required Resource Providers
Write-Host -ForegroundColor Green "###########################################################################"
Write-Host -ForegroundColor Green "# Checking and registering required Azure resource providers               #"
Write-Host -ForegroundColor Green "###########################################################################"
$providers = @("Microsoft.KeyVault", "Microsoft.Sql", "Microsoft.Web", "Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage", "Microsoft.Automation")
foreach ($provider in $providers) {
    $state = az provider show -n $provider --query registrationState -o tsv
    if ($state -ne "Registered") {
        Write-Host -ForegroundColor Yellow "Registering $provider..."
        az provider register --namespace $provider
        # Wait until the provider registration is complete
        while ((az provider show -n $provider --query registrationState -o tsv) -ne "Registered") {
            Write-Host -NoNewline "."
            Start-Sleep -Seconds 5
        }
        Write-Host ""
        Write-Host -ForegroundColor Green "$provider registered successfully."
    } else {
        Write-Host -ForegroundColor Green "$provider is already registered."
    }
}

## Create contributoruser
$upn = az ad signed-in-user show --query userPrincipalName --output tsv
$upnsuffix = $upn.Split('@')[-1]
$password = Read-Host "Please enter a password (must meet complex requirements)"
$securepassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$user = "contributoruser@$upnsuffix"
$displayname = $user.Split('@')[0]

Write-Host -ForegroundColor Green "###########################################################################"
Write-Host -ForegroundColor Green "# Creating new admin user $user in Azure AD #"
Write-Host -ForegroundColor Green "###########################################################################"
New-AzADUser -DisplayName $displayname -UserPrincipalName $user -Password $securepassword -MailNickname $displayname

## assign role in Azure subscription
$subid = az account show --query id --output tsv
Write-Host -ForegroundColor Green "#########################################################################"
Write-Host -ForegroundColor Green "# Assigning the Contributor role to $user #"
Write-Host -ForegroundColor Green "#########################################################################"
az role assignment create --role "Contributor" --assignee $user --subscription $subid

## Set variables and create resource group
$group = "contributorPaaS"
$random = Get-Random -Maximum 10000
$random2 = Get-Random -Maximum 100
$webappname = "webapp$random"
$keyvaultname = "azptkv$random"
$aciname = "aci$random"
$storagename = "privstore$random$random2"
$cosmosname = "cosmos$random"
$sqlsrvname = "sqlsrv$random"
$acrname="acr$random"
$location = "eastasia" # change this if needed
$gitrepo = "https://github.com/Azure-Samples/php-docs-hello-world"
$vmfqdn = "ptlinuxvm$random"
az group create --name $group --location $location

## obtain subscription id and signed in user details
$subid = az account show --query id --output tsv
$signedinuserid = az ad signed-in-user show --query id -o tsv

## create Linux VM
Write-Host -ForegroundColor Green "##########################################"
Write-Host -ForegroundColor Green "# Creating Linux VM #"
Write-Host -ForegroundColor Green "##########################################"
az vm create -g $group -n ptlinuxvm --image Ubuntu2204 --admin-username azureuser --admin-password $password --public-ip-address-dns-name $vmfqdn --size Standard_B2als_v2

az vm open-port --port 22 -g $group -n ptlinuxvm

$vmfqdnoutput = az vm show -g $group -n ptlinuxvm -d --query fqdns -o tsv

## create webapp with owner permissions
Write-Host -ForegroundColor Green "######################################"
Write-Host -ForegroundColor Green "# Creating WebApp #"
Write-Host -ForegroundColor Green "######################################"
az appservice plan create -n $webappname -g $group --sku S1
az webapp create -n $webappname -g $group --plan $webappname
az webapp deployment source config -n $webappname -g $group --repo-url $gitrepo --branch master --manual-integration
az webapp identity assign -n $webappname -g $group --role Owner --scope /subscriptions/$subid

## Create key vault
Write-Host -ForegroundColor Green "######################################"
Write-Host -ForegroundColor Green "# Creating Key Vault #"
Write-Host -ForegroundColor Green "######################################"
az keyvault create -n $keyvaultname -g $group --location $location --enable-rbac-authorization false

az keyvault secret set --vault-name $keyvaultname --name "twitter-api-key" --value "LB7BsQCtG57xYkQG" --description "Twitter API Key Used By ACI" 
az keyvault secret set --vault-name $keyvaultname --name "SQLAdminPassword" --value "4zVDknE3TyMxxW2J"
az keyvault secret set --vault-name $keyvaultname --name "db-encrption-key" --value "Pnfcc4F29XKNM5QB" --description "Database Encryption Key"
az keyvault key create --vault-name $keyvaultname --name "disk-encryption-key" --protection software

## Create storage
Write-Host -ForegroundColor Green "########################################"
Write-Host -ForegroundColor Green "# Creating Storage Account #"
Write-Host -ForegroundColor Green "########################################"
az storage account create --name $storagename -g $group --location $location --sku Standard_LRS

# Fetch the storage account key immediately to perform reliable data-plane operations
$key = az storage account keys list -g $group -n $storagename --query [0].value -o tsv

# Create container using account key to avoid Entra ID role assignment delays
az storage container create --account-name $storagename --name data --account-key $key

# Retrieve external payload
Invoke-WebRequest https://raw.githubusercontent.com/davidokeyode/azure-offensive/master/sensitive_customer_private_information.csv -OutFile sensitive_customer_private_information.csv 

# Assign role for Entra ID access testing later
az role assignment create --role "Storage Blob Data Contributor" --assignee $signedinuserid --scope "/subscriptions/$subid/resourceGroups/$group/providers/Microsoft.Storage/storageAccounts/$storagename"

# Upload blob using account key for instantaneous transfer
az storage blob upload --account-name $storagename --account-key $key --container-name data --file sensitive_customer_private_information.csv --name sensitive_customer_private_information.csv

## Create Azure SQL
Write-Host -ForegroundColor Green "######################################"
Write-Host -ForegroundColor Green "# Creating SQL Database #"
Write-Host -ForegroundColor Green "######################################"
az sql server create -l southeastasia -g $group -n $sqlsrvname -u sqladminuser -p 4zVDknE3TyMxxW2J

az sql db create -g $group -s $sqlsrvname -n advworksDB --sample-name AdventureWorksLT --edition GeneralPurpose --family Gen5 --capacity 2 --zone-redundant false --compute-model Serverless

az sql server firewall-rule create -g $group -s $sqlsrvname -n "corp-app-rule" --start-ip-address 16.17.18.19 --end-ip-address 16.17.18.19

# Get connection string for the database
$connstring = az sql db show-connection-string --name advworksDB --server $sqlsrvname --client ado.net --output tsv
$connstring = $connstring -replace "<username>", "sqladminuser"
$connstring = $connstring -replace "<password>", "4zVDknE3TyMxxW2J"

az webapp config appsettings set --name $webappname -g $group --settings "SQLSRV_CONNSTR=$connstring" 

## Create automation account
az deployment group create --name TemplateDeployment --resource-group $group --template-uri "https://raw.githubusercontent.com/PacktPublishing/Penetration-Testing-Azure-for-Ethical-Hackers/main/chapter-6/resources/automationacct.json"

## Create automation account credential
$automationuser = "automation-cred-user"
$automationpassword = ConvertTo-SecureString "SuperS3cretP@ssW0rd!" -AsPlainText -Force
$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $automationuser, $automationpassword
New-AzAutomationCredential -AutomationAccountName "automation-acct" -Name "AutomationCredential" -ResourceGroupName $group -Value $Credential

## Script Output
Start-Transcript -Path contributor-iaas-scenario-output.txt
Write-Host -ForegroundColor Green "#################################"
Write-Host -ForegroundColor Green "# Script Output #"
Write-Host -ForegroundColor Green "#################################"
Write-Host -ForegroundColor Green "Azure Contributor Admin User:" $user
Write-Host -ForegroundColor Green "Azure Contributor Admin User Password:" $password
Write-Host -ForegroundColor Green " "
Write-Host -ForegroundColor Green "Linux VM FQDN:" $vmfqdnoutput
Write-Host -ForegroundColor Green "Linux VM Password:" $password
Write-Host -ForegroundColor Green " "
Stop-Transcript
$endtime = Get-Date
Write-Host -ForegroundColor Green "Deployment Ended $endtime"