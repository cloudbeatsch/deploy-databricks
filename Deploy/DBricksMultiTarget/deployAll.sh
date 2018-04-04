
#!/bin/bash

# Access granted under MIT Open Source License: https://en.wikipedia.org/wiki/MIT_License
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
# documentation files (the "Software"), to deal in the Software without restriction, including without limitation 
# the rights to use, copy, modify, merge, publish, distribute, sublicense, # and/or sell copies of the Software, 
# and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions 
# of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED 
# TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
# DEALINGS IN THE SOFTWARE.
#
#
# Description: Deploy ARM template which creates a Databricks account
#
# Usage: ./deployAll.sh 
#
# Requirments:  
# - User must be logged in to the az cli with the appropriate account set.
# - User must have appropraite permission to deploy to a resource group
# - User must have appropriate permission to create a service principal

set -o errexit
set -o pipefail
set -o nounset
set -o xtrace

###################
# Check script prerequisites

# Check if required utilities are installed
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed. See https://stedolan.github.io/jq/.  Aborting."; exit 1; }
command -v az >/dev/null 2>&1 || { echo >&2 "I require azure cli but it's not installed. See https://bit.ly/2Gc8IsS. Aborting."; exit 1; }

# Params
paramsFile="${1-}"

# Check if paramsFile exists
[[ -n $paramsFile ]] || paramsFile="deployAll.parameters.json"
[[ -n $paramsFile && -a $paramsFile ]] || { echo >&2 "Params file does not exists. Aborting."; exit 1; }

# Read params file
dbricksRgName=$(cat $paramsFile | jq -r '.DatabricksResourceGroup')
dbricksLocation=$(cat $paramsFile | jq -r '.DatabricksLocation')
dbricksSubscriptionId=$(cat $paramsFile | jq -r '.DatabricksSubscriptionId')
adlRgName=$(cat $paramsFile | jq -r '.DataLakeResourceGroup')
adlLocation=$(cat $paramsFile | jq -r '.DataLakeLocation')
adlSubscriptionId=$(cat $paramsFile | jq -r '.DataLakeSubscriptionId')

# Deployment Variables
timestamp=$(date +%s)
deployName="deployment${timestamp}"
dbricksTemplateFile="./DeployDbricks/azuredeploy.json"
dbricksParametersFile="./DeployDbricks/azuredeploy.parameters.json"
dbricksScope="adlScope"
dbricksNotebookTemplates="./DeployDbricks/cluster/notebookTemplates"
dbricksOutFile="/tmp/DeployDbricks.deploy.out"
adlTemplateFile="./DeployADL/azuredeploy.json"
adlParametersFile="./DeployADL/azuredeploy.parameters.json"
adlOutFile="/tmp/DeployADL.deploy.out"

###############################################
# Deploy databricks

# Set sub
az account set -s $dbricksSubscriptionId

# Retrieve KeyVault User Id
upn=$(az account show \
        --output json | 
        jq -r '.user.name')
keyVaultUserId=$(az ad user show --upn $upn \
    --output json |
    jq -r '.objectId')

# Deploy
./DeployDbricks/deploy.sh \
    "$dbricksRgName" \
    "$dbricksLocation" \
    "$deployName" \
    "$dbricksTemplateFile" \
    "$dbricksParametersFile" \
    "keyVaultUserId=${keyVaultUserId}" \
    "$dbricksOutFile"

#################################################
# Deploy ADL and Service Principal

# Additional Params from previous
kvName=$(cat $dbricksOutFile | jq -r '.properties.outputs.keyVaultName.value')
kvSpSecretName=$(cat $dbricksOutFile | jq -r '.properties.outputs.keyVaultSpSecretName.value')
kvSubId=$(cat $dbricksOutFile | jq -r '.properties.outputs.keyVaultSubscriptionId.value')

# Set sub
az account set -s $adlSubscriptionId

# Deploy
./DeployADL/deploy.sh \
    "$adlRgName" \
    "$adlLocation" \
    "$deployName" \
    "$adlTemplateFile" \
    "$adlParametersFile" \
    "kvName=${kvName} kvSubId=${kvSubId} kvSpSecretName=${kvSpSecretName}" \
    "$adlOutFile"

#################################################
# Upload Databricks Bootstrapped notebooks into workspace

# Configure CLI
echo "To continue, please configure your databricks cli to point to the newly create workspace"
databricks configure --token

# Additional Params from previous
dlName=$(cat $adlOutFile | jq -r '.properties.outputs.dlName.value')
spName=$(cat $adlOutFile | jq -r '.properties.outputs.spName.value')
kvName=$(cat $adlOutFile | jq -r '.properties.outputs.kvName.value')
dbricksLocation=$(cat $dbricksOutFile | jq -r '.properties.outputs.dbricksLocation.value')

# Retrieve Service Account Details
az account set -s $adlSubscriptionId
spNameDetails=$(az ad sp show --id http://$spName -o json )
spClientId=$(echo $spNameDetails | jq -r '.appId')
spTenantId=$(echo $spNameDetails | jq -r '.additionalProperties.appOwnerTenantId')

# Set sub
az account set -s $dbricksSubscriptionId
./DeployDbricks/cluster/mountadl_confignb.sh \
    $dlName \
    $spName \
    $spClientId \
    $spTenantId \
    $kvName \
    $kvSpSecretName \
    $dbricksNotebookTemplates

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

####
echo "Deployment complete!"


