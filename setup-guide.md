# Apollo DTS — Setup Guide

**Service:** Apollo Document Transfer Service  
**Applies to:** First-time provisioning in a new environment (dev, uat, prod)

---

## Overview

This guide walks through provisioning DTS from scratch. Complete each numbered section in order before moving to the next.

**What the Bicep IaC deploys automatically:**

| Resource | Name pattern |
|---|---|
| App Service Plan | `asp-{loc}-dts-{env}` |
| Logic App Standard | `logic-{loc}-dts-{env}` |
| Config storage account | `sta{loc}dtsconfig{env}` |
| Data storage account | `sta{loc}dtsdata{env}` (blob containers + all 10 Azure Tables) |
| Service Bus discovery + delivery + notification topics and subscriptions | in `rg-uks-integrationplatform-{env}` |
| Diagnostic settings | Logic App logs → shared Log Analytics workspace |

> `{loc}` = `uks` for UK South, `ukw` for UK West. `{env}` = `dev`, `uat`, or `prod`.

**What is provisioned manually (outside this pipeline):**

| Task | Owner |
|---|---|
| VNet, subnets, NSGs, private endpoints | Infrastructure team |
| RBAC role assignments for the Logic App MI | App Support / Infrastructure team — notify once assigned |
| Azure DevOps setup (step 0) | You — one-time |
| Resource groups | You |
| Key Vault secrets (step 2) | You |
| SharePoint managed API connection (step 5) | You |
| Azure Table Storage seed data (step 7) | You |
| Logic App workflow deployment (step 4) | You / CD pipeline |

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Azure subscription | `Contributor` on `rg-uks-dts-{env}` |
| Shared integration platform | `rg-uks-integrationplatform-{env}` must already exist and contain: `kv-uks-integration-{env}`, `sbns-uks-integrationplatform-{env}`, `apim-uks-integrationplatform-{env}`, `appi-uks-integrationplatform-{env}` |
| KV write access | Your identity needs `Key Vault Secrets Officer` on `kv-uks-integration-{env}` to populate secrets before the first deploy |
| Service Bus tier | Standard or Premium — Basic does not support topics |
| Azure CLI | `az` ≥ 2.50; run `az account set --subscription {id}` before starting |
| Git Bash / WSL | Required if using the shell commands in step 7; PowerShell equivalents exist but are not shown |

---

## 0 — Azure DevOps CI/CD setup (one-time)

Complete this section once when first creating the project. Steps 1–9 assume the CI/CD pipelines are already registered and service connections are in place.

### 0.1 — Repository and branches

Create the ADO repository (or import from GitHub/local) in your Azure DevOps project. Two long-lived branches are required:

| Branch | Purpose |
|---|---|
| `develop` | Feature integration and dev deployments — default branch |
| `main` | Production-grade code; source of truth for UAT and prod deployments |

**Recommended branch policies for both `develop` and `main`:**

- Require a pull request; disable direct pushes
- Minimum 1 reviewer (`main`: minimum 2)
- Require linked work items (optional but recommended)
- Check for comment resolution before completing
- Automatically include the team as reviewers

> The CI pipelines (`ci-app.yml`, `ci-iac-bicep.yml`) are configured to run on PRs targeting `develop` and `main`, validating every change before merge.

---

### 0.2 — Workload Identity Federation app registrations

Create **6 app registrations** in Microsoft Entra ID. These are the identities that ADO pipelines will use to authenticate to Azure — no client secrets are needed.

**Naming convention:**

| Purpose | App registration name |
|---|---|
| IaC deploy — dev | `DevOps-DTS-CoreTech-IaC-Dev` |
| IaC deploy — UAT | `DevOps-DTS-CoreTech-IaC-UAT` |
| IaC deploy — prod | `DevOps-DTS-CoreTech-IaC-Prod` |
| App (workflow) deploy — dev | `DevOps-DTS-LogicApp-CodeRelease-Dev` |
| App (workflow) deploy — UAT | `DevOps-DTS-LogicApp-CodeRelease-UAT` |
| App (workflow) deploy — prod | `DevOps-DTS-LogicApp-CodeRelease-Prod` |

**For each app registration, add a federated credential:**

