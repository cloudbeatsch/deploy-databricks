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
# Description: Creates Notebook setup to mount to ADL
#
# Usage: ./secretApi.sh adlAccount myserviceprincipal john@contoso.com
#
# Requirments:  
# - User must be logged in to the az cli with the appropriate account set.
# - User must have appropraite permission to deploy to a resource group
# - User must have appropriate permission to create a service principal
#

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

_timestamp=$(date +%s)
_defaultTemplatePath="./notebookTemplates"
_defaultScope="AzureDataLakeScope"
_tmpDir=/tmp/$USER/dbricks${_timestamp}
mkdir -p $_tmpDir

# Check if required utilities are installed
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed. See https://stedolan.github.io/jq/. Aborting."; exit 1; }
command -v az >/dev/null 2>&1 || { echo >&2 "I require azure cli but it's not installed. See https://bit.ly/2Gc8IsS. Aborting."; exit 1; }
command -v databricks >/dev/null 2>&1 || { echo >&2 "I require databricks cli but it's not installed. See https://github.com/databricks/databricks-cli. Aborting."; exit 1; }
#[[ -e ~/.netrc ]] || { echo >&2 "I require databricks token configured in the .netrc correctly. See https://docs.azuredatabricks.net/api/latest/authentication.html#store-token-in-netrc-file. Aborting."; exit 1; }

_main() {
    declare dlName="${1-}"
    declare spName="${2-}" 
    declare spClientId="${3-}"
    declare spTenantId="${4-}"
    declare kvName="${5-}"
    declare kvSpSecretName=${6-}
    declare dbiRegion="${7-}"
    declare scope="${8-}"
    declare templatePath="${9-}"

    while [[ -z $dlName ]]; do
        read -rp "Enter Azure Data Lake name: " dlName
    done

    while [[ -z $spName ]]; do
        read -rp "Enter AD Service Principal name: " spName
    done

    while [[ -z $spClientId ]]; do
        read -rp "Enter AD Service Principal Client Id: " spClientId
    done

    while [[ -z $spTenantId ]]; do
        read -rp "Enter AD Service Principal Tenant Id: " spTenantId
    done

    while [[ -z $kvName ]]; do
        read -rp "Enter KeyVault name where AD Service principal password is stored: " kvName
    done

    while [[ -z $kvSpSecretName ]]; do
        read -rp "Enter KeyVault secret name referring to AD Service Principal password: " kvSpSecretName
    done

    while [[ -z $dbiRegion ]]; do
        read -rp "Enter Databricks region (ea. eastus2): " dbiRegion
    done

    if [[ ! $scope ]]; then
        read -rp "Enter name of the Databricks scope to store Azure Data Lake secrets (Default: $_defaultScope): " scope
        [[ -n $scope ]] || scope=$_defaultScope
    fi

    if [[ ! $templatePath ]]; then
        read -rp "Enter templates folder path (Default: $_defaultTemplatePath): " templatePath
        [[ -n $templatePath ]] || templatePath=$_defaultTemplatePath
    fi

    # Retrieve Service Principal Password from keyvault
    spPassword=$(az keyvault secret show \
        --name $kvSpSecretName \
        --vault-name $kvName \
        --query "value" \
        --output tsv)

    # Retrieve username
    dbiUserName=$(az account show \
        --output json \
        | jq -r '.user.name')

    # Retrieve token 
    dbiToken=$(awk '/token/ && NR==3 {print $0;exit;}' ~/.databrickscfg | cut -d' ' -f3)
    [[ -n $dbiToken ]] || { echo >&2 "Databricks cli not configured correctly. Please run databricks configure --token. Aborting."; exit 1; }

    # Create scope and secret
    dbiDomain="${dbiRegion}.azuredatabricks.net"
    _createOrUpdateSecret $dbiDomain $scope "serviceClientId" $spClientId $dbiToken
    _createOrUpdateSecret $dbiDomain $scope "serviceCredentials" $spPassword $dbiToken
    _createOrUpdateSecret $dbiDomain $scope "serviceDirectoryId" $spTenantId $dbiToken
    _createOrUpdateSecret $dbiDomain $scope "adlAccountName" $dlName $dbiToken

    # Now that config notebook is uploaded, upload remaining notebooks from templates
    _uploadNotebook "mountadl_secret_sparkApi" $templatePath $dbiUserName $scope
    _uploadNotebook "mountadl_secret_dbfs" $templatePath $dbiUserName $scope
}

_createOrUpdateSecret () {
    declare dbiDomain="$1"
    declare scope="$2"
    declare secretName="$3"
    declare secretValue="$4"
    declare token="$5"

    # As of 2018-03-04, databricks 0.6v does not support Secret API
    # Thus, using REST API directly

    echo "Checking if scope '$scope' already exists"
    scopeExists=$(curl -s -n -X GET -H "Authorization: Bearer ${token}" \
            -k https://${dbiDomain}/api/2.0/preview/secret/scopes/list |
            jq -r --arg s $scope '.scopes | .[]? | select(.name | contains($s))')

    if [[ ! $scopeExists ]]; then
        # Create scope
        # Scopes are created with MANAGE permissions for the user who created the scope.
        echo "Creating scope '$scope'"
        curl -sn -X POST -H "Authorization: Bearer ${token}" \
            -k https://${dbiDomain}/api/2.0/preview/secret/scopes/create \
            -d '{"scope": "'$scope'"}'
    fi

    # Add secret to scope
    # Will overwrite any existing secret
    echo "Adding secret '$secretName' to scope '$scope'"
    curl -sn -X POST -H "Authorization: Bearer ${token}" \
        -k https://${dbiDomain}/api/2.0/preview/secret/secrets/write \
        -d '{ "scope": "'${scope}'", "key": "'${secretName}'", "string_value": "'${secretValue}'"}'
}

_uploadNotebook() {
    declare templateName="$1"
    declare templatePath="$2"
    declare dbiUsername="$3"
    declare scope="$4"

    # Check if template exists
    templatePath=${templatePath}/${templateName}.template
    [[ -e $templatePath ]] || { echo "${templateName}.template does not exist"; exit 1;}

    # Create temporary copy of template
    tmpFile="${_tmpDir}/${templateName}.py"
    cat $templatePath > $tmpFile

    # Replace placeholders in copy of template
    sed -i -e "s/__REPLACE_W_SCOPE__/${scope}/g" $tmpFile

    # Import into databricks workspace (will overwrite!)
    dbiworkspacePath=$(_getWorkspacePath ${dbiUsername})
    echo "Uploading databricks notebook to '$dbiworkspacePath/${templateName}.py'"
    databricks workspace import -ol PYTHON $tmpFile $dbiworkspacePath/${templateName}.py
}

_getConfigPath() {
    declare dbiUsername="$1"
    dbiworkspacePath=$(_getWorkspacePath ${dbiUsername})
    echo "${dbiworkspacePath}/config.py"
}

_getWorkspacePath() {
    declare dbiUsername="$1"
    echo "/Users/${dbiUsername}"
}

_main $@