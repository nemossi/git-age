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

    # Check for Windows-specific environment variables
    if [[ -n "$MSYSTEM" ]] || [[ "$(uname -s)" =~ ^(CYGWIN|MINGW32|MINGW64|MSYS|.*_NT-).*$ ]] || [[ "$(uname -o)" == "Msys" ]]; then
        echo "windows"
        return
    fi

    # Fallback to uname for other platforms
    case "$(uname -s)" in
        Linux*)
            echo "ubuntu"
            ;;
        Darwin*)
            echo "macos"
            ;;
        *_NT-*)
            echo "windows"
            ;;
        *)
            echo "Unsupported OS: $(uname -s)" >&2
            exit 1
            ;;
    esac
}

# Install age on ubuntu, windows, and macos
install_age()
{
    case "$1" in
        ubuntu)
            sudo apt-get update
            sudo apt-get install -y age
            ;;
        windows)
            choco install age
            ;;
        macos)
            brew install age
            ;;
        *)
            echo "Unsupported OS: $1"
            exit 1
            ;;
    esac
}

test_encryption()
{
    local os_type=$(detect_os)
    local encryption_type=${1:-symmetric}
    local test_repo=${2:-test-repo}
    local secret_config=${3:-config.secret}
    local secret_content=${4:-"test config"}

    echo "Testing $encryption_type encryption on $os_type"
    setup_git_repo "$test_repo"
    init_git_age "$encryption_type"
    cd $test_repo || exit 1
    add_secret_config "$secret_config" "$secret_content"
    verify_encryption "$secret_config"
    cd ..
    echo "$encryption_type encryption test passed on $os_type"
}

test_decryption()
{
    local os_type=$(detect_os)
    local encryption_type=${1:-symmetric}
    local test_repo=${2:-test-repo}
    local secret_config=${3:-config.secret}
    local secret_content=${4:-"test config"}
    local clone_repo=${5:-test-repo-clone}

    echo "Testing $encryption_type decryption on $os_type"
    clone_git_repo "$test_repo" "$clone_repo"
    cd $clone_repo || exit 1
    init_git_age "$encryption_type"
    verify_if_encrypted "$secret_config"
    git checkout -- .
    verify_if_decrypted "$secret_config" "$secret_content"
    cd ..
    echo "$encryption_type decryption test passed on $os_type"
}

init_git_repo()
{
    local repo_name=${1:-test-repo}
    mkdir "$repo_name"
    cd "$repo_name" || exit 1
    git init
    cd ..
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
    cd test-repo || exit 1
    cp ../src/git-age.sh .
    chmod +x git-age.sh
    
    local encryption_type=${1:-symmetric}
    case "$encryption_type" in
        symmetric)
            echo "testpassword" | ./git-age.sh init symmetric
            ;;
        asymmetric)
            ./git-age.sh init asymmetric
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
    local os_type=$(detect_os)
    local filename=${1:-config.secret}
    
    if [ ! -f "$filename" ]; then
        echo "ERROR: File $filename does not exist" >&2
        exit 1
    fi
    
    case "$os_type" in
        windows)
            if ! Select-String -Path ".\$filename" -Pattern "BEGIN AGE ENCRYPTED FILE" -Quiet; then
                echo "ERROR: File $filename is not properly encrypted (missing AGE header)" >&2
                exit 1
            fi
            ;;
        *)
            if ! grep -q "BEGIN AGE ENCRYPTED FILE" "$filename"; then
                echo "ERROR: File $filename is not properly encrypted (missing AGE header)" >&2
                exit 1
            fi
            ;;
    esac
    echo "Secret file $filename is properly encrypted"
}

verify_if_decrypted()
{
    local os_type=$(detect_os)
    local filename=${1:-config.secret}
    local expected_content=${2:-"test config"}
    
    if [[ "$os_type" == "windows" ]]; then
        if ! (Select-String -Path .\$filename -Pattern "$expected_content" -Quiet); then
            echo "ERROR: File is not decrypted" >&2
            exit 1
        fi
        Get-Content .\$filename | ./git-age.sh smudge || {
            echo "ERROR: Failed to smudge file" >&2
            exit 1
        }
    else
        if ! grep -q "$expected_content" "$filename"; then
            echo "ERROR: File is not decrypted" >&2
            exit 1
        fi
        ./git-age.sh smudge < "$filename" || {
            echo "ERROR: Failed to smudge file" >&2
            exit 1
        }
    fi
}