1. Azure Portal → Microsoft Entra ID → App registrations → {app reg} → **Certificates & secrets** → **Federated credentials** → **Add credential**.
2. Choose **Azure DevOps** as the scenario, or choose **Other issuer** and set:
   - **Issuer:** `https://vstoken.dev.azure.com/{your-ado-org}`
   - **Subject identifier:** `sc://{your-ado-org}/{your-ado-project}/{service-connection-name}`
   - **Name:** any descriptive label

   The service connection names to use in the subject are:
   ```
   sc://{org}/{project}/DevOps-DTS-CoreTech-IaC-Dev
   sc://{org}/{project}/DevOps-DTS-CoreTech-IaC-UAT
   sc://{org}/{project}/DevOps-DTS-CoreTech-IaC-Prod
   sc://{org}/{project}/DevOps-DTS-LogicApp-CodeRelease-Dev
   sc://{org}/{project}/DevOps-DTS-LogicApp-CodeRelease-UAT
   sc://{org}/{project}/DevOps-DTS-LogicApp-CodeRelease-Prod
   ```
3. Note the **Application (client) ID** and **Directory (tenant) ID** for each — needed when creating service connections (step 0.4).

---

### 0.3 — Azure role assignments for the WIF identities

Assign the following roles to each app registration's **service principal** (not the app reg itself — the enterprise application object):

**IaC service principals** (`DevOps-DTS-CoreTech-IaC-{Dev/UAT/Prod}`)

| Scope | Role | Reason |
|---|---|---|
| Subscription | **Reader** | ADO validates every service connection by calling `GET /subscriptions/{id}` — without this the pipeline fails with `AuthorizationFailed: subscriptions/read` before any deployment step runs |
| `rg-uks-dts-{env}` | **Contributor** | Deploys the Logic App, App Service Plan, config and data storage accounts |
| `rg-uks-integrationplatform-{env}` | **Contributor** | Cross-RG `serviceBusResources` module creates Service Bus topics/subscriptions; `alertRules` module deploys alert rules |

> RBAC role assignments for the Logic App MI (Storage Blob/Table Contributor, Service Bus Data roles, KV Secrets User) are **not** deployed by this pipeline — they are assigned manually by the infrastructure/app-support team after provisioning. Notify them of the `logicAppPrincipalId` output from the IaC deployment (step 3).

**CodeRelease service principals** (`DevOps-DTS-LogicApp-CodeRelease-{Dev/UAT/Prod}`)

| Scope | Role | Reason |
|---|---|---|
| Subscription | **Reader** | Same ADO service connection validation requirement as above |
| `rg-uks-dts-{env}` | **Contributor** | Zip-deploys workflow artifacts to the Logic App Standard resource |

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Example: full role assignments for the IaC-Dev SP
SP_OBJECT_ID=$(az ad sp show --id {DevOps-DTS-CoreTech-IaC-Dev-client-id} --query id -o tsv)

# Reader on the subscription — required for ADO service connection validation
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role Reader \
  --scope /subscriptions/$SUBSCRIPTION_ID

# Contributor on the DTS resource group
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role Contributor \
  --scope $(az group show --name rg-uks-dts-dev --query id -o tsv)

# Contributor on the shared integration RG (for Service Bus topics + alert rules)
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role Contributor \
  --scope $(az group show --name rg-uks-integrationplatform-dev --query id -o tsv)
