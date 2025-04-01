#!/bin/bash

# Detect OS type
detect_os()
{
    # Check CI environment variables
    if [[ -n "$RUNNER_OS" ]]; then
        case "$RUNNER_OS" in
            Linux)
                echo "ubuntu"
                ;;
            macOS)
                echo "macos"
                ;;
            Windows)
                echo "windows"
                ;;
            *)
                echo "Unsupported CI OS: $RUNNER_OS" >&2
                exit 1
                ;;
        esac
        return
    fi

    if [[ -n "$(uname -s)" ]]; then
        case "$(uname -s)" in
            Linux*)
                echo "ubuntu"
                ;;
            Darwin*)
                echo "macos"
                ;;
            CYGWIN*|MINGW32*|MINGW64*|MSYS*|*_NT-*)
                echo "windows"
                ;;
            *)
                echo "Unsupported OS: $(uname -s)" >&2
                exit 1
                ;;
        esac
        return
    fi

    # Check for Windows-specific environment variables
    if [[ -n "$MSYSTEM" ]] || [[ "$(uname -o)" == "Msys" ]]; then
        echo "windows"
        return
    fi
}

# Install age on ubuntu, windows, and macos
install_age()
{
    local os_type=$(detect_os)
    case "$os_type" in
        ubuntu)
            sudo apt-get update
            sudo apt-get install -y age
            ;;
        windows)
            choco install age.portable
            ;;
        macos)
            brew install age
            ;;
        *)
            echo "Unsupported OS: $os_type" >&2
            exit 1
            ;;
    esac
}

test_encryption()
{
    local binpath=${1-.}
    local encryption_type=${2:-symmetric}
    local test_repo=${3:-test-repo}
    local secret_config=${4:-config.secret}
    local secret_content=${5:-"test config"}

    echo "Testing $encryption_type encryption..."
    init_git_repo "$test_repo"
    init_git_age "$binpath" "$encryption_type"
    cd $test_repo || exit 1
    add_secret_config "$secret_config" "$secret_content"
    verify_if_encrypted "$encryption_type" "$secret_config"
    cd ..
    echo "$encryption_type encryption test passed."
}

test_decryption()
{
    local binpath=${1-.}
    local encryption_type=${2:-symmetric}
    local test_repo=${3:-test-repo}
    local secret_config=${4:-config.secret}
    local secret_content=${5:-"test config"}
    local clone_repo=${6:-test-repo-clone}

    echo "Testing $encryption_type decryption..."
    clone_git_repo "$test_repo" "$clone_repo"
    cd $clone_repo || exit 1
    init_git_age "$binpath" "$encryption_type"
    verify_if_encrypted "$encryption_type" "$secret_config"
    git checkout -- .
    verify_if_decrypted "$secret_config" "$secret_content"
    cd ..
    echo "$encryption_type decryption test passed."
}

init_git_repo()
{
    local repo_name=${1:-test-repo}
    mkdir "$repo_name"
    cd "$repo_name" || exit 1
    git init
    init_git_user
    cd ..
}

init_git_user()
{
    local email=${1-git-age-test@example.com}
    local name=${2-Git Age Test}
    git config user.email "$email"
    git config user.name "$name"
}

clone_git_repo()
{
    local source_repo=${1:-test-repo}
    local target_repo=${2:-test-repo-clone}
    cd "$source_repo" || { echo "ERROR: Failed to enter source directory $source_repo" >&2; exit 1; }
    git clone . "../$target_repo" || { echo "ERROR: Failed to clone repository" >&2; exit 1; }
    cd "../$target_repo" || { echo "ERROR: Failed to enter cloned repository $target_repo" >&2; exit 1; }
}

add_secret_config()
{
    local filename=${1:-config.secret}
    local content=${2:-"test secret config"}
    echo "$content" > "$filename"
    git add "$filename"
    git commit -m "Add encrypted config"
}

init_git_age()
{
    local binpath=$1
    cp "$binpath/git-age.sh" .
    chmod +x git-age.sh
    
    local encryption_type=${2:-symmetric}
    case "$encryption_type" in
        symmetric)
            echo "testpassword" | ./git-age.sh init "$encryption_type"
            ;;
        asymmetric)
            ./git-age.sh init "$encryption_type"
            export AGE_PUBKEY=$(git config age.publickey)
            export AGE_KEYFILE=$(git config age.keyfile)
            ;;
        *)
            echo "Invalid encryption type: $encryption_type"
            exit 1
            ;;
    esac
}

verify_if_encrypted()
{
    local encryption_type=${1:-symmetric}
    local filename=${2:-config.secret}
    
    if [ ! -f "$filename" ]; then
        echo "ERROR: File $filename does not exist" >&2
        exit 1
    fi
    
    if ! grep -q "BEGIN AGE ENCRYPTED FILE" "$filename"; then
        cat "$filename"
        echo "ERROR: File $filename is not properly encrypted (missing AGE header)" >&2
        exit 1
    fi
    
    if [[ "$encryption_type" == "asymmetric" ]]; then
        if ! grep -q "recipient:" "$filename"; then
            cat "$filename"
            echo "ERROR: Asymmetric encryption missing recipient header" >&2
            exit 1
        fi
    fi
    
    echo "Secret file $filename is properly encrypted"
}

verify_if_decrypted()
{
    local os_type=$(detect_os)
    local filename=${1:-config.secret}
    local expected_content=${2:-"test config"}
    if ! grep -q "$(echo -e "$expected_content")" "$filename"; then
        cat "$filename"
        echo "ERROR: File is not decrypted" >&2
        exit 1
    fi
    check_file_permissions "$filename"
    echo "Secret file $filename is properly decrypted and has correct permissions"    
}

check_file_rw()
{
    local os_type=$(detect_os)
    local filename=${1:-config.secret}

    case "os_type" in
        ubuntu)
            if [[ "$(stat -c '%a' "$filename")" != "644" ]]; then
                echo "ERROR: File permissions should be 644 after decryption" >&2
                exit 1
            fi
            ;;
        windows)
            if attrib "$filename" | grep -q "R "; then
                echo "ERROR: File should not be read-only after decryption" >&2
                exit 1
            fi
            ;;
        macos)
            if [[ "$(stat -f '%OLp' "$filename")" != "644" ]]; then
                echo "ERROR: File permissions should be 644 after decryption" >&2
                exit 1
            fi
            ;;
        *)
            echo "Unsupported OS: $os_type" >&2
            exit 1
            ;;
    esac
}
