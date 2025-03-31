#!/bin/bash

# Common functions for git-age testing

install_age() {
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

setup_test_repo() {
    mkdir test-repo
    cd test-repo || exit 1
    git init
    echo "test config" > config.secret
}

configure_git_age() {
    local encryption_type=${1:-symmetric}
    cd test-repo || exit 1
    cp ../src/git-age.sh .
    chmod +x git-age.sh
    
    case "$encryption_type" in
        symmetric)
            echo "testpassword" | ./git-age.sh init symmetric
            ;;
        asymmetric)
            ./git-age.sh init asymmetric
            # 获取并导出公钥和密钥文件路径
            export AGE_PUBKEY=$(git config age.publickey)
            export AGE_KEYFILE=$(git config age.keyfile)
            ;;
        *)
            echo "Invalid encryption type: $encryption_type"
            exit 1
            ;;
    esac
}

test_encryption_workflow() {
    local os_type=$1
    local encryption_type=${2:-symmetric}
    
    echo "Testing $encryption_type encryption on $os_type"
    
    setup_test_repo
    configure_git_age "$encryption_type"
    
    # 测试加密
    cd test-repo || exit 1
    git add config.secret
    git commit -m "Add encrypted config"
    
    verify_encryption "$os_type"
    
    # 测试解密
    test_decryption_process "$os_type" "$encryption_type"
    
    echo "$encryption_type encryption test passed on $os_type"
}

verify_encryption() {
    case "$1" in
        windows)
            Select-String -Path .\config.secret -Pattern "BEGIN AGE ENCRYPTED FILE" -Quiet
            if (!$?) {
                echo "ERROR: File is not encrypted"
                exit 1
            }
            ;;
        *)
            if ! grep -q "BEGIN AGE ENCRYPTED FILE" config.secret; then
                echo "ERROR: File is not encrypted"
                exit 1
            fi
            ;;
    esac
    echo "File is properly encrypted"
}

test_decryption_process() {
    local os_type=$1
    local encryption_type=$2
    
    cd test-repo || exit 1
    git clone . ../test-repo-clone
    cd ../test-repo-clone || exit 1
    
    case "$1" in
        windows)
            Select-String -Path .\config.secret -Pattern "BEGIN AGE ENCRYPTED FILE" -Quiet
            if (!$?) {
                echo "ERROR: File is not encrypted before decryption"
                exit 1
            }
            ;;
        *)
            if ! grep -q "BEGIN AGE ENCRYPTED FILE" config.secret; then
                echo "ERROR: File is not encrypted before decryption"
                exit 1
            fi
            ;;
    esac
    
    cp ../../src/git-age.sh .
    chmod +x git-age.sh
    
    # 根据加密类型初始化
    if [[ "$encryption_type" == "asymmetric" ]]; then
        # 从原仓库复制密钥文件
        cp ../../test-repo/.git/git-age-key .git/
        ./git-age.sh init asymmetric
    else
        echo "testpassword" | ./git-age.sh init symmetric
    fi
    
    git checkout -- .
    
    # 解密验证
    case "$os_type" in
        windows)
            Select-String -Path .\config.secret -Pattern "test config" -Quiet
            if (!$?) {
                echo "ERROR: File is not decrypted"
                exit 1
            }
            Get-Content .\config.secret | ./git-age.sh smudge
            ;;
        *)
            if ! grep -q "test config" config.secret; then
                echo "ERROR: File is not decrypted"
                exit 1
            fi
            ./git-age.sh smudge < config.secret
            ;;
    esac
    
    echo "File is properly decrypted"
}

# 新增专用测试函数
test_asymmetric_encryption() {
    local os_type=$1
    echo "Testing asymmetric encryption on $os_type"
    
    setup_test_repo
    configure_git_age "asymmetric"
    
    # 测试加密
    cd test-repo || exit 1
    git add config.secret
    git commit -m "Add encrypted config"
    
    verify_encryption "$os_type"
    
    # 测试解密
    test_decryption_process "$os_type" "asymmetric"
    
    # 验证密钥文件安全性
    if [[ ! -f ".git/git-age-key" ]]; then
        echo "ERROR: Key file not found"
        exit 1
    fi
    if [[ $(stat -c %a .git/git-age-key) != "600" ]]; then
        echo "ERROR: Key file permissions are not secure"
        exit 1
    fi
    
    echo "Asymmetric encryption test passed on $os_type"
}