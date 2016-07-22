#!/bin/bash
set -ueo pipefail

# Usage text
usage_text=$(cat << EOF
Usage: `basename $0` [-u user -d domain | -a]
Script to move sites between ISPmanager users.

You can move one site:
    -u\tusername of new site owner
    -d\tdomainname to move

Or you can perform automatic moving of all sites to separate users:
    -a\tmove all sites to separate users
    -u\tmove sites only from one user
    -x\texclude site (if you want to specify, which one to keep on old user)

Users are created if do not exist.

EOF
)


TXT_GRN='\e[0;32m'
TXT_RED='\e[0;31m'
TXT_YLW='\e[0;33m'
TXT_RST='\e[0m'
DATE_FORMAT='+%H:%M:%S'

TMP_PATH='/root/site_mover'
DOMAIN_PARAMS=''
ISP_VERSION=''
ISPMGR_CONF=''
MASS_MOVING='0'
USERNAME=''
DOMAIN=''
EXCLUDE=''

# Echo with time
echo_time()
{
    echo -e "[${TXT_GRN}`date $DATE_FORMAT`${TXT_RST}] $1"
}

# Echo with leading TAB
echo_tab()
{
    echo -e " - $1"
}

# Parsing arguments recieved
parse_args()
{
    local opt
    if [ $# -eq 0 ]; then
        echo -e "$usage_text"
        exit 0
    fi
    while getopts "hu:d:x:a" opt; do
        case $opt in
            h )
                echo -e "$usage_text"
                exit 0
            ;;
            u )
                USERNAME=$OPTARG
            ;;
            d )
                DOMAIN=$OPTARG
            ;;
            a )
                MASS_MOVING='1'
            ;;
            x )
                EXCLUDE=$OPTARG
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
        echo -e "OS: ${TXT_YLW}${OS}${TXT_RST}"
    else
        # If not, trying redhat-release file (mainly because of bitrix-env)
        if [ -f $redhat_release_file ]; then
            OS=`head -1 /etc/redhat-release | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'`
            verify_package_manager $OS
            echo -e "OS: ${TXT_YLW}${OS}${TXT_RST}"        
        else
            # Else, trying issue file
            if [ -f $issue_file ]; then
                OS=`head -1 $issue_file | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'` 
                verify_package_manager $OS
                echo -e "OS: ${TXT_YLW}${OS}${TXT_RST}"
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
            echo -e "${TXT_YLW}ISPmanager ${version}${TXT_RST} detected."
            echo -e "Full version: ${TXT_YLW}${full_version}${TXT_RST}"
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
            ISPMGR_CONF='/usr/local/mgr5/etc/ispmgr.conf'
            kill_ispmgr_command='killall -9 core'

            create_user_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr user.add.finish addinfo=on confirm=* ftp_inaccess= ftp_user=on ftp_user_name=$username limit_charset=off limit_db_enabled=on limit_dirindex="index.php index.html" limit_ftp_users= limit_ftp_users_inaccess= limit_php_mode=php_mode_mod limit_php_mode_cgi=on limit_php_mode_mod=on name=$username passwd=$password php_enable=on sok=ok'
            create_site_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.edit $domain_params'
            gen_siteparams_command='isp5_gen_siteparams $domain $username'
            remove_site_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.delete elid=$domain'
            get_domain_dir="sqlite3 /usr/local/mgr5/etc/ispmgr.db \"SELECT docroot FROM webdomain WHERE name='\$domain';\""
            check_user_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr user | grep -q "^name=$username"; echo $?'
            check_domain_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain | grep -q "^name=$domain"; echo $?'
            check_domain_owner_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain | grep -q "^name=$domain owner=$username"; echo $?'

            get_all_users_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr user | sed -re "s/^name=([^ ]+) .*$/\1/"'
            get_all_sites_by_user_command='/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain | grep "owner=$username" | sed -re "s/^name=([^ ]+) .*$/\1/"'

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
    local result=''

    local check_result=$(check_input $domain $username)
    case $check_result in
        # Domain exists, used does not, full action set
        100 )
            echo_tab "Getting current site parameters"
            eval $gen_siteparams_command

            echo_tab "Creating user $username"
            create_user $username

            echo_tab "Backing up docroot for $domain"
            backup_domain_dir $domain

            echo_tab "Removing old $domain from panel"
            remove_site $domain

            echo_tab "Creating new $domain in panel"
            create_site $domain

            echo_tab "Restoring docroot for $domain"
            restore_domain_dir $domain

            echo_tab "Setting permissions for $domain"
            set_permissions $domain $username
        ;;
        # User and domain exist. no need to create user
        110 )
            echo_tab "Getting current site parameters"
            eval $gen_siteparams_command

            echo_tab "User $username exists."

            echo_tab "Backing up docroot for $domain"
            backup_domain_dir $domain

            echo_tab "Removing old $domain from panel"
            remove_site $domain 

            echo_tab "Creating new $domain in panel"
            create_site $domain

            echo_tab "Restoring docroot for $domain"
            restore_domain_dir $domain

            echo_tab "Setting permissions for $domain"
            set_permissions $domain $username
        ;;
        # Everything is already done
        111 )
            echo_tab "Domain '$domain' already belongs to user '$username'. Skipping."
            return 0
        ;;
        # Domain does not exist
        0?? )
            echo_tab "Domain '$domain' does not exist."
        ;;
        * )
            echo_tab 'How did you get there?'
            finish NOTOK
        ;;
    esac
}

