#!/bin/bash
# git-age: Cross-platform Git transparent encryption (age-based)
set -e
VERSION="0.1.0"

# Password Management
store_password()
{
    local repo_id=$(get_repo_id)
    local password="$1"
    
    if [[ "$OSTYPE" == "msys"* ]]; then
        echo "$password" | wincred store "git-age-$repo_id"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] && command -v secret-tool >/dev/null; then
        secret-tool store --label="git-age" repo "$repo_id" password "$password"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        security add-generic-password -a "git-age" -s "$repo_id" -w "$password"
    else
        echo "Warning: No credential manager found. Using session-only password." >&2
    fi
}

get_password()
{
    local repo_id=$(get_repo_id)
    
    if [[ -n "$GIT_AGE_PASSPHRASE" ]]; then
        echo "$GIT_AGE_PASSPHRASE"
        return
    fi

    if [[ "$OSTYPE" == "msys"* ]]; then
        wincred get "git-age-$repo_id" 2>/dev/null || prompt_password
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
    read -s -p "Enter git-age password: " password
    echo
    echo "$password"
}

get_repo_id()
{
    git rev-parse --show-toplevel | xargs basename || echo "default"
}

# Encryption (clean filter)
clean()
{
    if [[ -n "$AGE_PUBKEY" ]]; then
        age -a -r "$AGE_PUBKEY"
    else
        age -a -p --passphrase "$(get_password)"
    fi
}

# Decryption (smudge filter)
smudge()
{
    if [[ -n "$AGE_PUBKEY" ]]; then
        age -d -i "$AGE_KEYFILE"
    else
        age -d --passphrase "$(get_password)"
    fi
}

# Initialize repository
init()
{
    if git config filter.git-age.clean >/dev/null; then
        echo "Error: git-age already initialized in this repository" >&2
        exit 1
    fi
    check_dependencies

    # Check for command line arguments
    if [[ "$1" == "symmetric" ]]; then
        enc_choice=1
    elif [[ "$1" == "asymmetric" ]]; then
        enc_choice=2
    else
        echo "Select encryption method:"
        echo "1) Symmetric (password-based)"
        echo "2) Asymmetric (key-based)"
        read -p "Choice [1/2]: " enc_choice
    fi

    case "$enc_choice" in
        1)
            if [[ ! -t 0 ]]; then
                read -s password1
                password2="$password1"
                echo
            else
                read -s -p "Set git-age password: " password1
                echo
                read -s -p "Confirm password: " password2
                echo
            fi

            if [[ "$password1" != "$password2" ]]; then
                echo "Error: Passwords do not match!" >&2
                exit 1
            fi
            store_password "$password1"
            ;;
        2)
            if ! command -v age-keygen >/dev/null; then
                echo "Error: age-keygen not found. Required for asymmetric encryption." >&2
                exit 1
            fi
            
            keyfile="$(git rev-parse --show-toplevel)/.git/git-age-key"
            age-keygen -o "$keyfile"
            pubkey="$(age-keygen -y "$keyfile")"
            
            git config filter.git-age.clean "git-age clean"
            git config filter.git-age.smudge "git-age smudge"
            git config filter.git-age.required true
            git config age.publickey "$pubkey"
            git config age.keyfile "$keyfile"
            
            echo "Asymmetric encryption configured. Keep $keyfile secure!"
            ;;
        *)
            echo "Invalid choice" >&2
            exit 1
            ;;
    esac

    cat > .gitattributes <<EOF
# git-age encrypted files
*.secret filter=git-age diff=git-age
EOF

    echo "Initialized git-age for this repository."
}

check_dependencies()
{
    if ! command -v age >/dev/null; then
        echo "Error: age not installed. Get it from https://github.com/FiloSottile/age" >&2
        exit 1
    fi
}

show_status()
{
    echo "Git Config:"
    git config --get-regexp 'filter\.git-age' || echo "Not configured"
    git config --get-regexp 'age\.' || echo "No age keys configured"
    echo -e "\n.gitattributes Rules:"
    grep -h "filter=git-age" .gitattributes 2>/dev/null || echo "No rules found"
}

case "$1" in
    version)    echo "git-age version v$VERSION"; exit 0 ;;
    clean)      clean ;;
    smudge)     smudge ;;
    init)       init ;;
    status)     show_status ;;
    *)          echo "Usage: git-age {init|clean|smudge|status|version}"; 
                echo "Note: You can set GIT_AGE_PASSPHRASE environment variable to skip password prompt";
                exit 1 ;;
esac