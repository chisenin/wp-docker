#!/bin/bash

# 测试.env文件修复效果的脚本

echo "=== 测试.env文件修复效果 ==="

# 颜色输出函数
print_blue() {
    echo -e "\033[34m$1\033[0m"
}

print_green() {
    echo -e "\033[32m$1\033[0m"
}

print_red() {
    echo -e "\033[31m$1\033[0m"
}

print_yellow() {
    echo -e "\033[33m$1\033[0m"
}

# 1. 检查.env文件是否存在
print_blue "1. 检查.env文件存在性..."
if [ -f ".env" ]; then
    print_green "✓ .env 文件存在"
else
    print_red "✗ .env 文件不存在，请先生成.env文件"
    exit 1
fi

# 2. 检查.env文件权限
print_blue "2. 检查.env文件权限..."
permissions=$(stat -c '%a' .env 2>/dev/null || stat -f '%A' .env 2>/dev/null)
if [ "$?" -eq 0 ]; then
    print_green "✓ 当前.env文件权限: $permissions"
    if [ "$permissions" == "600" ]; then
        print_green "✓ .env 文件权限符合安全标准 (600)"
    else
        print_yellow "⚠️ .env 文件权限不是600，建议设置为600以提高安全性"
        print_yellow "   可以运行: chmod 600 .env"
    fi
else
    print_yellow "⚠️ 无法获取.env文件权限，可能是不支持的环境"
fi

# 3. 检查.env文件语法
print_blue "3. 检查.env文件语法..."
error_found=false
line_num=0

while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    
    # 跳过空行和注释行
    [[ -z "$line" || "$line" == \#* ]] && continue
    
    # 检查是否包含等号
    if [[ "$line" != *"="* ]]; then
        print_red "✗ 语法错误 (第${line_num}行): 缺少等号"
        print_red "   行内容: $line"
        error_found=true
        continue
    fi
    
    # 尝试提取键值对
    key=$(echo "$line" | cut -d'=' -f1)
    value=$(echo "$line" | cut -d'=' -f2-)
    
    # 检查键名是否有效（只允许字母、数字、下划线）
    if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        print_red "✗ 语法错误 (第${line_num}行): 无效的环境变量名"
        print_red "   键名: $key"
        error_found=true
    fi
    
done < .env

if [ "$error_found" = false ]; then
    print_green "✓ .env 文件语法检查通过，没有发现明显错误"
fi

# 4. 测试安全加载.env文件
print_blue "4. 测试安全加载.env文件..."
set -a

# 使用修复后的方法加载.env文件
loaded_vars=0
grep -v '^\s*#' .env | grep -v '^$' | while IFS= read -r line; do
    if [[ "$line" == *"="* ]]; then
        key=$(echo "$line" | cut -d'=' -f1)
        value=$(echo "$line" | cut -d'=' -f2-)
        export "$key"="$value"
        loaded_vars=$((loaded_vars + 1))
    fi
done

print_green "✓ 成功加载了 $loaded_vars 个环境变量"

# 检查几个关键环境变量是否被正确加载
key_vars=("MYSQL_USER" "MYSQL_DATABASE" "REDIS_HOST")
for var in "${key_vars[@]}"; do
    if [ -n "${!var}" ]; then
        # 对于密码等敏感信息，只显示变量存在，不显示值
        if [[ "$var" == *"PASSWORD"* ]]; then
            print_green "✓ 环境变量 $var 已加载 (值已隐藏)"
        else
            print_green "✓ 环境变量 $var 已加载: ${!var}"
        fi
    else
        print_yellow "⚠️ 环境变量 $var 未被加载或为空"
    fi
done

set +a

# 5. 检查文件结尾
print_blue "5. 检查文件结尾..."
last_char=$(tail -c 1 .env)
if [ -z "$last_char" ]; then
    print_green "✓ 文件以换行符结束"
else
    print_yellow "⚠️ 文件不以换行符结束，可能会导致问题"
fi

print_blue "\n=== 测试完成 ==="
if [ "$error_found" = false ]; then
    print_green "✓ 所有关键测试通过！.env文件应该可以正常工作了"
else
    print_red "✗ 发现一些问题，请根据上述错误信息修复.env文件"
    exit 1
fi

echo ""
echo "提示: 建议定期检查.env文件的权限和内容，确保敏感信息安全。"
