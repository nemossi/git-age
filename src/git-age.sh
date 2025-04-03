#!/bin/bash
# git-age: Cross-platform Git transparent encryption (age-based)
set -euo pipefail
VERSION="0.1.2"

# Initialize temp file variable
temp_file=""

# Cleanup function
cleanup()
{
    if [[ -n "${temp_file:-}" && -f "$temp_file" ]]; then
        rm -f "$temp_file" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

show_help()
{
    cat <<EOF
git-age v${VERSION} - Git transparent encryption tool

Usage:
  git-age init [symmetric|asymmetric]  # Initialize repository encryption
  git-age clean                        # Encryption filter
  git-age smudge                       # Decryption filter
  git-age status                       # Show configuration status
  git-age version                      # Show version
  git-age help                         # Show this help

Environment Variables:
  AGE_PASSWORD          # Password for age tool
  AGE_PUBKEY            # Public key for asymmetric encryption
  AGE_KEYFILE           # Private key file for asymmetric decryption

Notes:
  1. Run 'git-age init' first to set up encryption
  2. Always back up your passwords/keys securely
  3. For symmetric encryption, use at least 12 character passwords
EOF
}

validate_config()
{
    if [[ -n "${AGE_PUBKEY:-}" && ! "${AGE_PUBKEY}" =~ ^age1[0-9a-z]+$ ]]; then
        echo "Error: Invalid AGE_PUBKEY format" >&2
        exit 1
    fi
    
    if [[ -n "${AGE_KEYFILE:-}" && ! -f "${AGE_KEYFILE}" ]]; then
        echo "Error: AGE_KEYFILE not found: ${AGE_KEYFILE}" >&2
        exit 1
    fi
}

store_password()
{
    local repo_id="$1"
    local password="$2"
    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* ]]; then
        local escaped_password=$(printf '%q' "$password")
        powershell -Command "\
            [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); \
            \$cred = New-Object System.Management.Automation.PSCredential('git-age', \
            (ConvertTo-SecureString -String $escaped_password -AsPlainText -Force)); \
            \$cred.GetNetworkCredential().Password | \
            cmdkey /add:\"git-age-$repo_id\" /user:\"git-age\" /pass:stdin" >/dev/null 2>&1 || {
            echo "Warning: Failed to store password in Windows Credential Manager" >&2
        }
    elif [[ "$OSTYPE" == "linux-gnu"* ]] && command -v secret-tool >/dev/null; then
        echo -n "$password" | secret-tool store --label="git-age" repo "$repo_id" password -
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        security add-generic-password -a "git-age" -s "$repo_id" -w "$password"
    else
        echo "Warning: No credential manager found. Password will only work in current session." >&2
    fi
}

get_password()
{
    local repo_id=$(get_repo_id)
    
    if [[ -n "${AGE_PASSWORD:-}" ]]; then
        echo "$AGE_PASSWORD"
        return
    fi

    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* ]]; then
        password=$(powershell -Command "\
            \$pass = (cmdkey /list | Where-Object { \$_ -match 'git-age-${repo_id//\'/\'\'}' } | \
            ForEach-Object { \$cred = \$_.Split()[2]; \
            (New-Object -ComObject WScript.Shell).GetObject('cmdkey','/generic:'+\$cred).Password }); \
            if (\$pass) { \$pass } else { exit 1 }" 2>/dev/null) && echo "$password" || prompt_password
    elif [[ "$OSTYPE" == "linux-gnu"* ]] && command -v secret-tool >/dev/null; then
        secret-tool lookup repo "$repo_id" 2>/dev/null || prompt_password
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        security find-generic-password -a "git-age" -s "$repo_id" -w 2>/dev/null || prompt_password
    else
        prompt_password
    fi
}

prompt_password()
{
    local password
    local attempt=0
    local max_attempts=3
    
    while [[ $attempt -lt $max_attempts ]]; do
        read -s -p "Enter git-age password: " password
        echo
        if [[ -z "$password" ]]; then
            echo "Error: Password cannot be empty" >&2
        else
            echo "$password"
            return
        fi
        attempt=$((attempt + 1))
    done
    
    echo "Error: Too many failed password attempts" >&2
    exit 1
}

get_repo_id()
{
    local repo_path
    if ! repo_path=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "Error: Not a git repository" >&2
        exit 1
    fi
    basename "$repo_path" || echo "default"
}

clean()
{
    validate_config
    
    if [[ -n "${AGE_PUBKEY:-}" ]]; then
        if ! age -a -r "$AGE_PUBKEY"; then
            echo "Error: Encryption failed" >&2
            exit 1
        fi
    else
        if ! get_password | age -a -p --passphrase; then
            echo "Error: Encryption failed" >&2
            exit 1
        fi
    fi
}

smudge()
{
    validate_config
    
    temp_file=$(mktemp)
    if [[ -n "${AGE_KEYFILE:-}" && -f "$AGE_KEYFILE" ]]; then
        if ! age -d -i "$AGE_KEYFILE" > "$temp_file"; then
            echo "Error: Decryption failed" >&2
            exit 1
        fi
        cat "$temp_file"
    elif [[ -n "${AGE_PUBKEY:-}" ]]; then
        echo "Error: AGE_KEYFILE environment variable required" >&2
        exit 1
    else
        if ! get_password | age -d --passphrase > "$temp_file"; then
            echo "Error: Decryption failed" >&2
            exit 1
        fi
        cat "$temp_file"
    fi
}

