# Introduction 
The following deploys a PoC showing the ability to mount an [Azure Data Lake Store](https://azure.microsoft.com/en-us/services/data-lake-store/) to an [Azure Databricks](https://azure.microsoft.com/en-au/services/databricks/) workspace across two Azure tenants. It incorporates the use of [Azure Key Vault](https://azure.microsoft.com/en-us/services/key-vault/) as the main storage of the AD Service Principal password during deployment. To demonstrate two ways ways of handling secrets within Azure Databricks, after deployment the service principal credentials are stored in a config notebook in the user's Azure Databricks workspace and in the Azure Databricks' Secret API (preview).

# Requirements
- [Azure cli 2.0](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
- [jq](https://stedolan.github.io/jq/)
- [Databricks cli](https://github.com/databricks/databricks-cli)

# Getting Started

Ensure you have logged in to azure cli by calling `az login`. You may need to login to multple accounts if the resources are spread across multiple tenants / subscriptions.

## Deploy full solution

1. Navigate to **DBricksMultiTarget**
2. Inspect the following parameters files:
    - `deployAll.parameters.json`
    - `DeployADL/azuredeploy.parameters.json`
    - `DeployDbricks/azuredeploy.parameters.json`
3. Run `./deployAll.sh`
    - NOTE: When prompted, supply Databricks domain and personal access token from newly created workspace. See here for more details: https://docs.azuredatabricks.net/user-guide/dev-tools/databricks-cli.html#set-up-authentication

## Deploy individual components

1. **Deploy Databricks workspace and KeyVault**
    1. Navigate to **Deploy > DBricksMultiTarget > DeployDbricks** 
    2. Inspect and update the deployment parameters in the `azuredeploy.parameters.json` file. 
        - **Important:** Update `keyVaultUserId` value with the user's AD Object Id that will need to retrieve the password of the AD service principal account. Obtain a user's AD Object Id by running `az ad user show --upn <principal_name ei. johndoe@contoso.com>`
    3. Ensure azure cli is pointing to the correct subscription you want to deploy the resources to by running `az account show`. To switch accounts, use `az account set -s <subscription_id>`.
    4. Run `./deploy.sh` and fill in the prompts. 
        - **Important:** Take note of the KeyVault name and subscription id as this will be needed in the next step.

2. **Deploy Azure Data Lake and create a service principal**
    1. Navigate to **Deploy > DBricksMultiTarget > DeployADL**
    2. Inspect and update the deployment parameters in the `azuredeploy.parameters.json` file. 
        - **Important:** Update the KeyVault parameters to point to the appropriate KeyVault created in the previous step.
    3. Ensure azure cli is pointing to the correct subscription you want to deploy the resources to by running `az account show`. To switch accounts, use `az account set -s <subscription_id>`.
    4. Run `./deploy.sh` and fill in the prompts.

3. **Upload Databricks ADLMount-boostrapped notebooks into workspace**
    1. Configure Databricks CLI to point to the newly created Databricks workspace. See here for more details: https://docs.azuredatabricks.net/user-guide/dev-tools/databricks-cli.html#set-up-authentication. Note: There is currently an outstanding bug with Basic Authentication in the v0.6 of the Databricks CLI, so make sure you use Token Authentication instead.
    2. Navigate to **Deploy > DbricksMultiTarget > DeployDbricks > cluster**
    3. Run `./adlmount.sh`. This prompt you for the following:
        - Azure Data Lake account name
        - AD Service Principal name
        - KeyVault account name
        - Name of secret in KeyVault containing AD service principal password
        - Databricks username (ea. john@contoso.com)
        - *Optional*: Template folder path containing notebook templates

    - This will upload the following notebooks to the specified Databricks workspace:
        - **config.py** - contains all configuration to mount ADL. Do not share this notebook!
        - **mountadl_dbfs.py** - contains bootstap code to mount ADL via DBFS. See here for more info: https://docs.azuredatabricks.net/spark/latest/data-sources/azure/azure-datalake.html#mount-azure-data-lake-stores-with-dbfs
        - **mountadl_sparkApi.py** - contains bootstap code to mount ADL via Spark API. See here for more info: https://docs.azuredatabricks.net/spark/latest/data-sources/azure/azure-datalake.html#access-azure-data-lake-store-using-the-spark-api
4. **Optional: Create cluster to run notebooks**
    1. Navigate to **Deploy > DbricksMultiTarget > DeployDbricks > cluster**
    2. Inspect cluster.config.json
    3. Run `./createcluster.sh`.
    4. Once the cluster is created, you can execute the notebooks uploaded.
