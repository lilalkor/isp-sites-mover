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

TMP_PATH='/root/site_mover'
DOMAIN_PARAMS=''
ISP_VERSION=''

# Parsing arguments recieved
check_args()
{
    #if [ $# -eq 0 ]; then
    #    echo -e "$usage_text"
    #    exit 0
    #fi
    local opt
    while getopts "hc:" opt; do
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
            echo -e "RESULT: ${TXT_YLW}${result}${TXT_RST}"; exit 2
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
    local counter=0

    for version in  ${!version_to_file_hash[@]}; do
        local file=${version_to_file_hash[$version]}
        if [ -x ${file} ]; then
            ISP_VERSION=$version
            local full_version=`$file -V`
            ((counter++))
        fi
    done
    case $counter in
        0 )
            echo "Can't find ISPmanager on server"
            finish NOTOK
        ;;
        1 )
            echo "ISPmanager $version detected."
            echo "Full version: $full_version"
        ;;
        * )
            echo "Can't detect ISPmanager version"
            finish NOTOK
        ;;
    esac
}


# Setting commands for different OS
set_commands()
{
    case $ISP_VERSION in
        4 )

        ;;
        5 )
            create_user_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr user.add.finish addinfo=on confirm=* ftp_inaccess= ftp_user=on ftp_user_name=$username limit_charset=off limit_db_enabled=on limit_dirindex="index.php index.html" limit_ftp_users= limit_ftp_users_inaccess= limit_php_mode=php_mode_mod limit_php_mode_cgi=on limit_php_mode_mod=on name=$username passwd=$password php_enable=on sok=ok'
            create_site_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.edit $domain_params'
            gen_siteparams_command='isp5_gen_siteparams $domain $username'
            remove_site_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.delete elid=$domain'
            get_domain_dir="sqlite3 /usr/local/mgr5/etc/ispmgr.db \"SELECT docroot FROM webdomain WHERE name='\$domain';\""

        ;;
        * )
            echo "I don't know how to work with ISPmanager version: $ISP_VERSION"    
            finish NOTOK
        ;;
    esac
}


# Move site with ISPmanager
move_site()
{
    local domain=$1
    local username=$2

    #eval $gen_siteparams_command
    isp5_gen_siteparams $domain $username
    echo "Creating user $username..."
    create_user $username
    echo "Backing up docroot for $domain"
    backup_domain_dir $domain
    echo "Removing old $domain"
    remove_site $domain
    echo "Creating new $domain"
    create_site $domain $DOMAIN_PARAMS
    echo "Restoring docroot for $domain"
    restore_domain_dir $domain
}

# Generate site parameters
isp5_gen_siteparams()
{
    local domain=$1
    local username=$2

    local domain_params="owner=$username sok=ok"
    local webdomain_columns=(`sqlite3 /usr/local/mgr5/etc/ispmgr.db 'PRAGMA table_info(webdomain);' | awk -F\| '{print $2}' | grep -vE 'id|users|docroot'`)
    for column in ${webdomain_columns[@]}; do
        local value=`sqlite3 /usr/local/mgr5/etc/ispmgr.db "SELECT $column FROM webdomain WHERE name='$domain';"`
        local domain_params="$domain_params $column=$value"
    done
    DOMAIN_PARAMS=$domain_params
}

# Create user with ISPmanager
create_user()
{
    local username=$1
    local password=`pwgen -scan 16 1`

    local result=`eval $create_user_command`
    #if [[ $result =~ ERROR ]]; then
    #    echo $result
    #    finish NOTOK
    #fi
}

# Create www-domain with ISPmanager
create_site()
{
    local domain=$1
    local domain_params=$DOMAIN_PARAMS

    local result=`eval $create_site_command`
    if [[ $result =~ ERROR ]]; then
        echo $result
        finish NOTOK
    fi
}

# Remove www-domain with ISPmanager
remove_site()
{
    local domain=$1

    local result=`eval $remove_site_command`
    if [[ $result =~ ERROR ]]; then
        echo $result
        finish NOTOK
    fi
}

# Move sitedir to tmp
backup_domain_dir()
{
    local domain=$1 
    local tmp_path=$TMP_PATH
    local backup_path=${tmp_path}/${domain}

    local domain_dir=`eval $get_domain_dir`
    mkdir -p $tmp_path
    mv $domain_dir $backup_path
    mkdir $domain_dir
}

# Restore sitedir from tmp
restore_domain_dir()
{
    local domain=$1
    local tmp_path=$TMP_PATH
    local backup_path=${tmp_path}/${domain}

    local domain_dir=`eval $get_domain_dir`
    /bin/rm -rf $domain_dir
    mv $backup_path $domain_dir
}




check_args
check_bash_version
detect_package_manager
detect_os
detect_isp_version
set_commands

move_site drupal.lilal.tk fasttest