check_dependencies()
{
    if ! command -v age >/dev/null; then
        echo "Error: age tool not found. Install from https://github.com/FiloSottile/age" >&2
        exit 1
    fi
}

init()
{
    if git config filter.git-age.clean >/dev/null; then
        echo "Error: git-age already initialized in this repository" >&2
        exit 1
    fi
    check_dependencies

    local enc_choice
    if [[ "$1" == "symmetric" ]]; then
        enc_choice=1
    elif [[ "$1" == "asymmetric" ]]; then
        enc_choice=2
    else
        echo "Select encryption method:"
        echo "1) Symmetric (password-based)"
        echo "2) Asymmetric (keypair-based)"
        read -p "Choice [1/2]: " enc_choice
    fi

    case "$enc_choice" in
        1)
            local password1 password2
            if [[ ! -t 0 ]]; then
                read -r password1
                password2="$password1"
            else
                while true; do
                    read -s -p "Set git-age password: " password1
                    echo
                    [[ -n "$password1" ]] && break
                    echo "Error: Password cannot be empty" >&2
                done
                read -s -p "Confirm password: " password2
                echo
            fi
            
            if [[ "$password1" != "$password2" ]]; then
                echo "Error: Passwords do not match!" >&2
                exit 1
            fi
            
            if [[ ${#password1} -lt 12 ]]; then
                echo "Error: Password must be at least 12 characters" >&2
                exit 1
            fi
            
            local repo_id
            repo_id=$(get_repo_id)
            store_password "$repo_id" "$password1"
            echo "Symmetric encryption configured. Keep your password secure!"
            ;;
        2)
            if ! command -v age-keygen >/dev/null; then
                echo "Error: age-keygen not found. Required for asymmetric encryption." >&2
                exit 1
            fi
            
            local keyfile
            keyfile="$(git rev-parse --show-toplevel)/.git/git-age-key"
            if [[ -f "$keyfile" ]]; then
                echo "Warning: Key file already exists: $keyfile" >&2
                read -p "Overwrite? [y/N]: " overwrite
                [[ "${overwrite:-N}" != [Yy]* ]] && exit 1
            fi
            
            age-keygen -o "$keyfile"
            chmod 600 "$keyfile"
            local pubkey
            pubkey=$(age-keygen -y "$keyfile")
            
            git config age.publickey "$pubkey"
            git config age.keyfile "$keyfile"
            
            echo -e "\nAsymmetric encryption configured. Keep your private key secure:"
            echo "Private key: $keyfile"
            echo "Public key: $pubkey"
            ;;
        *)
            echo "Invalid choice" >&2
            exit 1
            ;;
    esac

    local script_binpath="$(realpath -s "$0")"
    git config filter.git-age.clean "\"$script_binpath\" clean"
    git config filter.git-age.smudge "\"$script_binpath\" smudge"
    git config filter.git-age.required true
    
    local git_attrs=".gitattributes"
    if [[ -f "$git_attrs" ]]; then
        grep -q "filter=git-age" "$git_attrs" && \
            echo "Warning: Existing git-age configuration found, will append new rules" >&2
        cp "$git_attrs" "${git_attrs}.bak"
    fi
    
    cat > "$git_attrs" <<EOF
# git-age encrypted files
*.secret filter=git-age diff=git-age
.secret/* filter=git-age diff=git-age
EOF
    
    if [[ -f "${git_attrs}.bak" ]]; then
        grep -vE 'filter=git-age|\.secret' "${git_attrs}.bak" >> "$git_attrs"
        rm "${git_attrs}.bak"
    fi
    
    echo -e "\nInitialized git-age configuration:"
    echo "1. Added Git filter configuration"
    echo "2. Configured .gitattributes rules"
    echo "3. These patterns will be automatically encrypted:"
    echo "   - *.secret"
    echo "   - All files under .secret/"
}

show_status()
{
    echo "Git Configuration:"
    git config --get-regexp 'filter\.git-age' 2>/dev/null || echo "  (not configured)"
    
    echo -e "\nAge Key Configuration:"
    if git config age.publickey >/dev/null; then
        echo "  Mode: Asymmetric"
        echo "  Public Key: $(git config age.publickey)"
        echo "  Private Key: $(git config age.keyfile)"
    else
        echo "  Mode: Symmetric (password-based)"
        echo "  Password Storage: $OSTYPE"
    fi
    
    echo -e "\n.gitattributes Rules:"
    if [[ -f .gitattributes ]]; then
        grep -h "filter=git-age" .gitattributes 2>/dev/null || echo "  (no encryption rules)"
    else
        echo "  (no .gitattributes file)"
    fi
}

case "${1:-}" in
    version)    echo "git-age version v$VERSION"; exit 0 ;;
    clean)      clean ;;
    smudge)     smudge ;;
    init)       init "${2:-}" ;;
    status)     show_status ;;
    help|--help|-h) show_help ;;
    *)          show_help; exit 1 ;;
esac