# Check input for correctness
check_input()
{
    local domain=$1
    local username=$2
    local domain_exists='0'
    local user_exists='0'
    local needed_owner='0'
    if [ `eval $check_domain_command` -eq 0 ]; then
        domain_exists='1'
    fi
    if [ `eval $check_user_command` -eq 0 ]; then
        user_exists='1'
    fi
    if [ `eval $check_domain_owner_command` -eq 0 ]; then
        needed_owner='1'
    fi
    
    local result=`echo "${domain_exists}${user_exists}${needed_owner}"`
    echo $result
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
    local func_name=${FUNCNAME[0]}

    local answer=`eval $create_user_command`
    check_result $func_name ${answer[@]}
    local result=$?
    case $result in
        0 )
            return 0
        ;;
        1 )
            echo "Error in $func_name"
            echo "$answer"
            return 1
        ;;
        * )
            echo "Undefined result in $func_name "
            echo -e "Answer:\n$answer"
            finish NOTOK
        ;;
    esac
}

# Create www-domain with ISPmanager
create_site()
{
    local domain=$1
    local domain_params=$DOMAIN_PARAMS
    local func_name=${FUNCNAME[0]}

    local answer=`eval $create_site_command`
    check_result $func_name ${answer[@]}
    local result=$?
    case $result in
        0 )
            return 0
        ;;
        1 )
            echo "Error in $func_name"
            echo "$answer"
            return 1
        ;;
        2 )
            echo "Adding 'Option InsecureDomain' to $ISPMGR_CONF"
            echo 'Option InsecureDomain' >> $ISPMGR_CONF
            eval $kill_ispmgr_command
            answer=`eval $create_site_command`
        ;;
        * )
            echo "Undefined result in $func_name "
            echo -e "Answer:\n$answer"
            finish NOTOK
        ;;
    esac
}

# Check ISPmanager API results
check_result()
{
    local func=$1
    shift
    local answer=$@

    case $func in
        create_site )
            if [[ $answer =~ 'ERROR dns(domain_access)' ]]; then
                return 2
            elif [[ $answer =~ 'ERROR' ]]; then
                return 1
            else
                return 0
            fi
        ;;
        remove_site )
            if [[ $answer =~ 'ERROR' ]]; then
                return 1
            else
                return 0
            fi
        ;;
    esac
}

