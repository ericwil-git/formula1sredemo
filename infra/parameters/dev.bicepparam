// =============================================================================
// dev.bicepparam — parameters for the dev deployment.
//
// Set these env vars before running `az deployment sub create`:
//
//   export SQL_SA_PWD="$(openssl rand -base64 18)Aa1!"
//   export VM_PWD="$(openssl rand -base64 18)Aa1!"
//   export FILEGEN_API_KEY="$(openssl rand -hex 24)"
//
// Data tier is now SQL Server 2022 Developer Edition installed on the
// Windows Server VM (see docs/techspec.md §3.1). No SQL MI, no Entra Directory
// Readers issue, no MCAPS deny policy fights.
// =============================================================================

using '../main.bicep'

param location = 'centralus'
param resourceGroupName = 'rg-f1demo-centeral'
param namePrefix = 'f1demo'

// Strong defaults; override via env vars in real runs.
param sqlServerSaPassword = readEnvironmentVariable('SQL_SA_PWD', 'F1Demo!ChangeMe2026')
param vmAdminUsername = 'f1demoadmin'
param vmAdminPassword = readEnvironmentVariable('VM_PWD', 'F1Demo!ChangeMe2026')
param fileGeneratorApiKey = readEnvironmentVariable('FILEGEN_API_KEY', 'change-me-please-use-a-random-32-char-key')

// Restrict RDP to your /32 in real demos. '*' = open to internet.
param rdpSourceAddressPrefix = '*'
