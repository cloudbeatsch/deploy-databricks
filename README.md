# Introduction 

## Solution Requirement
The aim of the solution is to provide a separate security context
between the data custodian, whose data is residing in Azure Data Lake, and the data modeller / consumer, which uses Azure Databricks as the main data processing platform. This is achieved by deploying the two parts of the solution into different AD Tenants and subscriptions while using an AD service principal to facilitate access.

## Solution Description
The following deploys a Proof-of-Concept showing the ability to mount an [Azure Data Lake Store](https://azure.microsoft.com/en-us/services/data-lake-store/) to an [Azure Databricks](https://azure.microsoft.com/en-au/services/databricks/) workspace across two Azure tenants. It incorporates the use of [Azure Key Vault](https://azure.microsoft.com/en-us/services/key-vault/) as the main storage of the AD Service Principal password during deployment. Furthermore, the solution demonstrates two ways of handling secrets within Azure Databricks: 
1. Credentials are stored in a config notebook in the user's Azure Databricks workspace
2. (Recommended) Credentials are stored in the [Azure Databricks' Secrets API (preview)](https://docs.azuredatabricks.net/user-guide/secrets/index.html)

# Architecture
![Architecture](/Images/architecture.JPG?raw=true "Architecture")

# Requirements
- [Azure cli 2.0](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
- [jq](https://stedolan.github.io/jq/)
- [Databricks cli](https://github.com/databricks/databricks-cli)

# Getting Started

Ensure you have logged in to azure cli by calling `az login`. You may need to login to multple accounts if the resources are spread across multiple tenants / subscriptions.

## Deploy full solution

1. Navigate to **Deploy > DBricksMultiTarget**
2. Inspect the following parameters files:
    - `deployAll.parameters.json` - parameter file containing destination subscriptions and resource groups
    - `DeployADL/azuredeploy.parameters.json` - parameters controlling the Azure Data Lake deployment
    - `DeployDbricks/azuredeploy.parameters.json` - parameters controlling the Azure Databricks deployment
3. Run `./deployAll.sh`
    - NOTE: When prompted, supply Databricks domain and personal access token from newly created workspace. See here for more details: https://docs.azuredatabricks.net/user-guide/dev-tools/databricks-cli.html#set-up-authentication

## Deploy individual components

Instead of deploying the entire solution in one go, different individuals may need deploy individual components of the solution separately - perhaps due to security reasons. The following outlines how to deploy individual components of the solution. 

Note that the following are simply the manual steps which is automated in the previous `deployAll.sh` script.


### A. Deploy Azure Databricks workspace and Azure KeyVault

The following will deploy an Azure Databricks workspace and Azure KeyVault in the specified resource group and location. It will also generate a random password to be used by the Service Principal and store this string as a secret in Azure KeyVault. 

1. Navigate to **Deploy > DBricksMultiTarget > DeployDbricks** 
2. Inspect and update the deployment parameters in the `azuredeploy.parameters.json` file. 
    - **Important:** Update `keyVaultUserId` value with the user's AD Object Id that will need to retrieve the password of the AD service principal account. Obtain a user's AD Object Id by running `az ad user show --upn <principal_name ei. johndoe@contoso.com> --query "objectId"`
3. Ensure azure cli is pointing to the correct subscription you want to deploy the resources to by running `az account show`. To switch accounts, use `az account set -s <subscription_id>`.
4. Run `./deploy.sh` and fill in the prompts. 
    - **Important:** Take note of the KeyVault name, KeyVault subscription id, and KeyVault secret name refering to the AD Service Principal password as this will be needed in the next step. This should be displayed as part of output of the deployment script.

### B. Deploy Azure Data Lake and create a service principal

The following will deploy Azure Data Lake into the specified resource group and location. It will also create an AD Service Account with a password retrieved from Azure KeyVault (see previous "Deploy Azure Databricks workspace and Azure KeyVault"), then grant rwx to the folder in Azure Data Lake as specified in the parameters file.

1. Navigate to **Deploy > DBricksMultiTarget > DeployADL**
2. Inspect and update the deployment parameters in the `azuredeploy.parameters.json` file. 
    - **Important:** Update following parameters to point to the appropriate KeyVault:
    - 
            "kvName": {"value": "KEY_VAULT_NAME"}, 
            "kvSubId": { "value": "KEY_VAULT_SUBSCRIPTION_ID" },
            "kvSpSecretName": { "value": "KEY_VAULT_SECRET_NAME" }
            
3. Ensure azure cli is pointing to the correct subscription you want to deploy the resources to by running `az account show`. To switch accounts, use `az account set -s <subscription_id>`.
4. Run `./deploy.sh` and fill in the prompts.

### C. Upload Databricks ADLMount-boostrapped notebooks into workspace
The following will upload Notebooks into the Azure Databricks workspace with the necessary scripts to mount Azure Data Lake to Azure Databricks. 
1. Configure Databricks CLI to point to the newly created Databricks workspace by running `databricks configure --token`. See here for more details: https://docs.azuredatabricks.net/user-guide/dev-tools/databricks-cli.html#set-up-authentication.
    - Note: There is currently an outstanding bug with Basic Authentication in the v0.6 of the Databricks CLI, so make sure you use Token Authentication instead.
2. Navigate to **Deploy > DbricksMultiTarget > DeployDbricks > cluster**
3. Run `./mountadl_confignb.sh` or `./mountadl_secret.sh`. The former uses the a config notebook to store the secrets while the latter makes use of the Azure Databricks Secrets API. When running either script, it will prompt you for the following:
    - Azure Data Lake account name
    - AD Service Principal name
    - AD Service Principal Client Id
    - AD Service Principal Tenant Id
    - KeyVault account name
    - Name of secret in KeyVault containing AD service principal password
    - Databricks region
    - *Optional*: Template folder path containing notebook templates

- You may also pass these inline like below:

        ./DeployDbricks/cluster/mountadl_secret.sh \
            $dlName \
            $spName \
            $spClientId \
            $spTenantId \
            $kvName \
            $kvSpSecretName \
            $dbricksLocation \
            $dbricksScope \
            $dbricksNotebookTemplates

- These scripts will upload the following notebooks to the specified Databricks workspace:
    - **config.py** - contains all configuration to mount ADL. Do not share this notebook! Only used by `confignb`.
    - **mountadl_<confignb/secret>_dbfs.py** - contains bootstap code to mount ADL via DBFS. See here for more info: https://docs.azuredatabricks.net/spark/latest/data-sources/azure/azure-datalake.html#mount-azure-data-lake-stores-with-dbfs
    - **mountadl_<confignb/secret>_sparkApi.py** - contains bootstap code to mount ADL via Spark API. See here for more info: https://docs.azuredatabricks.net/spark/latest/data-sources/azure/azure-datalake.html#access-azure-data-lake-store-using-the-spark-api

### D. Optional: Create cluster to run notebooks

1. Navigate to **Deploy > DbricksMultiTarget > DeployDbricks > cluster**
2. Inspect cluster.config.json
3. Run `./createcluster.sh`.
4. Once the cluster is created, you can execute the uploaded notebooks.