# Remove www-domain with ISPmanager
remove_site()
{
    local domain=$1
    local func_name=${FUNCNAME[0]}

    local answer=`eval $remove_site_command`
    check_result $func_name ${answer[@]}
    local result=$?
    case $result in
        0 )
            return 0
        ;;
        1 )
            echo "Error in $func_name"
            echo "$answer"
            return 1
        ;;
        * )
            echo "Undefined result in $func_name "
            echo -e "Answer:\n$answer"
            finish NOTOK
        ;;
    esac
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

# Fix owner for sitedir
set_permissions()
{
    local domain=$1
    local username=$2

    local domain_dir=`eval $get_domain_dir`
    chown -R ${username}:${username} $domain_dir
}



# Move all sites to different users
move_all_sites()
{
    local domain=''
    local username=''
    local new_username=''
    local users=''
    local domains=''
    local exclude=$EXCLUDE

    if [ $# -eq 0 ]; then
        users=(`eval $get_all_users_command`)
    else
        users=$1
    fi

    for username in ${users[@]}; do
        echo_time "Processing user '$username'"
        if [ `eval $check_user_command` -eq 1 ]; then
            echo "No user '$username'. Skipping."
            break 
        fi
        domains=(`eval $get_all_sites_by_user_command`)
        if [ ${#domains[@]} -gt 1 ]; then
            for domain in ${domains[@]}; do
                if [ "$domain" == "$exclude" ]; then
                    echo_time "Site '$domain' is exluded. Skipping."
                else
                    new_username=$(gen_new_usename $domain)
                    echo_time "Moving site '$domain' to user '$new_username'"
                    move_site $domain $new_username
                fi
            done
        else
            echo "User '$username' have only ${#domains[@]} sites. Skipping."
        fi
    done
    echo_time 'Finished!'
}

# Generate new username based on domain
gen_new_usename()
{
    local domain=$1
    local username=''
    
    # Form username from domain
    # Main idea is create something like my_domain_com or my_domain_com_3
    # We are limited to 16 characters and chop trailing '_' just for more fancy names
    local dot_count=`echo $domain | grep -o '\.' | wc -l`
    case $dot_count in
        # Not a correct domain
        0 )
            finish "Not a correct domain name: '$domain'."
        ;;
        # 2nd level domain
        1 )
            username=`echo $domain | awk -F\. '{print $(NF-1)"_"$NF}' | cut -c1-13 | sed -e 's/_$//'`
        ;;
        # 3rd level domain
        2 )
            username=`echo $domain | awk -F\. '{print $(NF-2)"_"$(NF-1)"_"$NF}' | cut -c1-13 | sed -e 's/_$//'`
        ;;
        # More level domain
        * )
            username=`echo $domain | awk -F\. '{print $1_$2}' | cut -c1-13 | sed -e 's/_$//'`
        ;;      
    esac

    # Add 01-99 to the end, if user exists
    if [ `eval $check_user_command` -eq 0 ]; then
        local short_username=$username
        for i in {1..99}; do
            username="${short_username}_${i}"
            if [ `eval $check_user_command` -ne 0 ]; then 
                break
            elif [ $i -eq 99 ]; then 
                finish "Can't create user for domain '$domain'"
            fi
        done

    fi
    echo $username
}



# Preparing everything
parse_args "$@"
check_bash_version
detect_package_manager
detect_os
detect_isp_version
set_commands

# Move sites
if [ $MASS_MOVING -eq 0 ]; then
    if [ ! -z $DOMAIN ] || [ ! -z $USERNAME ]; then
        echo_time "Moving site '$DOMAIN' to user '$USERNAME'"
        move_site $DOMAIN $USERNAME
        echo_time 'Finished!'
    else
        echo -e "$usage_text"
        exit 1
    fi
else
    if [ ! -z $USERNAME ]; then
        echo "Moving all sites of user '$USERNAME' to new users."
        move_all_sites $USERNAME
    else
        echo "Moving all sites to new users."
        move_all_sites
    fi
fi
