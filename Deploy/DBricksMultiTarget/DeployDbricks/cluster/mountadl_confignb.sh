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
# Usage: ./adlmount.sh adlAccount myserviceprincipal john@contoso.com
#
# Requirments:  
# - User must be logged in to the az cli with the appropriate account set.
# - User must have appropraite permission to deploy to a resource group
# - User must have appropriate permission to create a service principal
#

set -o errexit
set -o pipefail
set -o nounset
set -o xtrace

_timestamp=$(date +%s)
_defaultTemplatePath="./notebookTemplates"
_tmpDir=/tmp/$USER/dbricks${_timestamp}
mkdir -p $_tmpDir

# Check if required utilities are installed
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed. See https://stedolan.github.io/jq/. Aborting."; exit 1; }
command -v az >/dev/null 2>&1 || { echo >&2 "I require azure cli but it's not installed. See https://bit.ly/2Gc8IsS. Aborting."; exit 1; }
command -v databricks >/dev/null 2>&1 || { echo >&2 "I require databricks cli but it's not installed. See https://github.com/databricks/databricks-cli. Aborting."; exit 1; }

_main() {
    declare dlName="${1-}"
    declare spName="${2-}" 
    declare spClientId="${3-}"
    declare spTenantId="${4-}"
    declare kvName="${5-}"
    declare kvSpSecretName="${6-}"
    declare templatePath="${7-}"

    while [[ -z $dlName ]]; do
        read -rp "Enter Azure Data Lake name: " dlName
    done

    while [[ -z $spName ]]; do
        read -rp "Enter AD Service Principal name: " spName
    done

    while [[ -z $kvName ]]; do
        read -rp "Enter KeyVault name where AD Service principal password is stored: " kvName
    done

    while [[ -z $kvSpSecretName ]]; do
        read -rp "Enter KeyVault secret name referring to AD Service Principal password: " kvSpSecretName
    done

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

    # Upload config notebook
    _uploadConfigNotebook $templatePath $dbiUserName $spClientId $spPassword $spTenantId $dlName

    # Now that config notebook is uploaded, upload remaining notebooks from templates
    _uploadNotebook "mountadl_confignb_sparkApi" $templatePath $dbiUserName
    _uploadNotebook "mountadl_confignb_dbfs" $templatePath $dbiUserName
}

_uploadConfigNotebook() {
    declare templatePath="$1"
    declare dbiUsername="$2"
    declare spClientId="$3"
    declare spPassword="$4"
    declare spTenantId="$5"
    declare dlName="$6"

    # Check if template exists
    configT="${templatePath}/config.template"
    [[ -e $configT ]] || { echo >&2 "Config file location $configT does not exists."; exit 1; }

    # Create temporary copy of template
    tmpConfigFile="${_tmpDir}/config.py"
    cat $configT > $tmpConfigFile

    # Replace placeholders in copy of template
    sed -i -e "s/REPLACE_W_CLIENT_ID/${spClientId}/g" $tmpConfigFile
    sed -i -e "s/REPLACE_W_SERVICE_CREDENTIALS/${spPassword}/g" $tmpConfigFile
    sed -i -e "s/REPLACE_W_DIRECTORY_ID/${spTenantId}/g" $tmpConfigFile
    sed -i -e "s/REPLACE_W_ADL_ACCOUNT_NAME/${dlName}/g" $tmpConfigFile

    # Set workspace and path to config variables
    workspaceConfigPath=$(_getConfigPath ${dbiUsername})

    # Upload config notebook
    databricks workspace import -ol PYTHON $tmpConfigFile $workspaceConfigPath
}

_uploadNotebook() {
    declare templateName="$1"
    declare templatePath="$2"
    declare dbiUsername="$3"

    # Check if template exists
    templatePath=${templatePath}/${templateName}.template
    [[ -n $templatePath ]] || { echo "${templateName}.template does not exist"; exit 1;}

    # Create temporary copy of template
    tmpFile="${_tmpDir}/${templateName}.py"
    cat $templatePath > $tmpFile

    # Replace placeholders in copy of template
    dbiworkspacePath=$(_getWorkspacePath ${dbiUsername})
    workspaceConfigPath=$(_getConfigPath ${dbiUsername})
    sed -i -e "s/__REPLACE_W_CONFIG_PATH__/${workspaceConfigPath//\//\\/}/g" $tmpFile

    # Import into databricks workspace (will overwrite!)
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