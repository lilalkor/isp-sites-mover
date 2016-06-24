#!/bin/bash
set -u

# Usage text
usage_text=$(cat << EOF
Usage: `basename $0`
Script to move sites between ISPmanager users.

EOF
)


TXT_GRN='\e[0;32m'
TXT_RED='\e[0;31m'
TXT_YLW='\e[0;33m'
TXT_RST='\e[0m'
ISP_VERSION=''

# Parsing arguments recieved
check_args()
{
    #if [ $# -eq 0 ]; then
    #    echo -e "$usage_text"
    #    exit 0
    #fi
    while getopts "hlrRp:v:o:c:" opt; do
        case $opt in
            h )
                echo -e "$usage_text"
                exit 0
            ;;
            \? )
                echo "Invalid option: -$OPTARG" >&2
                exit 1
            ;;
            : )
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
          ;;
      esac
    done
}


# Exit function
finish()
{
    local result=$1
    case $result in
        OK )
            echo -e "RESULT: ${TXT_GRN}OK${TXT_RST}"; exit 0
        ;;
        NOTOK )
            echo -e "RESULT: ${TXT_RED}FAIL${TXT_RST}"; exit 1
        ;;
        * )
            echo -e "RESULT: ${TXT_YLW}UNKNOWN${TXT_RST}"; exit 2
        ;;
    esac
}


# Check package manager
detect_package_manager()
{
    local dpkg=""
    local rpm=""
    local dpkg=`which dpkg >/dev/null 2>&1; echo $?`
    local rpm=`which rpm >/dev/null 2>&1; echo $?`
    local result=`echo "$dpkg$rpm"`
    case $result in
        01 )
            package_manager='dpkg'
        ;;
        10 )
            package_manager='rpm'
        ;;
        00 )
            echo 'You have both dpkg and rpm? Hello, Dr. Frankenstein!'
            finish NOTOK
        ;;
        11 )
            echo "You don't have neither dpkg, nor rpm. We don't know, what to do here. Exiting."
            finish NOTOK
        ;;
        * )
            echo "We couldn't detect package manager. Exiting"
            finish NOTOK
        ;;
    esac
}


# OS to package manager hash
verify_package_manager()
{
    local os=$1
    local -A os_to_pm_hash
    os_to_pm_hash["Debian"]="dpkg"
    os_to_pm_hash["Ubuntu"]="dpkg"
    os_to_pm_hash["CentOS"]="rpm"
    
    local os_name=`echo ${os} | tr -d [:digit:]` 
    if [ ${os_to_pm_hash[$os_name]-} ]; then
        if [ ! "${os_to_pm_hash[$os_name]}" == "$package_manager" ]; then
            echo "Your have $package_manager on ${os}. We can't do anything here. Exiting."
            finish NOTOK 
        fi
    else
        echo "We don't know, what package manager is needed for your OS. You have $package_manager on ${os}. Exiting."
        finish NOTOK
    fi
}


# Detect OS
detect_os()
{
    local issue_file='/etc/issue'
    local os_release_file='/etc/os-release'
    local redhat_release_file='/etc/redhat-release'
    # First of all, trying os-relese file
    if [ -f $os_release_file ]; then
        local name=`grep '^NAME=' $os_release_file | awk -F'[" ]' '{print $2}'`
        local version=`grep '^VERSION_ID=' $os_release_file | awk -F'[". ]' '{print $2}'`
        OS=`echo "${name}${version}"`
        verify_package_manager $OS
        echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"
    else
        # If not, trying redhat-release file (mainly because of bitrix-env)
        if [ -f $redhat_release_file ]; then
            OS=`head -1 /etc/redhat-release | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'`
            verify_package_manager $OS
            echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"        
        else
            # Else, trying issue file
            if [ -f $issue_file ]; then
                OS=`head -1 $issue_file | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'` 
                verify_package_manager $OS
                echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"
            else
                # If none of that files worked, exit
                echo -e "${TXT_RED}Cannot detect OS. Exiting now"'!'"${TXT_RST}"
                finish NOTOK
            fi
        fi
    fi
}


# Exit if bash is older then 4.0
check_bash_version()
{
    local bash_version=`echo $BASH_VERSION| awk -F. '{print $1}'`
    if [ $bash_version -lt 4 ]; then
        echo -e "Old bash ($BASH_VERSION). 4.0 or newer needed."
        finish NOTOK
    fi
}


# Detect ISPmanager version
detect_isp_version()
{
    local -A version_to_file_hash
    version_to_file_hash['4']='/usr/local/ispmgr/bin/ispmgr'
    version_to_file_hash['5']='/usr/local/mgr5/bin/core'
    local version=''

    for version in  ${!version_to_file_hash[@]}; do
        local file=${version_to_file_hash[$version]}
        if [ -x ${file} ]; then
            ISP_VERSION=$version
            local full_version=`$file -V`
            echo "ISPmanager $version detected."
            echo "Full version: $full_version"
        fi
    done

}





check_args
check_bash_version
detect_package_manager
detect_os
detect_isp_version