```

Repeat for each of the 6 SPs, adding the subscription-scope `Reader` assignment to all of them and the environment-appropriate RG roles for each.

---

### 0.4 — Service connections in Azure DevOps

Create **6 service connections** in the ADO project — one per app registration. Use Workload Identity Federation (no secrets stored in ADO).

**ADO portal:** Project settings → Service connections → **New service connection** → Azure Resource Manager → **Workload Identity Federation (manual)**.

Fill in:
- **Subscription ID** — the Azure subscription ID for the target environment
- **Subscription name** — display name (e.g. `DTS Dev`)
- **Service Principal (client) ID** — the app reg client ID from step 0.2
- **Tenant ID** — your Entra tenant ID

Use exactly these service connection names (they are hardcoded in the YAML pipelines). Each service connection name matches its app registration name:

| Service connection / App registration | Environment |
|---|---|
| `DevOps-DTS-CoreTech-IaC-Dev` | dev |
| `DevOps-DTS-CoreTech-IaC-UAT` | uat |
| `DevOps-DTS-CoreTech-IaC-Prod` | prod |
| `DevOps-DTS-LogicApp-CodeRelease-Dev` | dev |
| `DevOps-DTS-LogicApp-CodeRelease-UAT` | uat |
| `DevOps-DTS-LogicApp-CodeRelease-Prod` | prod |

After saving each connection, verify it with **Verify connection** in the portal.

> **Agent pool access:** grant each service connection permission to the `Default` self-hosted pool (or your named pool), otherwise the pipeline will be blocked at queue time.

---

### 0.5 — Library variable groups

Create **3 variable groups** in the ADO project (Pipelines → Library → + Variable group). Each group is referenced by both the IaC and app deployment pipelines for that environment.

| Variable group name | Variable | Value |
|---|---|---|
| `dts-logicapp-dev-vargrp` | `LOGIC_APP_NAME` | `logic-uks-dts-dev` |
| | `RESOURCE_GROUP` | `rg-uks-dts-dev` |
| `dts-logicapp-uat-vargrp` | `LOGIC_APP_NAME` | `logic-uks-dts-uat` |
| | `RESOURCE_GROUP` | `rg-uks-dts-uat` |
| `dts-logicapp-prod-vargrp` | `LOGIC_APP_NAME` | `logic-uks-dts-prod` |
| | `RESOURCE_GROUP` | `rg-uks-dts-prod` |

Grant each pipeline permission to access its variable group when prompted on the first run, or pre-authorise via **Pipeline permissions** on each group.

---

### 0.6 — Environments and approval gates

Create **3 environments** in ADO (Pipelines → Environments → **New environment**). The CD pipelines reference these environments by name to enforce approval gates and audit trails.

| Environment | Approval policy |
|---|---|
| `dts-dev` | No approval required — deploys automatically when CI passes on `develop` |
| `dts-uat` | 1 approver required |
| `dts-prod` | Minimum 2 approvers; requester cannot self-approve; timeout 4 hours |

**Portal:** Pipelines → Environments → {environment name} → **Approvals and checks** → **+ Add** → **Approvals**.

For `prod` only, also add a **Business hours** check (Mon–Thu 09:00–16:00 UTC) as a second safeguard alongside the deployment window enforcement already built into the pipeline script.

---

### 0.7 — Register the four pipeline definitions

Import each YAML file from the `pipelines/` folder as an ADO pipeline definition (Pipelines → **New pipeline** → Azure Repos Git → select this repo → **Existing Azure Pipelines YAML file**).

| Pipeline name | YAML file | Trigger |
|---|---|---|
| `CI - IaC - Bicep (DTS)` | `pipelines/ci-iac-bicep.yml` | Push to `develop`; PRs to `develop`/`main` (path: `infra/bicep/**`) |
| `CD - IaC - Bicep (DTS)` | `pipelines/cd-iac-bicep.yml` | Automatically triggered when `CI - IaC - Bicep (DTS)` passes on `develop` or `main` |
| `CI - App - DTS Logic App Workflows` | `pipelines/ci-app.yml` | Push to `develop`; PRs to `develop`/`main` (path: `workflows/**`, `schemas/**`, `host.json`, `connections.json`, `parameters/**`) |
| `CD - App - DTS Logic App Workflows` | `pipelines/cd-app.yml` | Automatically triggered when `CI - App - DTS Logic App Workflows` passes on `develop` or `main` |

> Use exactly the pipeline names shown above — the CD pipelines reference the CI pipeline by the `source:` name declared in `resources.pipelines`. A name mismatch will prevent the CD trigger from firing.

**Recommended queue order for the first run:**

1. Run `CD - IaC - Bicep (DTS)` first so the Logic App resource exists before the app pipeline tries to deploy to it.
2. Only after IaC completes, run `CD - App - DTS Logic App Workflows`.

---

## 1 — Create resource groups

```bash
# UK South — used for dev, uat, and prod primary
az group create --name rg-uks-dts-{env} --location uksouth

# UK West — prod DR only
az group create --name rg-ukw-dts-prod --location ukwest
```

The shared integration platform RG (`rg-uks-integrationplatform-{env}`) must already exist before you proceed. The VNet and networking resources in the DTS RG are created by the infrastructure team — coordinate with them before running the IaC pipeline so VNet integration can be applied post-deploy.

---

## 2 — Populate Key Vault secrets

The Logic App app settings reference these secrets from `kv-uks-integration-{env}` as Key Vault references. They must exist before the Bicep deploy so the Logic App can start without errors.

```bash
KV=kv-uks-integration-{env}

# App Insights connection string
# Source: Azure Portal → appi-uks-integrationplatform-{env} → Properties → Connection String
# NOTE: The instrumentation key is NOT stored as a separate secret — only the connection
# string is used, per Microsoft's current recommendation.
az keyvault secret set --vault-name $KV \
  --name appinsights-connection-string \
  --value "InstrumentationKey={key};IngestionEndpoint=https://uksouth-1.in.applicationinsights.azure.com/"

# APIM subscription key for the DTS product
# Source: Azure Portal → apim-uks-integrationplatform-{env} → Subscriptions → DTS → Show primary key
az keyvault secret set --vault-name $KV \
  --name apim-subscription-key \
  --value "{apim-subscription-key}"

# Azure Communication Services email endpoint
# Source: Azure Portal → ACS resource → Keys and Endpoint → Endpoint
az keyvault secret set --vault-name $KV \
  --name acs-email-endpoint \
  --value "https://{acs-resource-name}.communication.azure.com"
```

---

## 3 — Deploy infrastructure (Bicep)

Run from the repository root. The deployment provisions the Logic App, both storage accounts, and the Service Bus topics. The Service Bus module deploys into the shared integration platform RG via a cross-RG module scope.

```bash
# Dev
az deployment group create \
  --resource-group rg-uks-dts-dev \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/dev.parameters.bicepparam \
  --name dts-infra-$(date +%Y%m%d%H%M)

# UAT
az deployment group create \
  --resource-group rg-uks-dts-uat \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/uat.parameters.bicepparam \
  --name dts-infra-$(date +%Y%m%d%H%M)

# Prod — UK South primary
az deployment group create \
  --resource-group rg-uks-dts-prod \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/prod.parameters.bicepparam \
  --name dts-infra-$(date +%Y%m%d%H%M)
```

Deployment takes 3–6 minutes. After it completes, verify the outputs:

```bash
az deployment group show \
  --resource-group rg-uks-dts-{env} \
  --name {deployment-name} \
  --query properties.outputs
```

Expected outputs: `logicAppName`, `logicAppPrincipalId`, `dataStorageAccountName`, `configStorageAccountName`, `sharedKeyVaultUri`.

> **Note:** The Logic App will report errors in Application Insights until workflows are deployed (step 4) and the SharePoint connection URL is populated (step 5). This is expected. Steps 3.1 and 3.2 below must be completed before workflows can run successfully.

---

### 3.1 — Manual: RBAC role assignments (app-support / infrastructure team)

> **Performed by:** app-support or infrastructure team, not the CI/CD pipeline.
> **Trigger:** raise a request with the team after the IaC deployment completes. Provide them with the `logicAppPrincipalId` from the deployment outputs.

The Logic App runs as a System-Assigned Managed Identity. The following roles must be assigned to that identity before workflows can operate:

| Resource | Role | Purpose |
|---|---|---|
| `sta{loc}dtsconfig{env}` (config storage) | Storage Blob Data Contributor | Logic App runtime blobs (state, artifact cache) |
| `sta{loc}dtsconfig{env}` (config storage) | Storage Queue Data Contributor | Logic App internal queue triggers |
| `sta{loc}dtsconfig{env}` (config storage) | Storage Table Data Contributor | Logic App internal state tables |
| `sta{loc}dtsconfig{env}` (config storage) | Storage File Data Privileged Contributor | Logic App content file share (`WEBSITE_CONTENTSHARE`) |
| `sta{loc}dtsdata{env}` (data storage) | Storage Blob Data Contributor | Read/write staging, quarantine, and records blob containers |
| `sta{loc}dtsdata{env}` (data storage) | Storage Table Data Contributor | Read/write all DTS Azure Tables |
| `sbns-uks-integrationplatform-{env}` (Service Bus namespace) | Azure Service Bus Data Sender | Publish delivery and notification messages |
| `sbns-uks-integrationplatform-{env}` (Service Bus namespace) | Azure Service Bus Data Receiver | Consume delivery request subscriptions |
| `kv-uks-integration-{env}` (Key Vault) | Key Vault Secrets User | Read APIM key, App Insights connection string, ACS endpoint at runtime |

> The four config-storage roles are required because the Logic App authenticates to its backing storage via Managed Identity (no connection string). The Logic App will start in a failed state after deployment and recover automatically once all roles are assigned.

```bash
# Retrieve the Logic App MI object ID from the deployment output
PRINCIPAL_ID=$(az deployment group show \
  --resource-group rg-uks-dts-{env} \
  --name {deployment-name} \
  --query properties.outputs.logicAppPrincipalId.value -o tsv)

CONFIG_STORAGE=sta{loc}dtsconfig{env}
DATA_STORAGE=sta{loc}dtsdata{env}
SBUS_NS=sbns-uks-integrationplatform-{env}
KEY_VAULT=kv-uks-integration-{env}
DTS_RG=rg-uks-dts-{env}
SHARED_RG=rg-uks-integrationplatform-{env}

CONFIG_SCOPE=$(az storage account show --name $CONFIG_STORAGE --resource-group $DTS_RG --query id -o tsv)
DATA_SCOPE=$(az storage account show  --name $DATA_STORAGE  --resource-group $DTS_RG --query id -o tsv)
SBUS_SCOPE=$(az servicebus namespace show --name $SBUS_NS --resource-group $SHARED_RG --query id -o tsv)
KV_SCOPE=$(az keyvault show --name $KEY_VAULT --resource-group $SHARED_RG --query id -o tsv)

# Config storage — four roles for MI-based backing storage auth
az role assignment create --assignee $PRINCIPAL_ID --role "Storage Blob Data Contributor"          --scope $CONFIG_SCOPE
az role assignment create --assignee $PRINCIPAL_ID --role "Storage Queue Data Contributor"         --scope $CONFIG_SCOPE
az role assignment create --assignee $PRINCIPAL_ID --role "Storage Table Data Contributor"         --scope $CONFIG_SCOPE
az role assignment create --assignee $PRINCIPAL_ID --role "Storage File Data Privileged Contributor" --scope $CONFIG_SCOPE

# Data storage — blob and table access for DTS workflows
az role assignment create --assignee $PRINCIPAL_ID --role "Storage Blob Data Contributor"  --scope $DATA_SCOPE
az role assignment create --assignee $PRINCIPAL_ID --role "Storage Table Data Contributor" --scope $DATA_SCOPE

# Service Bus
az role assignment create --assignee $PRINCIPAL_ID --role "Azure Service Bus Data Sender"   --scope $SBUS_SCOPE
az role assignment create --assignee $PRINCIPAL_ID --role "Azure Service Bus Data Receiver" --scope $SBUS_SCOPE

# Key Vault
az role assignment create --assignee $PRINCIPAL_ID --role "Key Vault Secrets User" --scope $KV_SCOPE
```

---

### 3.2 — Manual: VNet and network configuration (infrastructure team)

> **Performed by:** infrastructure team, not the CI/CD pipeline.
> **Trigger:** raise a request after the IaC deployment completes. Provide the resource names below.

The Logic App and storage are deployed without network restrictions. The infrastructure team applies the following after provisioning:

**VNet and subnets** (create in `rg-uks-dts-{env}`)

| Resource | Name pattern | Notes |
|---|---|---|
| VNet | `vnet-{loc}-dts-{env}` | Address space: agree with infra team to avoid overlap with hub/spoke |
| Logic App integration subnet | `snet-{loc}-dts-logicapp-{env}` | Min `/28`, recommend `/26`; delegation: `Microsoft.Web/serverFarms`; service endpoints: `Microsoft.Storage`, `Microsoft.ServiceBus`, `Microsoft.KeyVault` |
| Storage private endpoint subnet | `snet-{loc}-dts-storage-{env}` | `/27` sufficient; `privateEndpointNetworkPolicies: Disabled` |

**Logic App VNet integration**

After the VNet and Logic App integration subnet exist, enable VNet integration on the Logic App:

```bash
az webapp vnet-integration add \
  --name logic-{loc}-dts-{env} \
  --resource-group rg-uks-dts-{env} \
  --vnet vnet-{loc}-dts-{env} \
  --subnet snet-{loc}-dts-logicapp-{env}
```

**Private endpoints for storage accounts**

Four endpoints required on the config storage (`sta{loc}dtsconfig{env}`): `blob`, `table`, `queue`, `file`.  
Two endpoints required on the data storage (`sta{loc}dtsdata{env}`): `blob`, `table`.  
All endpoints should target the storage private endpoint subnet and register with the corresponding private DNS zones (`privatelink.blob.core.windows.net`, etc.).

**Storage network ACL lockdown** (after private endpoints are active)

```bash
# Lock down config storage
az storage account update \
  --name sta{loc}dtsconfig{env} \
  --resource-group rg-uks-dts-{env} \
  --default-action Deny \
  --bypass AzureServices

# Lock down data storage
az storage account update \
  --name sta{loc}dtsdata{env} \
  --resource-group rg-uks-dts-{env} \
  --default-action Deny \
  --bypass AzureServices
```

---

## 4 — Deploy Logic App workflows

Publish the `workflows/` directory to the Logic App.

### Via VS Code (recommended for dev/first deploy)

1. Open the `workflows/` folder in VS Code with the Azure Logic Apps (Standard) extension installed.
2. Open the Azure extension sidebar → Logic Apps → your subscription.
3. Right-click `logic-uks-dts-{env}` → **Deploy to Logic App**.
4. Select the `workflows/` folder when prompted. Confirm the deployment warning.

### Via Azure CLI (CI/CD or scripted)

```bash
# From the repository root — zip the workflows directory (exclude local.settings.json)
(cd workflows && zip -r ../dts-workflows.zip . --exclude "local.settings.json")

az logicapp deployment source config-zip \
  --name logic-uks-dts-{env} \
  --resource-group rg-uks-dts-{env} \
  --src dts-workflows.zip

rm dts-workflows.zip
```

After deployment: Azure Portal → Logic App → Workflows — all DTS workflows should be listed.

---

## 5 — Create the SharePoint managed connection

The `SHAREPOINT_CONNECTION_RUNTIME_URL` app setting is blank after the first deploy. Any workflow step that calls SharePoint will fail until this is populated.

**Steps:**

1. Azure Portal → `logic-uks-dts-{env}` → **Workflows** → open `wf-activity-sharepoint-upload`.
2. In the designer, the SharePoint action will show a connection error. Click the action → **Change connection** → **Add new**.
3. Authenticate as the service account or select Managed Identity as appropriate, then save.
4. Navigate to the newly created connection resource (`azureblob` API connection type for SP) → **JSON view** → find `properties.runtimeUrls[0]`.
5. Redeploy with the URL populated:

```bash
az deployment group create \
  --resource-group rg-uks-dts-{env} \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/{env}.parameters.bicepparam \
              sharePointConnectionRuntimeUrl="https://uksouth.logic.azure.com:443/apim/sharepointonline/{connection-id}" \
  --name dts-infra-sp-$(date +%Y%m%d%H%M)
```

Alternatively, commit the URL into the `*.parameters.bicepparam` file and redeploy via the normal pipeline.

> Managed API connections are not replicated across resource groups or regions. Repeat this step for each separate environment and for the UK West DR deployment.

---

## 6 — Grant SharePoint Sites.Selected

The Logic App MI needs `Sites.Selected` write access to each target SharePoint site. This cannot be granted via the Azure Portal — it requires PnP PowerShell.

See **SharePoint Sites.Selected Grant** in [runbook.md](runbook.md) for the full procedure. Complete this before running any workflow that delivers to SharePoint.

---

## 7 — Seed Azure Table Storage

The Azure Tables are created automatically by the Bicep deployment. You need to insert the configuration rows that tell the scheduler and orchestrators what to run, when, and where to deliver.

The following seed data reflects a single Whitespace workload delivering to a SharePoint destination. Adjust for your environment.

> **Type safety:** `az storage entity insert` stores unquoted `true`/`false` values as `Edm.Boolean` and ISO datetime strings as `Edm.String` by default. Prefer using **Azure Storage Explorer** (portal blade or standalone tool) for seeding, as it allows you to set each property's EDM type explicitly. The CLI commands below use `Edm.Boolean` annotation syntax where needed.

```bash
DATA_ACCOUNT=stauksdtsdatadev  # stauksdtsdataprod / staukwdtsdataprod for uat/prod
# Ensure your identity has Storage Table Data Contributor on $DATA_ACCOUNT
az role assignment list \
  --scope $(az storage account show \
    --name $DATA_ACCOUNT \
    --resource-group rg-uks-dts-dev \
    --query id -o tsv) \
  --query "[?principalName==\`$(az account show --query user.name -o tsv)\`].roleDefinitionName"
```

### 7.1 DtsPartners

```bash
az storage entity insert \
  --account-name $DATA_ACCOUNT \
  --table-name DtsPartners \
  --if-exists replace \
  --auth-mode login \
  --entity \
    PartitionKey=WHITESPACE \
    RowKey=WHITESPACE \
    PartnerId=WHITESPACE \
    PartnerName="Whitespace Markets" \
    IsEnabled=true \
    ValidFromUtc="2026-01-01T00:00:00.0000000Z"
```

### 7.2 DtsWorkloads

```bash
az storage entity insert \
  --account-name $DATA_ACCOUNT \
  --table-name DtsWorkloads \
  --if-exists replace \
  --auth-mode login \
  --entity \
    PartitionKey=WL-WHITESPACE-RISKDOCS \
    RowKey=WL-WHITESPACE-RISKDOCS \
    WorkloadId=WL-WHITESPACE-RISKDOCS \
    WorkloadName="Whitespace Risk Documents" \
    PartnerId=WHITESPACE \
    IsEnabled=true \
    IsPaused=false \
    ExtDocumentTypesCsv="application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document" \
    ExtDocStatusesCsv="Signed,Endorsement" \
    MaxDataClassification=OFFICIAL
```

| Field | Description |
|---|---|
| `ExtDocStatusesCsv` | Comma-separated document statuses from the Whitespace API that are eligible for download. Documents with any other status are skipped in discovery. Set to `""` (empty) to accept all statuses. |
| `ExtDocumentTypesCsv` | MIME types accepted; documents with other content types are rejected. |

### 7.3 DtsWorkloadSchedules

The DaysOfWeekMask is a bitmask: Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64. Monday–Friday = **31**.

```bash
# Generate a GUID for the ScheduleId RowKey
SCHEDULE_ID=$(python3 -c "import uuid; print(uuid.uuid4())")

az storage entity insert \
  --account-name $DATA_ACCOUNT \
  --table-name DtsWorkloadSchedules \
  --if-exists replace \
  --auth-mode login \
  --entity \
    PartitionKey=WL-WHITESPACE-RISKDOCS \
    RowKey=$SCHEDULE_ID \
    WorkloadId=WL-WHITESPACE-RISKDOCS \
    DaysOfWeekMask=31 \
    IntervalHours=1 \
    SpecificTimesCsv="" \
    TimeZoneId="GMT Standard Time" \
    WindowStartTime="07:00" \
    WindowEndTime="19:00" \
    EffectiveFromUtc="2026-01-01T00:00:00.0000000Z" \
    EffectiveToUtc=""
```

`IntervalHours=1` runs once per hour within the window. To run at specific times instead, set `IntervalHours=""` and populate `SpecificTimesCsv` (e.g., `"08:00,12:00,16:00"`).

### 7.4 DtsWorkloadRuntimeState (initial state)

```bash
az storage entity insert \
  --account-name $DATA_ACCOUNT \
  --table-name DtsWorkloadRuntimeState \
  --if-exists replace \
  --auth-mode login \
  --entity \
    PartitionKey=WL-WHITESPACE-RISKDOCS \
    RowKey=WL-WHITESPACE-RISKDOCS \
    WorkloadId=WL-WHITESPACE-RISKDOCS \
    LastStatus=Completed \
    LastRunStartedUtc="2000-01-01T00:00:00.0000000Z" \
    LastSuccessfulRunUtc="2000-01-01T00:00:00.0000000Z" \
    CommittedWatermarkUtc=""
```

> `CommittedWatermarkUtc` is empty on first bootstrap. The discovery orchestrator will start from the beginning of available partner data. To limit the initial discovery window, set this to a specific ISO 8601 datetime string (e.g., `"2026-10-01T00:00:00.0000000Z"`) so the first run only retrieves documents updated after that point.

### 7.5 DtsWorkloadDocRouting

```bash
ROUTING_ID=$(python3 -c "import uuid; print(uuid.uuid4())")

az storage entity insert \
  --account-name $DATA_ACCOUNT \
  --table-name DtsWorkloadDocRouting \
  --if-exists replace \
  --auth-mode login \
  --entity \
    PartitionKey=WL-WHITESPACE-RISKDOCS \
    RowKey=$ROUTING_ID \
    WorkloadId=WL-WHITESPACE-RISKDOCS \
    RoutingId=$ROUTING_ID \
    DestinationConfigCode=SP-RISKDOCS-DEV \
    DestinationType=SharePoint \
    "DestinationPath=https://{tenant}.sharepoint.com/sites/{site}/Shared Documents/RiskDocs" \
    IsEnabled=true \
    CredentialKeyVaultRef=""
```

| `DestinationType` | `CredentialKeyVaultRef` |
|---|---|
| `SharePoint` | Leave empty — MI-based `Sites.Selected` auth, no secret needed |
| `AzureFiles` | Leave empty — MI `Storage File Data Privileged Contributor` |
| `AzureBlob` | Leave empty — MI `Storage Blob Data Contributor` |
| `Sftp` | Secret name in `kv-uks-integration-{env}` holding the SSH private key (PEM) |
| `NetworkShare` | Secret name in `kv-uks-integration-{env}` holding `{"domain":"CORP","username":"svc_dts","password":"..."}` |

### 7.6 DtsNonWorkingDays (bank holidays)

Bank holidays are stored with `PartitionKey = "england-and-wales"` and `RowKey = "yyyy-MM-dd"`. Source dates from the UK Government bank holidays API and insert one row per holiday.

```bash
seed_bank_holiday() {
  az storage entity insert \
    --account-name $DATA_ACCOUNT \
    --table-name DtsNonWorkingDays \
    --if-exists replace \
    --auth-mode login \
    --entity \
      PartitionKey="england-and-wales" \
      RowKey="$1" \
      Date="$1" \
      Region="england-and-wales" \
      Name="$2"
}

# 2026 England and Wales bank holidays
seed_bank_holiday "2026-01-01" "New Year's Day"
seed_bank_holiday "2026-04-03" "Good Friday"
seed_bank_holiday "2026-04-06" "Easter Monday"
seed_bank_holiday "2026-05-04" "Early May bank holiday"
seed_bank_holiday "2026-05-25" "Spring bank holiday"
seed_bank_holiday "2026-08-31" "Summer bank holiday"
seed_bank_holiday "2026-12-25" "Christmas Day"
seed_bank_holiday "2026-12-28" "Boxing Day (substitute)"
```

Refresh this table annually. The scheduling workflow queries it on every timer tick to determine whether today is a non-working day for the configured region.

---

## 8 — Smoke test

After seeding, verify the system runs end-to-end with a manual HTTP trigger.

### 8.1 Get the trigger callback URL

Azure Portal → `logic-uks-dts-{env}` → **Workflows** → `wf-orchestrator-discovery` → **Overview** → **Get callback URL**. Copy the full URL including the SAS parameters.

### 8.2 POST a test discovery run

```bash
curl -s -X POST \
  "{callback-url-from-portal}" \
  -H "Content-Type: application/json" \
  -d '{
    "workloadId": "WL-WHITESPACE-RISKDOCS",
    "watermarkFromUtc": "2026-10-01T00:00:00Z",
    "watermarkToUtc": "2026-10-15T00:00:00Z",
    "requiresImmutableRecord": true,
    "extDocStatusesCsv": "Signed,Endorsement"
  }'
```

The trigger responds synchronously with a correlation ID. The workflow run continues asynchronously.

### 8.3 Verify results

| Check | Where to look |
|---|---|
| Workflow run completed | Logic App → Workflows → `wf-orchestrator-discovery` → Run history |
| Orchestration run record | `stauksdtsdatadev` → Storage → Tables → `DtsOrchestrationRuns` — row with `Status = Completed` |
| Documents discovered | `DtsDocuments` — rows with `Status = Discovered` or `Downloaded` |
| Staging blobs written | `stauksdtsdatadev` → Containers → `staging` |
| AppInsights telemetry | AppInsights → Logs → `customEvents` — filter `name == "DiscoveryCompleted"` |

If the Whitespace API is not accessible from dev, the FOREACH_Document loop will produce zero iterations and the run will complete with an empty result set. This is expected in a fresh environment without partner connectivity.

---

## 9 — Prod DR deployment (UK West)

After the UK South primary is healthy, deploy the DR replica.

```bash
az deployment group create \
  --resource-group rg-ukw-dts-prod \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/prod-ukw.parameters.bicepparam \
  --name dts-infra-dr-$(date +%Y%m%d%H%M)
```

The UK West deployment shares the UK South shared integration platform (KV, SB namespace, APIM, App Insights). It provisions its own storage accounts (`staukwdtsconfigprod`, `staukwdtsdataprod`) and Logic App (`logic-ukw-dts-prod`).

**Seed data**: Repeat all of step 7 targeting `DATA_ACCOUNT=staukwdtsdataprod` (the UK West data account).

**Workflow deploy**: Repeat step 4 targeting `logic-ukw-dts-prod` in `rg-ukw-dts-prod`.

**SharePoint connection**: Repeat step 5 for the UK West Logic App.

**Data synchronisation**: Table Storage and Blob containers are not automatically replicated between UK South and UK West. For DR readiness:

- Configure Azure Storage object replication on `stauksdtsdataprod` → `staukwdtsdataprod` for the `records` and `staging` containers (read-only replica).
- Table data replication requires a custom sync mechanism or periodic export/import. At minimum, the seed data (steps 7.1–7.6) must be manually applied to the UK West data account.

**Traffic failover**: Point incoming Service Bus triggers and HTTP invocations at `logic-ukw-dts-prod.azurewebsites.net` during a DR event. Update APIM backends or DNS accordingly.

---

## Appendix — Useful CLI commands

```bash
# Show Logic App state and identity
az logicapp show \
  --name logic-uks-dts-{env} \
  --resource-group rg-uks-dts-{env} \
  --query "{state:state, host:defaultHostName, principalId:identity.principalId}"

# List role assignments on the data storage account
az role assignment list \
  --scope $(az storage account show \
    --name stauksdtsdatadev \
    --resource-group rg-uks-dts-dev \
    --query id -o tsv) \
  --query "[].{principal:principalName, role:roleDefinitionName}" \
  --output table

# Verify KV secrets exist
az keyvault secret list \
  --vault-name kv-uks-integration-{env} \
  --query "[].{name:name, enabled:attributes.enabled}" \
  --output table

# Point-read a single Table entity
az storage entity show \
  --account-name stauksdtsdatadev \
  --table-name DtsWorkloads \
  --partition-key WL-WHITESPACE-RISKDOCS \
  --row-key WL-WHITESPACE-RISKDOCS \
  --auth-mode login

# List all entities in a table (small tables only)
az storage entity query \
  --account-name stauksdtsdatadev \
  --table-name DtsOrchestrationRuns \
  --filter "PartitionKey eq 'WL-WHITESPACE-RISKDOCS'" \
  --auth-mode login \
  --query "items[].{RowKey:RowKey, Status:Status, StartedAt:StartedAtUtc}"
```
