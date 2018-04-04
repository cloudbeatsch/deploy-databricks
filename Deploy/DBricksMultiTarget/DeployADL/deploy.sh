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
# Description: Deploy ARM template which creates an ADL account and service principal
#
# Usage: ./deploy.sh myResourceGroup "East US 2"
#
# Requirments:  
# - User must be logged in to the az cli with the appropriate account set.
# - User must have appropraite permission to deploy to a resource group
# - User must have appropriate permission to create a service principal

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

###################
# Check script prerequisites

# Check if required utilities are installed
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed. See https://stedolan.github.io/jq/. Aborting."; exit 1; }
command -v az >/dev/null 2>&1 || { echo >&2 "I require azure cli but it's not installed. See https://bit.ly/2Gc8IsS. Aborting."; exit 1; }

###################
# Capture timestamp and set defaults
export _timestamp=$(date +%s)
export _defaultTemplateFile="./azuredeploy.json"
export _defaultParamsFile="./azuredeploy.parameters.json"

###################
# Capture all necessary user parameters

rgName="${1-}"         # Resource Group name
rgLocation="${2-}"     # Resource Group location
deployName="${3-}"     # Deplyment name
templateFile="${4-}"   # Template File location
parametersFile="${5-}" # Parameters File location
overrideParams="${6-}" # Optional Parameters override
outFile="${7-}"

while [[ -z $rgName ]]; do
    read -rp "Enter Resource Group name: " rgName
done

while [[ -z $rgLocation ]]; do
    read -rp "Enter Azure Location (ei. EAST US 2): " rgLocation
done

if [[ ! $deployName ]]; then
    read -rp "Enter Deployment name (Optional): " deployName
    [[ -n $deployName ]] || { deployName="deployment${_timestamp}"; }
fi

if [[ ! $templateFile ]]; then
    read -rp "Enter Template file location (Default: $_defaultTemplateFile): " templateFile
    [[ -n $templateFile ]] || { templateFile="$_defaultTemplateFile"; }
fi

if [[ ! $parametersFile ]]; then
    read -rp "Enter Parameters file location (Default: $_defaultParamsFile): " parametersFile
    [[ -n $parametersFile ]] || { parametersFile="$_defaultParamsFile"; }
fi

#####################
# Deploy ARM template

# Check if param and template files exists
[[ -e $parametersFile ]] || { echo >&2 "Parameters file location $parametersFile does not exists."; exit 1; }
[[ -e $templateFile ]] || { echo >&2 "Template file location $templateFile does not exists."; exit 1; }

echo "Creating resource group: $rgName"
az group create --name "$rgName" --location "$rgLocation"

echo "Deploying resources into $rgName"
armOutput=$(az group deployment create \
    --name "$deployName" \
    --resource-group "$rgName" \
    --template-file "$templateFile" \
    --parameters @"$parametersFile" \
    --parameters $overrideParams \
    --output json)

if [[ -z $armOutput ]]; then
    echo >&2 "ARM deployment failed." 
    exit 1
fi

#####################
# Service Principal
# Create / Retrieve Service Principal then assigned permissions to Azure Data lake

# Extract parameters 
dlName=$(echo $armOutput | jq -r '.properties.outputs.dlName.value')
spName=$(echo $armOutput | jq -r '.properties.outputs.spName.value')
spDlFolder=$(echo $armOutput | jq -r '.properties.outputs.spDlFolder.value')
dlSubId=$(echo $armOutput | jq -r '.properties.outputs.dlSubId.value')
kvName=$(echo $armOutput | jq -r '.properties.outputs.kvName.value')
kvSubId=$(echo $armOutput | jq -r '.properties.outputs.kvSubId.value')
kvSpSecretName=$(echo $armOutput | jq -r '.properties.outputs.kvSpSecretName.value')

echo "Retrieving service principal '$spName' password from keyvault."
az account set --subscription $kvSubId # switch to sub with keyvault
spPassword=$(az keyvault secret show \
    --vault-name $kvName \
    --name $kvSpSecretName \
    --query "value" \
    --output tsv)
az account set --subscription $dlSubId # switch back to sub with ADL

# Create or reuse service principal
if [[ -z $(az ad sp show --id "http://${spName}" 2>/dev/null) ]]; then
    echo "Creating AD service principal '$spName'"
    az ad sp create-for-rbac --name $spName --password $spPassword --skip-assignment
else
    echo "Setting AD service principal '$spName' credentials to align with password in key vault"
    az ad sp reset-credentials --name $spName --password $spPassword > /dev/null >&2
fi

echo "Retrieving service principal ObjectId of service principal '$spName'"
spObjectId=$(az ad sp show --id http://${spName} --query 'objectId' --output tsv)

echo "Assigning permissions to folder in DataLake '$dlName' to the service principal '$spName'"
az dls fs access set-entry --account $dlName \
   --acl-spec "user:$spObjectId:rwx" \
   --path "$spDlFolder" 

#####################
# Write out output
jq . <<< $armOutput

# Write to output file, if specified
[[ -n $outFile ]] && { echo $armOutput | jq . > $outFile; }
