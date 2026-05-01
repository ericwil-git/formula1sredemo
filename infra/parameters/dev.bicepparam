// =============================================================================
// dev.bicepparam — parameters for the dev deployment.
//
// Set these env vars before running `az deployment sub create`:
//
//   export SQL_MI_PWD="$(openssl rand -base64 18)Aa1!"
//   export VM_PWD="$(openssl rand -base64 18)Aa1!"
//   export FILEGEN_API_KEY="$(openssl rand -hex 24)"
//   export AAD_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
//   export AAD_LOGIN="$(az ad signed-in-user show --query userPrincipalName -o tsv)"
//
// MCAPS deny policy AzureSQLMI_WithoutAzureADOnlyAuthentication_Deny enforces
// AAD-only auth on SQL MI. SQL_MI_PWD is still required by the ARM contract
// but cannot be used to log in.
// =============================================================================

using '../main.bicep'

param location = 'centralus'
param resourceGroupName = 'rg-f1demo-centeral'
param namePrefix = 'f1demo'

// Strong defaults — meet 4/4 complexity rules. Override via env vars in real runs.
param sqlMiAdminLogin = 'f1adm'
param sqlMiAdminPassword = readEnvironmentVariable('SQL_MI_PWD', 'F1Demo!ChangeMe2026')
param vmAdminUsername = 'f1demoadmin'
param vmAdminPassword = readEnvironmentVariable('VM_PWD', 'F1Demo!ChangeMe2026')
param fileGeneratorApiKey = readEnvironmentVariable('FILEGEN_API_KEY', 'change-me-please-use-a-random-32-char-key')

// Entra ID admin for SQL MI (required by AAD-only auth).
param aadAdminLogin = readEnvironmentVariable('AAD_LOGIN', '')
param aadAdminObjectId = readEnvironmentVariable('AAD_OBJECT_ID', '')
param aadAdminPrincipalType = 'User'

// Restrict RDP to your /32 in real demos. '*' = open to internet.
param rdpSourceAddressPrefix = '*'
